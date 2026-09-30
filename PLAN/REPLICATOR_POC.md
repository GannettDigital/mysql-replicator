
context:

 In previous commits we have build a mysql consumer for maxwell daemon / pubsub to replicate mysql 8.4 database to mysql 5.7
 We have prooved that this is possible in principle, and included evidence

 See `git log` and associated context



  Now, our target env is somewhat busy CloudSQL databases eventually running 8.4 (it;s currenly 5.7).
  There are 22 of those databases, each of those has a corresponding MyISAM MySQL 5.7 replica running on-prem.

  The stats from the busiest database are below 


  ```text
   5.7.44-google-log)                                                                                                                                                                                up 99+17:41:32 [19:49:51]
 Queries: 29.3G  qps: 3652 Slow:     0.0         Se/In/Up/De(%):    34/04/01/01
             qps now: 1112 Slow qps: 0.0  Threads: 10977 (   7/  22) 40/01/01/01
 Key Efficiency: 94.0%  Bps in/out:  3.5M/ 3.8M   Now in/out: 245.9k/ 1.0M
 ```

 The trx volume can grow to 10-12 K qps , depending on time of day.

 We are planning to keep the same replicas on-perm on 5.7 and switch to alrernative replication method to keep them going, while we will be upgrading CloudSQL to 8.4


 The maxwell consumer POC works, but maxwell->pubsub->consumer->mysql target, however for our purpose we do not really benefit from binlog data passing via maxwell and pubsub.  Pubsub is good when
 we would like to feed some external system from database update data, like new row added to customers table, we start on-boarding, or something along those lines.

 For strictly replicating , potentially we could just run a binary directly on replica .... pulling binlogs from cloudsql primary is relatevly simple non transcantional operation, and it's not affected by network latency fluctuations that much,
 but writing events to target mysql is transanctional and that will be affected by network latency.

 So, possibly we can have "mysql-replicator" swift binary that pulls from mysql primary , and then decode and apply those binlogs in trx way, and just keep the current status of applied GTID or binlog positions - essentially
 simialr to how mysql replication thread works, just outside of mysql database.

 TASK:

 review the above context, clone mysql 5.7 , 8.4 code bases, possibly maria db as well and a few mysql binlog readers like go-binlog and similar rust-based lib 
 and asses a viablity of building such binary in swift.

 deliverable:  a planning doc to build such tooling in phases, starting with initial phase to build a harness, and final phases that include full on testing, similar how we did that for maxwell mysql consumer.  


Accepted scope clarification: database dump/load management, including parallel MySQL Shell export/import, remains entirely external. The replicator assumes an already prepared target and accepts a known source file/position or executed GTID set with matching historical schema and scope. It does not parse/modify/load database dumps or manage target provisioning. See [START_BOUNDARY.md](START_BOUNDARY.md).
