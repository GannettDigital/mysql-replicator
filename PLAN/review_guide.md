## Pre requosites

### MySQL replication

MySQL uses logial replication, primary database records validated change statements in sql-like format in to a compressed log file referred to as binary log, binlog for short.
GTID mode adds transcation boundaries metadata to that log. Server maintains applied current log file offset, also known as position, and applied GTID set, to indicate what transactions have been applied to the primary.

Replicas download those binary log files, read them and apply change statements from those files on the replica. This is done sequentially, and in most mysql versions, replication is a single thread, that acts similar to mysql
client contionely applying trx in a loop.

In practice this reoliucation system is very efficient and operationally convient, for example, you can replicate older database to a newver version, proving an up to date replica ready for an upgrade.
Performance whise, replicas can keep up withreally busy databases withj 10k tps or more.

ref (old) http://doc.docs.sk/mysql-refman-5.5/replication-implementation-details.html?lang=sk
ref (new) https://dev.mysql.com/doc/refman/9.7/en/replication-implementation.html

### Notes on perforamce

Because mysql replication is transactional, it relies on single-thread sequentioanl production on binary log on the primary. No amount of parallization and what not, cannot help this case, as trx have to be applied on the replica
in exatly the same order to main data consitency,

CDC systems capture binlog and then post data to a highly disyrbiuted systems, like Kafka queue, pubsub, or cloud datawatehouses like BQ, or Snowflake - those can accept writes in parallel, so benefit from parallelization.

Thus reploication performance profile is dominated by single thread apply seepd, which is bounded by network latency. If applier is 20ms way from the db, it adds 20ms to EVERY transaction.  We can have up to 10k tps on the businesest database ...


## Implenation details


### Target implemenation profile

Since we are applyinh trx sequentiually and the pergormance is dominayed by latency between trx, it's best to model mysql replication implenenatuon - download binary logs from ghe primary and apply them on to the replica,
ruuning as close as possible to the replica.

### Details 

So, what we want is a native binary app, that can emulate a  mysql replication thread, just outside of the database.  MySQL re-uses mysql prvimtes which bound to specific version, so older verions cannot accept binlog from the newver versuons.
If we use independent ninlog decoding and  mysql clint code, we can pertty much re-implement binliog pulling and applying outsoide of mysql

- Since the perfirnance requires a native langue impolemebnatuonm, I used swift, as it the lang I know from some macOS developement.  It is  a memery save language, somewht close to rust in perfomacne prifile.
- Because of the above, Swift provides a good interop with other natice code, swift can import native libs from C or Rust or wise versa.
- Rust mysql_common packahe along witn some rust and C code to expose objects to Swift -- see `rust/src/`
- Swift implemens a small modification to mysql driver to pull binlogs and then apply them to mysqk target.
- Because we are dealing with non-transcatuon database MySIAM, the choice is to have a durable data store for the current poistion, i.e. we need a transcational guarannee for the positiin markl. The easit is to use sqlite.

Swift is used in this repo scriptoing languge, all tasks that are typocally wriiten in shell or python, like harness code or buold scriupts are written in Swift.

### Traget deploymeny and opearyion profile

Ideally we want to deploy right on the replica serveres, to get as close as possible to the place where we apply trx, so we build a 'fat' (i.e. all dependent libs included ) binary using MUSL C libarary, so the binary is not dependnt specific libc provided by linx distro, meaninh the same bianry can work on unbuntu, debian, RHEL, Liunux From Scrach, , etc.


Also, we want to build someghing that opeartes simioalr to mysql, i.e. we can start/stop using a command, skip broken trx and check the state by looking into a database.

### Code review

Sources/ReplicatorCLI/main.swift is the entry ppoint
Sources/ReplicatorApply/ implememys apply loop and various features lkie DDL implemention or apply filter.

### Testing

unit tests, obisuly.

end-to-end style test using the following test harness
 - Source:  MySQL 8.4 InnoDB Docker - primary
 - Native:  MySQL 8.4 MyISAM Docker - replica feed by native mysql replication
 - MySQL57: MySQL 5.7 MyISAM Docker - replica feed by mysql-replicator
 - fixture: Ubuntu 16.04 - running mysql-replicator

Tests run SQL against the source and compare data and logs on Native and MySQL57, as well as checking binlogs produced by replicas, this way can compare whenever the behavirs and data are the same


### AI ... 

Obvisolsy, I cannot write that much code quicklym but asking codex to write mysql-replicar using mysql_common rust lib and use mysql server code as a reference ... and a test harness to check that everything works end to end
 - this setup produces a working code.

Additiobally, mysql-server code contains a decent test suite, so asking codex to build coverage following mysql server test code is a decent approach.


