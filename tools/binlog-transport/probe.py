#!/usr/bin/env python3
"""Test native BINLOG row application on disposable servers, not the applier.

This research probe has no access to an existing MySQL server. It starts and
removes its own containers. Saved SQL and binlogs contain synthetic test data.
"""
import argparse
import base64
import json
from pathlib import Path
import struct
import subprocess
import time
import uuid
import zlib


PROFILES = {
    "mysql84-to-mysql57-myisam": ("8.4", "5.7", "MyISAM"),
    "mysql57-to-mysql84-innodb": ("5.7", "8.4", "InnoDB"),
    "mysql57-to-mysql57-myisam": ("5.7", "5.7", "MyISAM"),
    "mysql57-to-mysql57-innodb": ("5.7", "5.7", "InnoDB"),
}
IMAGE84 = "mysql:8.4.8-oracle@sha256:2952e3be7807f06fc18de50b3ea1a632d5c70d63482ff7d7376fe3aa8999babf"
IMAGE57 = "mysql-replicator-fixture:5.7.42-setpriv"
PASSWORD = "binlog-probe-only"


def run(arguments, *, data=None, checked=True, timeout=90):
    result = subprocess.run(arguments, input=data, capture_output=True, timeout=timeout)
    if checked and result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result


class Server:
    def __init__(self, name, version, engine, image):
        self.name, self.version, self.engine, self.image = name, version, engine, image

    def start(self):
        # Require a local image. Do not make a network pull part of the probe.
        self.image_id = run(["docker", "image", "inspect", self.image, "--format", "{{.Id}}"])
        self.image_id = self.image_id.stdout.decode().strip()
        myisam = self.engine == "MyISAM"
        run(["docker", "run", "-d", "--platform", "linux/amd64", "--name", self.name,
             "--label", "mysql-replicator.binlog-probe=true", "--network", "none",
             "-e", "MYSQL_ROOT_PASSWORD=" + PASSWORD, self.image_id,
             "--server-id=991", "--log-bin=binlog", "--binlog-format=ROW",
             "--binlog-row-image=FULL", "--binlog-checksum=CRC32",
             "--max-allowed-packet=67108864", "--binlog-row-event-max-size=8192",
             "--gtid-mode=" + ("OFF_PERMISSIVE" if myisam else "ON"),
             "--enforce-gtid-consistency=" + ("OFF" if myisam else "ON")])
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            # TCP avoids the entrypoint's temporary Unix-socket-only server.
            result = self.sql("SELECT 1", checked=False)
            if result.returncode == 0:
                return
            time.sleep(1)
        raise RuntimeError("server startup timed out: " + self.name)

    def sql(self, text, *, checked=True):
        return run(["docker", "exec", "-i", "-e", "MYSQL_PWD=" + PASSWORD, self.name,
                    "mysql", "--no-defaults", "--protocol=TCP", "-h127.0.0.1", "-uroot",
                    "--batch", "--raw", "--skip-column-names", "--binary-mode",
                    "--default-character-set=utf8mb4"], data=text.encode(), checked=checked)

    def scalar(self, query):
        return self.sql(query).stdout.decode().strip()

    def binlog(self):
        query = "SHOW BINARY LOG STATUS" if self.version == "8.4" else "SHOW MASTER STATUS"
        name = self.scalar(query).split("\t")[0]
        if not name.startswith("binlog.") or not name[7:].isdigit():
            raise RuntimeError("unexpected binlog filename")
        return run(["docker", "exec", self.name, "cat", "/var/lib/mysql/" + name]).stdout

    def reset(self):
        command = "RESET BINARY LOGS AND GTIDS" if self.version == "8.4" else "RESET MASTER"
        self.sql(command)

    def close(self, output):
        logs = run(["docker", "logs", self.name], checked=False)
        (output / (self.name + ".log")).write_bytes(logs.stdout + logs.stderr)
        run(["docker", "rm", "-f", "-v", self.name], checked=False)


def events(data):
    """Read only complete, CRC32-protected files created by this probe."""
    if data[:4] != b"\xfebin":
        raise ValueError("not a raw binlog")
    offset = 4
    while offset < len(data):
        if len(data) - offset < 19:
            raise ValueError("truncated event header")
        length = struct.unpack_from("<I", data, offset + 9)[0]
        if length < 23 or length > len(data) - offset:
            raise ValueError("invalid event length")
        event = data[offset:offset + length]
        checked = bytearray(event[:-4])
        # MySQL excludes the mutable binlog-in-use flag from the FDE checksum.
        if event[4] == 15:
            checked[17] &= ~1
        if zlib.crc32(checked) != struct.unpack_from("<I", event, length - 4)[0]:
            raise ValueError("event CRC32 mismatch")
        yield event
        offset += length


