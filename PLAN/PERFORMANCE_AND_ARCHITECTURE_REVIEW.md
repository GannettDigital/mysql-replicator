# Architecture, Performance Profile, and Readiness Review

**Date:** 2026-10-01  
**Target Repository:** `GannettDigital/mysql-replicator`  
**Reference Document:** `PLAN/REPO.md`

---

## 1. Executive Summary & Current Project State

`mysql-replicator` is an engine designed to replicate MySQL binary logs across incompatible MySQL versions or dialects (specifically targeting Cloud SQL MySQL 8.4 InnoDB as source and on-premises MySQL 5.7 MyISAM as target).

### Current Strengths
1. **Correctness & Safety First:** The project implements an ultra-rigorous, fail-stop verification pipeline. Cryptographic CRC32 checks, ABI boundary isolation between Swift and Rust (`mysql_common`), and strict transaction boundary assembly prevent undetected corruption.
2. **Durable Local State:** SQLite-backed checkpointing with WAL and full synchronization guarantees that replication state (`groups`, `state`, `schemas`, `ddl_intents`, `row_intents`) can cleanly stop, resume, or skip rejected GTIDs without silent drift.
3. **Comprehensive Lab & Qualification Harness:** Complete Docker-based testing matrix (`ddl-suite`, `dml-suite`, `live-suite`, `native-suite`, `ubuntu-smoke`) verifies exact before/after row states, schema changes, and error rejections against native MySQL references.
4. **Recent Increments:**
   - **Wildcard Filtering (`replicateWildIgnoreTable`):** Emulates MySQL `Replicate_Wild_Ignore_Table`, safely filtering DDL and DML for excluded schemas/tables before target discovery and row decoding.
   - **Targeted Test Execution (`SuiteSelection`):** Adds `--slice`, `--case`, `--positioning`, and `--list` flags to enable targeted test runs without incurring full-suite container turnaround time.

### Current Limitations
The current applier operates as a **strict proof-of-concept verification harness**. Its current throughput is bounded by design choices prioritizing invariant verification over replication speed:
- Single-threaded, synchronous lockstep between binlog ingestion and target application.
- Severe amplification of network roundtrips (3 queries per row) and disk I/O (2 unbatched SQLite commits and filesystem syncs per row).
- Estimated throughput on typical network/storage latency is ~10–50 rows/second, which will lag under high-volume production workloads.

---

## 2. Performance Profile & Pipeline Analysis

### A. Binlog Pull & Ingestion (`ReplicatorCapture`)
1. **Lockstep Ingestion Loop (`LiveInspection.swift`):**
   - The connection channel sets `autoRead = false` and `maxMessagesPerRead = 1`.
   - Binlog frames are read synchronously via `queue.next(..., requestRead: { channel.read() })`.
   - `StreamProcessor.consume(frame)` synchronously invokes `emitEvent(state.append)` and, at transaction boundaries, `emitTransaction(...)`.
   - **Bottleneck:** While `emitTransaction` executes target queries, locks tables, and synchronizes SQLite, **reading from the source MySQL network socket is completely paused**. There is no pipelined prefetching or asynchronous decoupling buffer between reader and applier.
2. **Base64 & JSON Overhead on Hot Path:**
   - Every raw binlog event is converted into a base64 string across the C ABI / Swift model (`DecodedEvent.rawBase64`), and then parsed back from base64 into `Data` inside `StateStore.append`.
   - Every event also executes `JSONSerialization.data(...)` to construct framing metadata before writing to `relay.frames`.
   - For high-event-volume streams, memory allocation and CPU cycles spent on base64 encoding/decoding and JSON formatting will create substantial garbage collection and memory pressure.

### B. SQLite State Management (`ReplicatorApply/StateStore.swift`)
1. **Unbatched SQLite Row Intents:**
   - In `ApplyRun.swift`, for every row mutation in a group:
     ```swift
     try state.intent(index, mutation)  // INSERT INTO row_intents
     try target.apply(mutation)
     try state.rowDone(index)           // UPDATE row_intents SET status='DONE'
     ```
   - Neither `state.intent` nor `state.rowDone` is enclosed in an explicit SQLite transaction (`BEGIN...COMMIT`).
   - Consequently, each call runs in SQLite autocommit mode, triggering independent B-tree operations and journal/WAL writes **twice per replicated row**.
