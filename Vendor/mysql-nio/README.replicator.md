# MySQLNIO vendoring

Source: https://github.com/vapor/mysql-nio, version 1.9.1, commit
`7fa853040169b604a16b963f23b481772f4ac181`. This directory retains the upstream
Package.swift, MIT LICENSE, Sources and Tests. `provenance.json` records upstream
and vendored file hashes; `replicator.patch` is the complete code delta.

The live reader needs mandatory TLS **before authentication**. Upstream's optional
TLS configuration permits a server without CLIENT_SSL to continue authentication.
The patch adds an opt-in `requireTLS` connection argument and rejects that handshake
before writing authentication. Existing callers retain their default behavior.
It also adds an optional handshake timeout and a ten-second TCP connect timeout;
the capture caller requests a ten-second handshake deadline.

Dump framing and commands remain in ReplicatorCapture. After authentication it
replaces the packet decoder to validate sequences, assemble multipart responses
and bound allocations. The upstream TLS/authentication/command lifecycle remains
in use. No Rust network client is introduced.

Root SwiftPM pins the resolved transitive dependencies. Root capture tests exercise
the actual vendor handshake handler's TLS rejection and a silent-server timeout.
Upstream Tests are retained for provenance; root `swift test` does not run that
separate package's full test suite. The real live suite exercises caching_sha2
password authentication over verified TLS with MySQL 8.4.8.

The applier also opts into `cachedQuery`: at most 128 prepared statements per
connection, accessed only on its event loop. Cache hits execute with fresh binary
bindings and parse fresh result metadata. New SQL beyond the limit uses the
ordinary prepare/execute/close path. SQL errors close and evict that statement;
there is no automatic retry. `clearPreparedStatementCache` is an awaited command
barrier that closes each server statement before DDL/session changes. Connection
closure releases all remaining server statements, including uncertain commands.
The default `query` API still uses prepare/execute/close.

Root protocol tests cover reuse, bindings, affected-row metadata, error eviction,
capacity and isolation. DML/DDL integration tests exercise exact binary/unsigned
values, schema changes and fail-stop behavior with the cached path enabled.