def transaction_groups(frames):
    groups, current = [], None
    for event in frames:
        kind = event[4]
        if kind == 33:
            if current is not None:
                raise ValueError("GTID before transaction end")
            identity = str(uuid.UUID(bytes=event[20:36])) + ":" + str(struct.unpack_from("<Q", event, 36)[0])
            current = dict(gtid=identity, frames=[])
        elif kind == 2:
            db_length, status_length = event[27], struct.unpack_from("<H", event, 30)[0]
            query = event[32 + status_length + db_length + 1:-4]
            if current is None or query != b"BEGIN":
                raise ValueError("probe expects only BEGIN query events")
        elif kind in (19, 30, 31, 32):
            if current is None:
                raise ValueError("row event outside GTID group")
            current["frames"].append(event)
        elif kind == 16:
            if current is None or not current["frames"]:
                raise ValueError("empty or unmatched XID")
            groups.append(current)
            current = None
        elif kind not in (3, 4, 15, 35):
            raise ValueError("unsupported probe event: " + str(kind))
    if current is not None:
        raise ValueError("incomplete transaction")
    return groups


def statement(frames):
    return "BINLOG '" + base64.b64encode(b"".join(frames)).decode() + "';\n"


def apply_script(fde, groups, version):
    pseudo_mode = "pseudo_replica_mode" if version == "8.4" else "pseudo_slave_mode"
    script = "SET SESSION " + pseudo_mode + "=1;\n" + statement([fde])
    for group in groups:
        script += "SET SESSION GTID_NEXT='" + group["gtid"] + "';\nBEGIN;\n"
        script += statement(group["frames"]) + "COMMIT;\nSET SESSION GTID_NEXT='AUTOMATIC';\n"
    return script


def seed(engine):
    return ("SET sql_log_bin=0; DROP DATABASE IF EXISTS binlog_probe; "
            "CREATE DATABASE binlog_probe CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; "
            "CREATE TABLE binlog_probe.t(id INT PRIMARY KEY,doc JSON,payload VARBINARY(4096)) ENGINE=" + engine)


def snapshot(server):
    return server.scalar("SELECT id,JSON_EXTRACT(doc,'$.n'),JSON_EXTRACT(doc,'$.updated'),"
                         "JSON_TYPE(JSON_EXTRACT(doc,'$.opaque')),OCTET_LENGTH(payload),"
                         "SHA2(payload,256) FROM binlog_probe.t ORDER BY id")


def row_images(frames):
    """Exact row bytes for this probe's INT/JSON/VARBINARY fixture only.

    This is not a general row decoder. Require FULL images and non-NULL values.
    Comparing raw JSON avoids version-specific SQL rendering of opaque values.
    """
    rows = []
    for event in frames:
        kind = event[4]
        if kind not in (30, 31, 32):
            continue
        end = len(event) - 4
        offset = 27 + struct.unpack_from("<H", event, 27)[0]
        bitmaps = 2 if kind == 31 else 1
        if offset + 1 + bitmaps > end or event[offset] != 3 or any(
                value & 7 != 7 for value in event[offset + 1:offset + 1 + bitmaps]):
            raise ValueError("expected three-column FULL row image")
        offset += 1 + bitmaps
        image_index = 0
        while offset < end:
            start = offset
            if event[offset] & 7:
                raise ValueError("unexpected NULL row field")
            offset += 5  # Null bitmap and INT primary key.
            if offset + 4 > end:
                raise ValueError("truncated JSON length")
            length = struct.unpack_from("<I", event, offset)[0]
            offset += 4 + length
            if offset + 2 > end:
                raise ValueError("truncated VARBINARY length")
            length = struct.unpack_from("<H", event, offset)[0]
            offset += 2 + length
            if offset > end:
                raise ValueError("truncated row image")
            # Unused bitmap bits differ between 5.7 and 8.4. The field bytes,
            # including the JSON type tags and opaque payload, must be identical.
            rows.append((kind, image_index % bitmaps, event[start + 1:offset]))
            image_index += 1
        if image_index % bitmaps:
            raise ValueError("missing UPDATE after-image")
    return rows


