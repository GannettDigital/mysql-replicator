#!/usr/bin/env python3
"""Measure cold discovery and warm writes with a local applier and disposable MySQL.

Only local Docker images and a supplied binary are used. No existing server can
be selected. Keep the output: it includes configs, synthetic binlogs, logs, and
support bundles. JSON is emitted as valid YAML in the generated .yaml files.
"""
import argparse
import hashlib
import json
from pathlib import Path
import socket
import shutil
import tempfile
import statistics
import struct
import sqlite3
import subprocess
import sys
import time
import uuid

from tcp_delay import DelayProxy

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "binlog-transport"))
from probe import IMAGE57, IMAGE84, PASSWORD, PROFILES, Server, run


class FixtureServer(Server):
    def start(self):
        self.image_id = run(["docker", "image", "inspect", self.image, "--format", "{{.Id}}"])
        self.image_id = self.image_id.stdout.decode().strip()
        myisam = self.engine == "MyISAM"
        run(["docker", "run", "-d", "--platform", "linux/amd64", "--name", self.name,
             "--label", "mysql-replicator.metadata-benchmark=true", "-p", "127.0.0.1::3306",
             "-e", "MYSQL_ROOT_PASSWORD=" + PASSWORD, self.image_id,
             "--server-id=991", "--log-bin=binlog", "--binlog-format=ROW",
             "--binlog-row-image=FULL", "--binlog-checksum=CRC32", "--skip-slave-start",
             "--gtid-mode=" + ("OFF_PERMISSIVE" if myisam else "ON"),
             "--enforce-gtid-consistency=" + ("WARN" if myisam else "ON")]
            + (["--binlog-row-metadata=FULL", "--mysql-native-password=ON"] if self.version == "8.4" else []))
        self.port = int(run(["docker", "port", self.name, "3306/tcp"]).stdout.decode().strip().split(":")[-1])
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if self.sql("SELECT 1", checked=False).returncode == 0:
                self.sql("CREATE USER 'bench'@'%' IDENTIFIED WITH mysql_native_password BY '" + PASSWORD
                         + "'; GRANT ALL ON *.* TO 'bench'@'%'")
                return
            time.sleep(1)
        raise RuntimeError("server startup timed out")


def ping_rtt(port):
    """Measure real COM_PING RTT on one authenticated disposable connection.

    This small probe supports only our mysql_native_password fixture account.
    It is not a production MySQL client. TLS is deliberately disabled here.
    """
    with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
        def receive():
            def exact(n):
                data = b""
                while len(data) < n:
                    part = sock.recv(n - len(data))
                    if not part:
                        raise RuntimeError("closed MySQL ping connection")
                    data += part
                return data
            size = int.from_bytes(exact(4)[:3], "little")
            if size > 65536:
                raise RuntimeError("unexpected ping packet size")
            return exact(size)

        def send(data, seq=0):
            sock.sendall(len(data).to_bytes(3, "little") + bytes([seq]) + data)

        hello = receive()
        end = hello.index(b"\0", 1)
        salt1 = hello[end + 5:end + 13]
        salt2 = hello[end + 32:end + 44]
        salt = salt1 + salt2
        first = hashlib.sha1(PASSWORD.encode()).digest()
        scramble = hashlib.sha1(salt + hashlib.sha1(first).digest()).digest()
        auth = bytes(a ^ b for a, b in zip(first, scramble))
        flags = 0x00000200 | 0x00008000 | 0x00080000  # protocol41, secure connection, plugin auth
        send(struct.pack("<IIB23x", flags, 65536, 45) + b"bench\0" + bytes([len(auth)])
             + auth + b"mysql_native_password\0", 1)
        reply = receive()
        if reply[0] == 0xfe:
            plugin, salt = reply[1:].split(b"\0", 1)
            if plugin != b"mysql_native_password":
                raise RuntimeError("unexpected fixture authentication plugin")
            scramble = hashlib.sha1(salt.rstrip(b"\0") + hashlib.sha1(first).digest()).digest()
            send(bytes(a ^ b for a, b in zip(first, scramble)), 3)
            reply = receive()
        if reply[0] != 0:
            raise RuntimeError("fixture ping authentication failed: " + repr(reply))
        samples = []
        for i in range(11):
            start = time.monotonic()
            send(b"\x0e")
            if receive()[0] != 0:
                raise RuntimeError("COM_PING failed")
            if i:
                samples.append((time.monotonic() - start) * 1000)
        send(b"\x01")
        return {"median_ms": statistics.median(samples), "minimum_ms": min(samples), "samples_ms": samples}


def schema(tables, engine, fk_group):
    statements = ["SET sql_log_bin=0", "DROP DATABASE IF EXISTS metadata_bench",
                  "CREATE DATABASE metadata_bench CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"]
    for i in range(tables):
        parent = i - i % fk_group if fk_group else i
        fk = (f", FOREIGN KEY(parent_id) REFERENCES metadata_bench.t{parent}(id) ON DELETE CASCADE"
              if fk_group and parent != i else "")
        statements += [f"CREATE TABLE metadata_bench.t{i}(id INT PRIMARY KEY,parent_id INT NOT NULL,value INT NOT NULL,"
                       f"KEY(parent_id){fk}) ENGINE={engine}", f"INSERT INTO metadata_bench.t{i} VALUES(0,0,0)"]
    return ";\n".join(statements) + ";"


