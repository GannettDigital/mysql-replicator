#!/usr/bin/env python3
"""Disposable native reference smoke; never reports Swift apply parity."""
import argparse
import os
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
RUN = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
PROJECT = "replicator-smoke-" + RUN.lower()
OUT = ROOT / "artifacts" / "native-smoke" / RUN
COMPOSE = ["docker", "compose", "-f", str(ROOT / "compose.yaml"), "-p", PROJECT]
SERVICES = ("source", "native", "target57")


def compose(*args, timeout=120):
    return subprocess.run(COMPOSE + list(args), check=True, capture_output=True, timeout=timeout).stdout


def sql(service, statement, headers=False):
    if service != "source":
        # Initialize this client session only. Native applier sessions are separate
        # and obtain their GTID_NEXT from received GTID events.
        statement = "SET @@SESSION.GTID_NEXT = 'AUTOMATIC'; " + statement
    return compose("exec", "-T", "-e", "MYSQL_PWD=fixture-root-only", service,
                   "mysql", "-uroot", "--batch", "--raw", "--column-names" if headers else "--skip-column-names", "-e", statement).decode().strip()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def boundary(service):
    command = "SHOW MASTER STATUS" if service == "target57" else "SHOW BINARY LOG STATUS"
    fields = sql(service, command).split("\t")
    return {"file": fields[0], "position": int(fields[1]), "gtid_executed": sql(service, "SELECT @@GLOBAL.gtid_executed")}


def rows(service):
    result = sql(service, "SELECT id, value, quantity FROM poc.items ORDER BY id")
    return [line.split("\t") for line in result.splitlines()]


def engine(service):
    return sql(service, "SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='items'")


