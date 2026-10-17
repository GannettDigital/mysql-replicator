#!/usr/bin/env python3
"""Check native BINLOG failure and request boundaries with saved probe events.

Only disposable target containers are used. Input must come from probe.py.
This does not test the production applier.
"""
import argparse
import json
from pathlib import Path
import re
import uuid

from probe import (IMAGE57, IMAGE84, PASSWORD, PROFILES, Server, events, run,
                   seed, statement, transaction_groups)


def rejection_matches(name, error, server_log=""):
    if name == "packet-limit":
        # The server can close the connection before the client receives 1153.
        return ("ERROR 1153" in error or ("ERROR 2006" in error
                and "Got a packet bigger than 'max_allowed_packet' bytes" in server_log))
    return "ERROR " + {"missing-format": "1609", "gtid-event": "1730"}[name] in error


def script(fde, group, version, *, split=False, preserve=True, rollback=False):
    mode = "pseudo_replica_mode" if version == "8.4" else "pseudo_slave_mode"
    sql = "SET SESSION " + mode + ("=1;\n" if preserve else "=0;\n") + statement([fde])
    if preserve:
        sql += "SET SESSION GTID_NEXT='" + group["gtid"] + "';\n"
    else:
        # FDE application sets NOT_YET_DETERMINED internally. Reset it even
        # though this fresh client session started with AUTOMATIC.
        sql += "SET SESSION GTID_NEXT='AUTOMATIC';\n"
    sql += "BEGIN;\n"
    packets = [[frame] for frame in group["frames"]] if split else [group["frames"]]
    for packet in packets:
        sql += statement(packet)
    sql += "ROLLBACK;\n" if rollback else "COMMIT;\n"
    sql += "SET SESSION GTID_NEXT='AUTOMATIC';\nSELECT 'end', @@GLOBAL.gtid_executed;\n"
    return sql


