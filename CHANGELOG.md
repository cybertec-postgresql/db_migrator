# Version 1.1.0 #

## Enhancements: ##

- Add `mssql_migrator` to the README.

- Add support for migrating partial indexes using a new `where_clause` column
  in the `indexes` foreign table.  
  Patch by Florent Jardin.

- Factor out `db_migrate_indexes` from `db_migrate_constraints`.  
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