def capture(service):
    dest = OUT / service
    dest.mkdir(exist_ok=True)
    config = "SELECT VERSION(), @@server_id, @@server_uuid, @@log_bin, @@binlog_format, @@binlog_row_image, @@binlog_checksum, @@gtid_mode, @@enforce_gtid_consistency, @@sync_binlog, @@innodb_flush_log_at_trx_commit"
    dest.joinpath("configuration.tsv").write_text(sql(service, config) + "\n")
    dest.joinpath("rows.json").write_text(json.dumps(rows(service), indent=2) + "\n")
    # Workload is quiesced; rotate before copying to capture closed files.
    sql(service, "FLUSH BINARY LOGS")
    logs = sql(service, "SHOW BINARY LOGS").splitlines()[:-1]
    checksums = {}
    for entry in logs:
        name = entry.split("\t")[0]
        require(re.fullmatch(r"binlog\.[0-9]+", name), "unsafe binlog filename")
        raw = compose("exec", "-T", service, "cat", "/var/lib/mysql/" + name)
        dest.joinpath(name).write_bytes(raw)
        checksums[name] = hashlib.sha256(raw).hexdigest()
        require(raw.startswith(b"\xfebin") and len(raw) > 4, "invalid captured binlog")
    dest.joinpath("sha256.json").write_text(json.dumps(checksums, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = ("OFF", "OFF_PERMISSIVE", "ON_PERMISSIVE", "ON")
    parser.add_argument("--gtid", action="store_true", help="Legacy shorthand: GTID ON on all three servers")
    parser.add_argument("--source-gtid-mode", choices=modes, default="ON")
    parser.add_argument("--native-gtid-mode", choices=modes, default="OFF_PERMISSIVE")
    parser.add_argument("--target57-gtid-mode", choices=modes, default="OFF_PERMISSIVE")
    parser.add_argument("--native-gtid-consistency", choices=("ON", "OFF", "WARN"), default=None)
    parser.add_argument("--native-engine", choices=("MyISAM", "InnoDB"), default="MyISAM", help="InnoDB is a diagnostic control, not the required MyISAM reference")
    parser.add_argument("--positioning", choices=("file-position", "auto"), default="auto")
    parser.add_argument("--native-init-automatic", action="store_true", help="Diagnostic: set GTID_NEXT=AUTOMATIC inside the native SQL thread at startup using init_replica")
    parser.add_argument("--workload", choices=("transaction", "autocommit"), default="transaction", help="Autocommit is a control with different source transaction boundaries")
    args = parser.parse_args()
    modes_by_service = {"source": args.source_gtid_mode, "native": args.native_gtid_mode, "target57": args.target57_gtid_mode}
    if args.gtid:
        modes_by_service = dict.fromkeys(SERVICES, "ON")
    consistency = {}
    for service, mode in modes_by_service.items():
        if mode == "OFF":
            consistency[service] = "OFF"
        elif service == "source" or mode == "ON":
            consistency[service] = "ON"
        else:
            consistency[service] = "WARN"
    if args.native_gtid_consistency is not None:
        consistency["native"] = args.native_gtid_consistency
    if modes_by_service["native"] == "ON" and consistency["native"] != "ON":
        parser.error("native GTID ON requires enforce_gtid_consistency ON")
    if args.positioning == "auto" and (modes_by_service["source"] != "ON" or modes_by_service["native"] == "OFF"):
        parser.error("auto-positioning requires source ON and native OFF_PERMISSIVE, ON_PERMISSIVE or ON")
    for service, mode in modes_by_service.items():
        os.environ["FIXTURE_" + service.upper() + "_GTID_MODE"] = mode
        os.environ["FIXTURE_" + service.upper() + "_GTID_CONSISTENCY"] = consistency[service]
    OUT.mkdir(parents=True)
    report = {"project": PROJECT, "native_reference": "failed", "swift_apply": "pending", "binlog_logical_comparison": "pending", "phase_1": "in_progress", "gtid_modes": modes_by_service, "gtid_consistency": consistency, "native_engine": args.native_engine, "positioning": args.positioning, "workload": args.workload, "native_init_automatic": args.native_init_automatic}
    try:
        OUT.joinpath("compose.yaml").write_bytes(compose("config"))
        OUT.joinpath("startup.log").write_bytes(compose("up", "-d", "--build", "--wait", "--wait-timeout", "300", timeout=600))
        sql("source", "CREATE USER 'replicator_fixture'@'%' IDENTIFIED BY 'fixture-replication-only'; GRANT REPLICATION SLAVE ON *.* TO 'replicator_fixture'@'%'")
        for service in SERVICES:
            actual = sql(service, "SELECT @@gtid_mode, @@enforce_gtid_consistency").split("\t")
            require(actual == [modes_by_service[service], consistency[service]], service + " GTID settings differ from request")
            storage = "InnoDB" if service == "source" else args.native_engine if service == "native" else "MyISAM"
            sql(service, "CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; "
                "CREATE TABLE poc.items (id INT PRIMARY KEY, value VARCHAR(100) NOT NULL, quantity BIGINT UNSIGNED NOT NULL) ENGINE=" + storage + "; "
                "INSERT INTO poc.items VALUES (1,'seed-one',1),(2,'seed-two',2)")
            require(engine(service) == storage, service + " initial engine mismatch")
        start = boundary("source")
        report["post_seed_source_boundary"] = start
        report["target_start_boundaries"] = {service: boundary(service) for service in SERVICES[1:]}
        if args.positioning == "auto":
            # Disposable, verified seed only: mark the exact source snapshot boundary
            # as already provisioned. Append to the native server's own setup history.
            require(rows("native") == rows("source"), "snapshot rows differ before GTID bootstrap")
            sql("native", "SET @@GLOBAL.gtid_purged='+" + start["gtid_executed"] + "'")
            position_clause = "SOURCE_AUTO_POSITION=1"
            report["seeded_source_gtid_set"] = start["gtid_executed"]
        else:
            position_clause = "SOURCE_AUTO_POSITION=0, SOURCE_LOG_FILE='" + start["file"] + "', SOURCE_LOG_POS=" + str(start["position"])
        if args.native_init_automatic:
            sql("native", "SET @@GLOBAL.init_replica = 'SET @@SESSION.GTID_NEXT = ''AUTOMATIC'''")
            report["init_replica"] = sql("native", "SELECT @@GLOBAL.init_replica")
            require(report["init_replica"] == "SET @@SESSION.GTID_NEXT = 'AUTOMATIC'", "unexpected native startup initializer")
        sql("native", "CHANGE REPLICATION SOURCE TO SOURCE_HOST='source', SOURCE_USER='replicator_fixture', "
            "SOURCE_PASSWORD='fixture-replication-only', " + position_clause + ", GET_SOURCE_PUBLIC_KEY=1; START REPLICA")
        workload = """BEGIN;
INSERT INTO poc.items VALUES (3,'inserted',18446744073709551615);
UPDATE poc.items SET value='updated' WHERE id=1;
DELETE FROM poc.items WHERE id=2;
COMMIT;
BEGIN;
INSERT INTO poc.items VALUES (4,'rolled-back',4);
ROLLBACK;
UPDATE poc.items SET value='final-three' WHERE id=3;
"""
        if args.workload == "autocommit":
            # Change only the first three DML statements to independent commits.
            # Keep the later rollback probe transactional.
            workload = workload.replace("BEGIN;\n", "", 1).replace("COMMIT;\n", "", 1)
        OUT.joinpath("workload.sql").write_text(workload)
        intent = [
            {"transaction": 1, "operation": "insert", "key": 3, "after": ["3", "inserted", "18446744073709551615"]},
            {"transaction": 1, "operation": "update", "key": 1, "before": ["1", "seed-one", "1"], "after": ["1", "updated", "1"]},
            {"transaction": 1, "operation": "delete", "key": 2, "before": ["2", "seed-two", "2"]},
            {"transaction": 2, "operation": "update", "key": 3, "before": ["3", "inserted", "18446744073709551615"], "after": ["3", "final-three", "18446744073709551615"]},
        ]
        if args.workload == "autocommit":
            for transaction, item in enumerate(intent, 1):
                item["transaction"] = transaction
        OUT.joinpath("expected-operations.ndjson").write_text("".join(json.dumps(item) + "\n" for item in intent))
        sql("source", workload)
        end = boundary("source")
        report["workload_end_source_boundary"] = end
        delta = sql("source", "SELECT GTID_SUBTRACT('" + end["gtid_executed"] + "','" + start["gtid_executed"] + "')")
        report["workload_gtid_set"] = delta
        if modes_by_service["source"] == "ON":
            require(bool(delta), "GTID ON source emitted no workload GTIDs")
        waited = sql("native", "SELECT SOURCE_POS_WAIT('" + end["file"] + "'," + str(end["position"]) + ",30)")
        status = sql("native", "SHOW REPLICA STATUS\\G", headers=True)
        OUT.joinpath("native-status-at-barrier.txt").write_text(status + "\n")
        for field in ("Last_SQL_Errno", "Last_SQL_Error", "Last_IO_Errno", "Last_IO_Error", "Auto_Position", "Source_Log_File", "Read_Source_Log_Pos", "Relay_Source_Log_File", "Exec_Source_Log_Pos"):
            match = re.search(r"^\s*" + field + r": (.*)$", status, re.MULTILINE)
            report[field] = match.group(1) if match else None
        require(all(report[field] is not None for field in ("Last_SQL_Errno", "Last_IO_Errno", "Auto_Position")), "missing labeled replica diagnostic fields")
        report["rows_at_barrier"] = {service: rows(service) for service in SERVICES}
        report["native_gtid_executed"] = sql("native", "SELECT @@GLOBAL.gtid_executed")
        require(report["Auto_Position"] == ("1" if args.positioning == "auto" else "0"), "unexpected positioning mode")
        require(waited not in ("NULL", "-1"), "native replica did not reach workload boundary")
        require(report["Last_SQL_Errno"] == "0" and report["Last_IO_Errno"] == "0", "native replication reported an error")
        if delta:
            require(sql("native", "SELECT GTID_SUBSET('" + delta + "',@@GLOBAL.gtid_executed)") == "1", "native is missing workload GTIDs")
        sql("native", "STOP REPLICA")
        OUT.joinpath("native-status.txt").write_text(sql("native", "SHOW REPLICA STATUS\\G", headers=True) + "\n")
        require(sql("target57", "SHOW SLAVE STATUS") == "", "5.7 fixture unexpectedly has native replication configured")
        expected = [["1", "updated", "1"], ["3", "final-three", "18446744073709551615"]]
        OUT.joinpath("expected-rows.json").write_text(json.dumps(expected, indent=2) + "\n")
        for service in ("source", "native"):
            require(rows(service) == expected, service + " exact rows differ from independent expected state")
        require(rows("target57") == [["1", "seed-one", "1"], ["2", "seed-two", "2"]], "5.7 seed unexpectedly changed")
        for service in SERVICES:
            require(engine(service) == ("InnoDB" if service == "source" else args.native_engine if service == "native" else "MyISAM"), service + " final engine mismatch")
        # Separate table demonstrates MyISAM rollback behavior on both targets.
        for service in SERVICES[1:]:
            sql(service, "CREATE TABLE poc.rollback_probe(id INT PRIMARY KEY) ENGINE=MyISAM; BEGIN; INSERT INTO poc.rollback_probe VALUES(1); ROLLBACK")
            require(sql(service, "SELECT COUNT(*) FROM poc.rollback_probe") == "1", service + " missing MyISAM rollback evidence")
        report["myisam_rollback"] = "write_survives_on_both_targets"
        for service in SERVICES:
            capture(service)
        report["native_reference"] = "passed"
    except BaseException as error:
        report["error"] = repr(error)
        if isinstance(error, subprocess.CalledProcessError):
            OUT.joinpath("command-error.log").write_bytes((error.stdout or b"") + (error.stderr or b""))
        try:
            sql("native", "STOP REPLICA")
            for service in SERVICES:
                capture(service)
        except Exception as capture_error:
            report["failure_capture_error"] = repr(capture_error)
        raise
    finally:
        try:
            OUT.joinpath("containers.log").write_bytes(compose("logs", "--no-color"))
        finally:
            try:
                compose("down", "--volumes", "--remove-orphans", timeout=120)
                report["cleanup"] = "passed"
            except BaseException as error:
                report["cleanup"] = "failed: " + repr(error)
                print("Cleanup failed; inspect Compose project " + PROJECT, flush=True)
                raise
            finally:
                OUT.joinpath("result.json").write_text(json.dumps(report, indent=2) + "\n")
                print(str(OUT), flush=True)
    print("Native reference passed; Swift apply parity remains pending.", flush=True)


if __name__ == "__main__":
    main()