def probe(profile, images, source_file, output, cases=None):
    _, version, engine = PROFILES[profile]
    output.mkdir(parents=True)
    frames = list(events(source_file.read_bytes()))
    fde = next(frame for frame in frames if frame[4] == 15)
    groups = transaction_groups(frames)
    group = groups[0]
    target = Server("binlog-behavior-" + uuid.uuid4().hex[:10], version, engine, images[version])
    result = dict(profile=profile, sourceFile=str(source_file), experiments=[])
    try:
        target.start()
        result["version"] = target.scalar("SELECT VERSION()")
        result["image"] = target.image_id
        result["nativeExecutionMode"] = target.scalar("SELECT @@GLOBAL."
            + ("replica_exec_mode" if version == "8.4" else "slave_exec_mode"))
        for name, split, duplicate, preserve, rollback in [
            ("split", True, False, True, False),
            ("split-rollback", True, False, True, True),
            ("duplicate", False, True, True, False),
            ("duplicate-rollback", False, True, True, True),
            ("split-duplicate", True, True, True, True),
            ("automatic", False, False, False, False),
            ("multi-statement", False, False, True, False),
        ]:
            if cases and name not in cases:
                continue
            target.reset()
            target.sql(seed(engine))
            if duplicate:
                target.sql("SET sql_log_bin=0; INSERT INTO binlog_probe.t VALUES (32,JSON_OBJECT('existing',1),'old')")
            selected = (dict(gtid=group["gtid"], frames=[frame for g in groups for frame in g["frames"]])
                        if name == "multi-statement" else group)
            sql = script(fde, selected, version, split=split, preserve=preserve, rollback=rollback)
            (output / (name + ".sql")).write_text(sql)
            # --force lets us inspect the same session and issue an explicit
            # ROLLBACK after a failed BINLOG request. Check stderr, not exit code.
            applied = run(["docker", "exec", "-i", "-e", "MYSQL_PWD=" + PASSWORD, target.name,
                "mysql", "--no-defaults", "--protocol=TCP", "-h127.0.0.1", "-uroot",
                "--batch", "--raw", "--skip-column-names", "--binary-mode", "--force"],
                data=sql.encode(), checked=False)
            (output / (name + ".stdout")).write_bytes(applied.stdout)
            (output / (name + ".stderr")).write_bytes(applied.stderr)
            error = applied.stderr.decode(errors="replace")
            count = int(target.scalar("SELECT COUNT(*) FROM binlog_probe.t"))
            present = target.scalar("SELECT GTID_SUBSET('" + group["gtid"] + "',@@GLOBAL.gtid_executed)") == "1"
            expected_count = (32 if engine == "MyISAM" or not (duplicate or rollback)
                              else 1 if duplicate else 0)
            if split:
                # These are deliberate invalid request boundaries. MySQL clears
                # the table-map state at the end of the map-only request.
                expected_count = 1 if duplicate else 0
            elif name == "multi-statement":
                expected_count = 32 if engine == "MyISAM" else 30
            # Record GTID observations without assuming that rollback has the
            # same GTID semantics as row rollback.
            error_codes = re.findall(r"ERROR (\d+)", error)
            expected_codes = (["1837"] if name == "multi-statement" and engine == "MyISAM"
                              else ["1062"] if duplicate and not split else [])
            passed = count == expected_count and error_codes == expected_codes
            if not duplicate and not rollback:
                passed = passed and present == preserve
            result["experiments"].append(dict(name=name, rows=count, expectedRows=expected_count,
                sourceGTIDPresent=present, targetGTIDs=target.scalar("SELECT @@GLOBAL.gtid_executed"),
                errorCodes=error_codes, expectedErrorCodes=expected_codes, error=error, passed=passed))
            (output / (name + ".binlog")).write_bytes(target.binlog())
        # A successful empty FDE request checks the BINLOG privilege only.
        # It does not prove the account has permission to set GTID_NEXT.
        target.sql("CREATE USER 'probe'@'127.0.0.1' IDENTIFIED BY 'probe'; GRANT ALL ON binlog_probe.* TO 'probe'@'127.0.0.1'")
        denied = run(["docker", "exec", "-i", "-e", "MYSQL_PWD=probe", target.name,
            "mysql", "--no-defaults", "--protocol=TCP", "-h127.0.0.1", "-uprobe", "--batch"],
            data=statement([fde]).encode(), checked=False)
        result["restrictedAccount"] = dict(exitCode=denied.returncode, error=denied.stderr.decode(errors="replace"))
        result["rejections"] = []
        for name, sql in [
            ("missing-format", statement(group["frames"])),
            ("gtid-event", statement([fde]) + "SET SESSION GTID_NEXT='AUTOMATIC';\n"
             + statement([next(frame for frame in frames if frame[4] == 33)])),
            ("packet-limit", script(fde, group, version)),
        ]:
            if cases and name not in cases:
                continue
            target.reset()
            target.sql(seed(engine))
            if name == "packet-limit":
                target.sql("SET GLOBAL max_allowed_packet=8192")
            applied = target.sql(sql, checked=False)
            if name == "packet-limit":
                target.sql("SET GLOBAL max_allowed_packet=67108864")
            count = int(target.scalar("SELECT COUNT(*) FROM binlog_probe.t"))
            error = applied.stderr.decode(errors="replace")
            server_log = ""
            if name == "packet-limit":
                logs = run(["docker", "logs", target.name])
                server_log = (logs.stdout + logs.stderr).decode(errors="replace")
            result["rejections"].append(dict(name=name, exitCode=applied.returncode, error=error,
                rows=count, passed=applied.returncode != 0 and count == 0
                and rejection_matches(name, error, server_log)))
            (output / (name + ".sql")).write_text(sql)
            (output / (name + ".stderr")).write_bytes(applied.stderr)
        result["passed"] = (all(item["passed"] for item in result["experiments"])
                            and "ERROR 1227" in denied.stderr.decode(errors="replace")
                            and all(item["passed"] for item in result["rejections"]))
    except Exception as error:
        result["error"] = str(error)
    finally:
        target.close(output)
        (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=[*PROFILES, "all"], required=True)
    parser.add_argument("--source-directory", type=Path, required=True,
                        help="probe.py output with PROFILE/source.binlog files")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", action="append", choices=["split", "split-rollback", "duplicate",
        "duplicate-rollback", "split-duplicate", "automatic", "multi-statement",
        "missing-format", "gtid-event", "packet-limit"], help="Select cases; repeat to select more than one")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for profile in PROFILES if args.profile == "all" else [args.profile]:
        print("Probing " + profile, flush=True)
        result = probe(profile, {"5.7": IMAGE57, "8.4": IMAGE84},
                       args.source_directory / profile / "source.binlog", args.output / profile, args.case)
        results.append(result)
        print(json.dumps(result), flush=True)
    (args.output / "summary.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    return 0 if all(result.get("passed") for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
