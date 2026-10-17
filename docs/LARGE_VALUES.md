# Large TEXT and BLOB values

The applier reads complete row events. It does not split a column value or commit
parts of a source transaction separately. TEXT and BLOB values have no separate
1 MiB limit. The declared column type and the limits below apply.

## Event and transaction limits

Set these values in the `source` section. They apply to `run` and `replay`.

```yaml
source:
  maximumEventBytes: 67108864         # 64 MiB; default
  maximumTransactionBytes: 268435456  # 256 MiB; default
```

`maximumEventBytes` permits 23 bytes through 1 GiB. It includes the binlog event
header and checksum. `maximumTransactionBytes` limits the total binlog bytes in
one transaction. It must be at least the event limit and at most 1 GiB.
Restart the process to change these settings. Configuration reload does not
change them.

A row event can contain several rows. With `binlog_row_image=FULL`, an UPDATE
contains both the old and new row. An update to a 20 MiB value can thus need an
event limit above 40 MiB. Allow space for the other columns and event headers.

The decoder also limits the row count and column count. The transaction assembler
limits retained data to four times the transaction byte limit. This is not a
process memory limit. Decoding, SQL parameters, TLS, and recovery inspection can
make additional copies. The process does not allocate the configured limit at
startup.

The download cache and apply queue can each admit one large item when empty.
That item remains subject to the event or transaction limit. Before execution of
a large transaction, the applier drains previously prepared work. The relay
storage limit is separate. Allow enough relay space for events and their metadata.

## Target packet limit

The applier uses an ordinary MySQL client connection. It reads the target's
`max_allowed_packet` setting when it connects. It checks each SQL request against
that limit before it sends the request. For example, a DBA can set:

```sql
SET GLOBAL max_allowed_packet = 67108864;
```

The new setting applies to new connections. Set the server startup configuration
too if the setting must survive a restart. If replication is already `BLOCKED`,
inspect the pending transaction and use the recovery procedure before retrying.
Earlier statements in a MyISAM transaction can already have changed data.

`batch.maximumInsertBytes` controls how the applier groups rows in an INSERT.
It does not split a single large row. The target packet limit still applies.

The client splits a large protocol message into physical packets of at most
16,777,215 bytes. It reassembles response packets before it reads a returned row.
It checks continuation sequence numbers and rejects truncated messages. The
maximum logical message size is 1 GiB. Protocol packets do not change transaction
boundaries.

Native replication has a separate replication packet limit. Its settings need
not match those for ordinary clients. See the
[MySQL packet-size guidance](https://dev.mysql.com/doc/mysql-replication-excerpt/5.7/en/replication-features-max-allowed-packet.html).

## Tests

Run the shared test on all four profiles:

```sh
make correctness PROFILE=all ARGS="--case large-values"
```

The test generates values on the source. It compares lengths and SHA-256 digests
on the source, native replica, and external target. It checks:

- BLOB values below, at, and above 1 MiB, and a value of 17 MiB plus three bytes.
- Multibyte TEXT values, empty values, and NULL values.
- INSERT, UPDATE, DELETE, and target reads of large row images.
- Restart from saved state and offline replay without a source connection.
- Rejection at a configured event limit and at the target packet limit.
- InnoDB pending-row inspection and explicit retry after the target packet limit
  is increased. MyISAM checks refusal of an unsafe restart and manual
  reconciliation in separate test state; it does not use InnoDB recovery commands.

Unit tests also check exact protocol packet boundaries, sequence-number wrap,
and malformed input. These tests do not qualify 1 GiB values or unbounded
transactions.
