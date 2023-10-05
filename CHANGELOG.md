# Version 1.1.0 #

## Enhancements: ##

- Add `mssql_migrator` to the README.

- Add support for migrating partial indexes using a new `where_clause` column
  in the `indexes` foreign table.  
  Patch by Florent Jardin.

- Factor out `db_migrate_indexes` from `db_migrate_constraints`.  
  Patch by Florent Jardin.

- Add a regression test suite based on pgTAP.  
  Patch by Florent Jardin.

- Add low-level function `execute_statements()` used by others methods to
  populate the `log_migrate` table on failed statements.  
  Patch by Florent Jardin.

- Make the extension non-relocatable.  
  This simplifies the code and should not be a problem: you can always drop and
  re-create the extension if you want it in a different schema.  
  Patch by Florent Jardin.

- Add a set of low-level statements functions to separate statement construction
  from statement execution in migration functions.  Third-party tools can use
  the output of these statements to parallelize index and constraint creation.  
  Patch by Florent Jardin.

## Bugfixes: ##

- Call the translation function on expressions in the partitioning key.  
  Patch by Florent Jardin.

- Call the translation function on index expressions.  
  Patch by Florent Jardin.

# Version 1.0.0, released 2023-02-08 #

## Enhancements: ##

- Add support for migrating partitioned tables.  
  Patch by Florent Jardin.