2. **Aggressive `PRAGMA synchronous = FULL` & Relay Syncs:**
   - SQLite is configured with `PRAGMA synchronous = FULL` and `PRAGMA journal_mode = WAL`.
   - In `begin(_ group:)`: calls `relay!.synchronize()` (`fsync` on the relay file), followed by `atomic { ... }` (an explicit SQLite commit with full disk sync).
   - In `complete(_ group:)`: performs `SELECT COUNT(*)` verification queries, followed by another `atomic { ... }` commit with full disk sync.
   - For a workload with 100 single-row transactions/sec, this issues hundreds of blocking disk syncs per second.
3. **Hot-Path Filesystem Probing:**
   - On every raw event appended to `relay.frames`, `append` invokes `checkDisk(extra: ...)`, which makes a `statvfs` system call. Probing filesystem free space on every packet is redundant and adds syscall overhead.
4. **`wal_autocheckpoint = 64`:**
   - Checkpointing the WAL every 64 pages (256 KB) creates constant I/O churn during bulk replication.

### C. Target Database Application (`ReplicatorApply/TargetSession.swift`)
1. **Triple Network Round-Trip Amplification per Row:**
   - In `TargetSession.apply(_ m: Mutation)`:
     - **Before-query:** `let current = try read(t, key: oldKey)` executes `SELECT ... WHERE pk = ?` to verify the pre-image.
     - **Mutation:** Executes the actual `INSERT`, `UPDATE`, or `DELETE`.
     - **After-query:** Executes another `SELECT ... WHERE pk = ?` to verify the post-image (or verify absence after `DELETE`).
   - Replicating a 100-row transaction requires **300 synchronous round-trips over TLS to target MySQL**.
2. **Table Locking & Schema Verification per Transaction:**
   - In `ApplyRun.swift`: `target.lock(mutations[0].table)` executes `LOCK TABLES ... WRITE`.
   - Immediately inside `lock`, `verifySchema(table)` executes 5 distinct `information_schema` queries (`TABLES`, `COLUMNS`, `STATISTICS`, `TRIGGERS`, `PARTITIONS`, table collations).
   - This metadata query storm repeats on every transaction, adding 5–6 round-trips and locking overhead even when replicating against the exact same table repeatedly.

---

## 3. Recommended Performance Roadmap

| Phase | Initiative | Expected Impact |
|---|---|---|
| **Phase 1: Transaction Batching in SQLite** | Wrap `state.intent` and `state.rowDone` within a single SQLite transaction per binlog group, or retain row intents only in qualification/debug mode. | Eliminates `2N` SQLite autocommit writes per transaction. 5x–10x reduction in local disk IOPS. |
| **Phase 2: Target Verification Modes** | Introduce an application mode flag (e.g. `--verify-row-images=none\|strict`). In normal running mode, rely on standard MySQL constraint checks and affected-row counts rather than reading back every row before and after mutation. | Reduces network roundtrips from `3N + 7` to `1` batch query per group. Major latency reduction. |
| **Phase 3: Schema Metadata Caching** | Cache verified table schema and index validity for a configurable TTL or until DDL events invalidate the cache, rather than querying `information_schema` on every transaction. | Eliminates 5–6 round-trips per transaction group. |
| **Phase 4: Reader/Applier Decoupling** | Decouple `LiveInspection` capture from `ApplyRun` applier via an asynchronous ring buffer or persistent relay log reader. Capture streams at wire speed; applier consumes asynchronously from local relay. | Source network stalls are completely decoupled from target latency. |
| **Phase 5: Zero-Copy Raw Payloads** | Pass raw binlog byte slices directly via `ByteBuffer` / pointer slices into `relay.frames` instead of round-tripping through base64 strings and `JSONSerialization`. | Eliminates significant CPU and memory allocations on the ingest loop. |

---

## 4. Open Source Readiness Assessment (`GannettDigital`)

To publish `mysql-replicator` as a clean, production-grade open-source repository under `GannettDigital`, the following items must be addressed:

### A. Repository Hygiene & Licensing
- [ ] **Root `LICENSE` File:** The repository currently lacks a top-level `LICENSE` file. A standard permissive license (e.g., Apache 2.0 or MIT) should be added at the root.
- [ ] **Third-Party Attribution & `NOTICE`:** Document vendored/linked dependencies:
  - `Vendor/mysql-nio` (Apache 2.0)
  - `rust/mysql_common` (Apache 2.0 / MIT)
  - Pinned SQLite amalgamation (Public Domain / Blessing)
  - Apple SwiftNIO ecosystem (Apache 2.0)
- [ ] **Security & Secret Audit:** Clean. Configs and fixtures use synthetic credentials (`fixture-root-only`, `fixture-capture-only`, `fixture-apply-only`), internal-only Docker networks, and no company secrets or proprietary endpoints are present.
- [ ] **Standard Documentation:**
  - `CONTRIBUTING.md`: Workflow for issues, PRs, and running test suites.
  - `SECURITY.md`: Vulnerability reporting instructions.

### B. CI / GitHub Actions Strategy
Currently, no `.github/workflows` exist. A recommended GitHub Actions setup:
1. **Fast PR Workflow (`ci-unit.yml`):**
   - Runs on `ubuntu-latest`.
   - Uses `swiftlang/setup-swift` and `dtolnay/rust-toolchain@stable`.
   - Runs `make test` (Rust unit tests + 143 Swift tests). Turnaround: ~1–2 minutes.
   - Runs `make ddl-catalog-check`.
2. **Integration / Qualification Workflow (`ci-integration.yml`):**
   - Runs on `ubuntu-latest` with Docker Compose.
   - Uses the new incremental runners:
     - `make ubuntu-smoke` (verifies static musl build and Ubuntu 16.04 userland execution).
     - `make dml-suite ARGS='--slice basic'` (verifies basic DML against live containers).
     - `make ddl-suite ARGS='--slice modify-index --positioning gtid'` (verifies DDL).
   - Turnaround: ~5–8 minutes.

---

## 5. Debian Packaging (`.deb`) Strategy

### Requirements
- Build a `.deb` package containing the statically linked `mysql-replicator` binary.
- Support local execution via `make` (cross-platform, functional on macOS via Docker).
- Reusable in GitHub Actions without separate scripting.

### Current Packaging Foundation
- The repository already has `docker/packaging/Dockerfile` and `packaging/Makefile`, which build a completely self-contained, statically linked x86_64 Linux musl binary (`/out/mysql-replicator`).
- Checks verify:
  - `! readelf -l /out/mysql-replicator | grep -q INTERP` (no dynamic ELF interpreter).
  - `! readelf -d /out/mysql-replicator | grep -q NEEDED` (zero dynamic shared library dependencies).
- This binary can run on any Linux distribution (Ubuntu 16.04+, Debian 10+, RHEL, etc.).

### Proposed `.deb` Architecture
1. **Package Layout:**
   ```
   mysql-replicator_VERSION_amd64/
   ├── DEBIAN/
   │   ├── control
   │   └── conffiles
   ├── usr/
   │   └── bin/
   │       └── mysql-replicator (mode 0755)
   ├── etc/
   │   └── mysql-replicator/
   │       └── apply.example.json (mode 0644)
   └── lib/
       └── systemd/
           └── system/
               └── mysql-replicator.service (mode 0644)
   ```
2. **`packaging/Makefile` Additions:**
   Add a `package-deb` target that:
   - Creates the staging tree.
   - Generates `DEBIAN/control` populated with package metadata and version.
   - Invokes `dpkg-deb --build --root-owner-group /out/staging /out/mysql-replicator_$(VERSION)_amd64.deb`.
3. **Local & CI Integration via Docker:**
   Add a top-level `Makefile` target:
   ```make
   .PHONY: deb
   deb:
   	docker build --platform linux/amd64 --target deb-export -f docker/packaging/Dockerfile --output type=local,dest=artifacts/deb .
   ```
   - On macOS or Linux, running `make deb` utilizes BuildKit to output `artifacts/deb/mysql-replicator_<version>_amd64.deb`.
   - In GitHub Actions:
     ```yaml
     - name: Build Debian Package
       run: make deb
     - name: Upload Debian Artifact
       uses: actions/upload-artifact@v4
       with:
         name: deb-package
         path: artifacts/deb/*.deb
     ```
