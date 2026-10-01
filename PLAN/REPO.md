Context:

  we have a created a mysql-replication, a binary that can read mysql binary log and apply changes to the tareget database.
  The primary reason is to be able to support replication accross incompatible mysql versions or dialects.

  Current state of the code base is not clean - it contains changes to support:

  - targeted runs of test suites
  - changes to support a binlog filteringm, similar to mysql Replicate_Wild_Ignore_Table 

  At this point the replicator has enough code to support basic crud (w/out r) and DDL 
  but may still have gaps in some cases functionally, and performance is not proven yet.

  Read git history for context.

TASK:

  A We need to perform two code reviews.

    - Review the current changes, if acceptable, commit them, look up git commit history for commit message style
     The goal here is to make repo clean for further changes. Issues can be addressed later.


    - Conduct a through code review, mainly to identify the state of the project and possible best next steps.
    My recomendation would be to access performace profile, like how do we pull and apply binlog and keep records in local sqlite.
    It should be done in performant way, if there are issues, create review notes under PLAN/

  
    - Access readiness to publish the code as opensourece repo, under GannettDigital .  We would need to review README
     and other docs, and figure out what we can do to run test suite (s) in github actions.


   - Access packaging as .deb , look at test suites, how binary is build and added to the container. 
     Ideally we can have a way to package .deb that runs locally, simialr to other test suites and make sure the same make command can be reused in GHA
     to create and publish .deb 
   