def probe(profile, images, output):
    source_version, target_version, engine = PROFILES[profile]
    identifier = "binlog-probe-" + uuid.uuid4().hex[:10]
    source = Server(identifier + "-source", source_version, "InnoDB", images[source_version])
    target = Server(identifier + "-target", target_version, engine, images[target_version])
    output.mkdir(parents=True)
    result = dict(profile=profile, scope="native BINLOG feasibility; no applier or performance claim", experiments=[])
    try:
        source.start()
        target.start()
        result["versions"] = dict(source=source.scalar("SELECT VERSION()"), target=target.scalar("SELECT VERSION()"))
        result["images"] = dict(source=source.image_id, target=target.image_id)
        source.sql(seed("InnoDB"))
        if source_version == "8.4":
            source.sql("SET GLOBAL binlog_row_metadata=FULL")
        source.sql("FLUSH BINARY LOGS")
        values = [f"({i},JSON_OBJECT('n',{i},'opaque',CAST(X'0001FF' AS BINARY)),REPEAT('x',2048))"
                  for i in range(1, 33)]
        workload = ("INSERT INTO binlog_probe.t VALUES " + ",".join(values) + ";\n"
                    "UPDATE binlog_probe.t SET payload=X'00FF',doc=JSON_SET(doc,'$.updated',true) WHERE id<=3;\n"
                    "DELETE FROM binlog_probe.t WHERE id IN (2,32);\n")
        (output / "source.sql").write_text(workload)
        source.sql(workload)
        raw = source.binlog()
        (output / "source.binlog").write_bytes(raw)
        frames = list(events(raw))
        groups = transaction_groups(frames)
        if len(groups) != 3:
            raise ValueError("expected three source transactions")
        result["sourceGTIDs"] = [g["gtid"] for g in groups]
        result["sourceEventTypes"] = [e[4] for e in frames]
        result["expectedRows"] = snapshot(source)
        result["sourceJSONDisplay"] = source.scalar("SELECT CAST(doc AS CHAR),"
            "HEX(JSON_UNQUOTE(JSON_EXTRACT(doc,'$.opaque'))) FROM binlog_probe.t WHERE id=1")
        source_rows = row_images(frames)
        source_fde = next(e for e in frames if e[4] == 15)
        for mode in ("source-fde", "target-fde"):
            target.reset()
            target.sql(seed(engine))
            target_fde = next(e for e in events(target.binlog()) if e[4] == 15)
            script = apply_script(source_fde if mode == "source-fde" else target_fde, groups, target_version)
            (output / (mode + ".sql")).write_text(script)
            applied = target.sql(script, checked=False)
            (output / (mode + ".stdout")).write_bytes(applied.stdout)
            (output / (mode + ".stderr")).write_bytes(applied.stderr)
            rows = snapshot(target)
            target_binlog = target.binlog()
            binary_match = row_images(list(events(target_binlog))) == source_rows
            checks = [target.scalar("SELECT GTID_SUBSET('" + g["gtid"] + "',@@GLOBAL.gtid_executed)") == "1"
                      for g in groups]
            result["experiments"].append(dict(mode=mode, exitCode=applied.returncode,
                rowsMatch=rows == result["expectedRows"], rowImagesMatch=binary_match,
                allGTIDsPresent=all(checks), targetRows=rows,
                targetJSONDisplay=target.scalar("SELECT CAST(doc AS CHAR),"
                    "HEX(JSON_UNQUOTE(JSON_EXTRACT(doc,'$.opaque'))) FROM binlog_probe.t WHERE id=1"),
                targetGTIDs=target.scalar("SELECT @@GLOBAL.gtid_executed"),
                error=applied.stderr.decode(errors="replace")))
            (output / (mode + "-target.binlog")).write_bytes(target_binlog)
        result["atLeastOnePathPassed"] = any(e["exitCode"] == 0 and e["rowsMatch"]
                                            and e["rowImagesMatch"] and e["allGTIDsPresent"]
                                            for e in result["experiments"])
    except Exception as error:
        result["error"] = str(error)
    finally:
        for server in (source, target):
            server.close(output)
        (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=[*PROFILES, "all"], required=True)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory")
    parser.add_argument("--mysql57-image", default=IMAGE57)
    parser.add_argument("--mysql84-image", default=IMAGE84)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    profiles = list(PROFILES) if args.profile == "all" else [args.profile]
    results = []
    for profile in profiles:
        print("Probing " + profile, flush=True)
        result = probe(profile, {"5.7": args.mysql57_image, "8.4": args.mysql84_image}, args.output / profile)
        results.append(result)
        print(json.dumps({k: v for k, v in result.items() if k in ("profile", "error", "atLeastOnePathPassed")}), flush=True)
    (args.output / "summary.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    return 0 if all(r.get("atLeastOnePathPassed") for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