def workload(events, tables):
    return "\n".join(f"INSERT INTO metadata_bench.t{i % tables} VALUES({1 + i // tables},0,{i});"
                     for i in range(events))


def snapshot(server, tables):
    # Compare every row, not just counts/sums.
    return [server.scalar(f"SELECT * FROM metadata_bench.t{i} ORDER BY id") for i in range(tables)]


def final_summary(result):
    records = [json.loads(line) for line in (result.stdout + b"\n" + result.stderr).splitlines()
               if line.startswith(b"{")]
    summaries = [item for item in records if item.get("kind") == "apply_summary" and item.get("lifecycle") == "STOPPED"]
    if len(summaries) != 1 or "stageTimings" not in summaries[0]:
        raise RuntimeError("missing or ambiguous final stopped summary")
    return summaries[0]


def run_case(args, source, target, archive, resume_archive, baseline, expected, after_ddl, delay, output):
    output.mkdir()
    print("Measure " + str(delay) + " ms added RTT: " + str(output), flush=True)
    target.sql(schema(args.tables, target.engine, args.foreign_key_group_size))
    proxy = DelayProxy("127.0.0.1", target.port, delay).start()
    temporary = Path(tempfile.mkdtemp(prefix="mr-meta-", dir="/tmp"))
    try:
        measured = ping_rtt(proxy.listen_port)
        config = dict(version=2, profile=args.profile, stateDirectory=str(temporary / "state"), applierProfiling=True,
            source=dict(version=2, host="unused.invalid", port=3306, username="unused", requireTLS=False,
                        serverID=9100, sourceUUID=source.scalar("SELECT @@server_uuid"), mode="gtid",
                        start=dict(executedGTIDs=baseline)),
            target=dict(host="127.0.0.1", port=proxy.listen_port, username="bench", password=PASSWORD,
                        requireTLS=False, preserveSourceGTIDs=False, nativeAutoStartDisabled=True,
                        transport=args.dml_transport),
            statistics=dict(tableDetails=args.table_statistics == "on"),
            targetReconnect=dict(enabled=False), archive=dict(directory=str(archive)),
            supportBundle=dict(onBlocked=True, directory=str(output / "bundles"), format="directory"))
        path = output / "apply.yaml"
        path.write_text(json.dumps(config, indent=2) + "\n")
        start = time.monotonic()
        result = run([str(args.binary), "replay", "--config", str(path), "--initialize", "--verbose"],
                     checked=False, timeout=600)
        elapsed = time.monotonic() - start
        (output / "stdout.ndjson").write_bytes(result.stdout)
        (output / "stderr.ndjson").write_bytes(result.stderr)
        if result.returncode:
            raise RuntimeError("replay failed; inspect " + str(output / "stderr.ndjson") + " and its support bundle")
        summary = final_summary(result)
        if summary["rowsApplied"] != args.events or snapshot(target, args.tables) != expected:
            raise RuntimeError("target rows differ from source")
        logs = [json.loads(line) for line in result.stderr.splitlines() if line.startswith(b"{")]
        discoveries = [log["fields"] for log in logs if log.get("message") == "Target schema query totals"]
        if len(discoveries) != args.tables:
            raise RuntimeError("warm writes unexpectedly repeated discovery: " + str(len(discoveries)))
        stages = summary["stageTimings"]
        metadata = {key: value for key, value in stages.items() if key.startswith("target.metadata.")}
        reads = {key: value for key, value in metadata.items() if key != "target.metadata.cache_hit"}
        report = dict(added_rtt_ms=delay, measured_mysql_ping_rtt=measured, seconds=elapsed,
                      transactions_per_second=args.events / elapsed, summary=summary, discovery=discoveries,
                      metadata_queries=sum(v["count"] for v in reads.values()),
                      metadata_seconds=sum(v["seconds"] for v in reads.values()), metadata_families=metadata)
        # A separate phase checks fresh sessions and DDL invalidation. Its time
        # does not enter the cold/warm throughput result above.
        config["archive"]["directory"] = str(resume_archive)
        path.write_text(json.dumps(config, indent=2) + "\n")
        resumed = run([str(args.binary), "replay", "--config", str(path), "--verbose"], checked=False, timeout=600)
        (output / "resume.stdout.ndjson").write_bytes(resumed.stdout)
        (output / "resume.stderr.ndjson").write_bytes(resumed.stderr)
        if resumed.returncode:
            raise RuntimeError("DDL/resume check failed; inspect " + str(output / "resume.stderr.ndjson") + " and its support bundle")
        resume_summary = final_summary(resumed)
        if resume_summary["rowsApplied"] != args.events + 2 or resume_summary["ddlApplied"] != 1 or snapshot(target, args.tables) != after_ddl:
            raise RuntimeError("DDL/resume rows or counters differ")
        if args.table_statistics == "on":
            with sqlite3.connect("file:" + str(temporary / "state/state.sqlite") + "?mode=ro", uri=True) as database:
                entries = [json.loads(row[0]) for row in database.execute("SELECT entry_json FROM table_statistics")]
            durable = [entry["durable"] for entry in entries]
            if sum(entry["insertRows"] for entry in durable) != args.events + 1 or sum(entry["updateRows"] for entry in durable) != 1:
                raise RuntimeError("table statistics do not match applied source rows")
            if sum(entry["ddl"].get("ALTER_TABLE", 0) for entry in durable) != 1:
                raise RuntimeError("table statistics do not include ALTER")
            report["table_statistics_check"] = "passed"
            (output / "table-statistics.json").write_text(json.dumps(entries, indent=2) + "\n")
        report["ddl_and_new_session_check"] = "passed"
        report["resume_summary"] = resume_summary
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        return report
    finally:
        proxy.close()
        if (temporary / "state").exists():
            shutil.copytree(temporary / "state", output / "state")
        shutil.rmtree(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tables", type=int, default=8)
    parser.add_argument("--events", type=int, default=128)
    parser.add_argument("--foreign-key-group-size", type=int, default=0)
    parser.add_argument("--target-rtt-ms", type=int, default=20)
    parser.add_argument("--table-statistics", choices=["on", "off"], default="off")
    parser.add_argument("--dml-transport", choices=["sql", "binlog"], default="sql")
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.output = args.output.resolve()
    if not (1 <= args.tables <= 6000 and args.tables <= args.events <= 100000 and 0 <= args.target_rtt_ms <= 1000
            and (args.foreign_key_group_size == 0 or 2 <= args.foreign_key_group_size <= min(args.tables, 64))):
        parser.error("invalid event, table, FK group, or delay range")
    source_version, target_version, engine = PROFILES[args.profile]
    if engine == "MyISAM" and args.foreign_key_group_size:
        parser.error("foreign keys require an InnoDB target")
    args.output.mkdir(parents=True, exist_ok=False)
    images = {"5.7": IMAGE57, "8.4": IMAGE84}
    token = uuid.uuid4().hex[:10]
    source = FixtureServer("metadata-source-" + token, source_version, "InnoDB", images[source_version])
    target = FixtureServer("metadata-target-" + token, target_version, engine, images[target_version])
    report = dict(profile=args.profile, binary=str(args.binary), transport=args.dml_transport,
                  table_statistics=args.table_statistics, tables=args.tables, events=args.events, foreign_key_group_size=args.foreign_key_group_size,
                  delay_model="Each direction delays received bytes by half the added RTT. No bandwidth or loss model.",
                  timing_scope="Local debug/release binary replay wall time, including startup; no native performance comparison.",
                  cases=[])
    try:
        source.start(); target.start()
        report["images"] = dict(source=source.image_id, target=target.image_id)
        report["versions"] = dict(source=source.scalar("SELECT VERSION()"), target=target.scalar("SELECT VERSION()"))
        source.sql(schema(args.tables, "InnoDB", args.foreign_key_group_size))
        baseline = source.scalar("SELECT @@GLOBAL.gtid_executed")
        source.sql(workload(args.events, args.tables))
        expected = snapshot(source, args.tables)
        source.sql("FLUSH BINARY LOGS")
        archive = args.output / "archive"
        archive.mkdir()
        # Copy the closed file; the next file is empty. Do not copy a live tail.
        name = source.scalar("SHOW BINARY LOGS").splitlines()[-2].split("\t")[0]
        run(["docker", "cp", source.name + ":/var/lib/mysql/" + name, str(archive / name)])
        resume_archive = args.output / "resume-archive"
        shutil.copytree(archive, resume_archive)
        source.sql("UPDATE metadata_bench.t0 SET value=1 WHERE id=0; "
                   "ALTER TABLE metadata_bench.t0 ADD COLUMN extra INT DEFAULT 7; "
                   "INSERT INTO metadata_bench.t0(id,parent_id,value) VALUES(1000001,0,1)")
        after_ddl = snapshot(source, args.tables)
        source.sql("FLUSH BINARY LOGS")
        name = source.scalar("SHOW BINARY LOGS").splitlines()[-2].split("\t")[0]
        run(["docker", "cp", source.name + ":/var/lib/mysql/" + name, str(resume_archive / name)])
        for delay in sorted({0, args.target_rtt_ms}):
            report["cases"].append(run_case(args, source, target, archive, resume_archive, baseline, expected, after_ddl, delay,
                                            args.output / (str(delay) + "ms")))
        report["result"] = "passed"
    except BaseException as error:
        report["result"], report["error"] = "failed", str(error)
        raise
    finally:
        for server in [source, target]:
            server.close(args.output)
        (args.output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Metadata benchmark: " + str(args.output))


if __name__ == "__main__":
    main()
