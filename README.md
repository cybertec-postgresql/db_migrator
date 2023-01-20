Tools for migrating other databases to PostgreSQL
=================================================

`db_migrator` is a PostgreSQL [extension][ext] that provides functions for
migrating databases from other data sources to PostgreSQL.
This requires a [foreign data wrapper][fdw] for the data source you
want to migrate.

You also need a plugin for `db_migrator` that contains the code specific
to the targeted data source.
Currently, plugins exist for the following data sources:

- **Oracle**: [`ora_migrator`][ora_migrator]

See the section [Plugin API](#plugin-api) below if you want to develop a
plugin (I'd be happy to add it to the list above).

See [Setup](#setup) below for installation instructions,
[Architecture](#architecture) so that you understand what is going on and
[Usage](#usage) for instructions how to best migrate a database.

 [ext]: https://www.postgresql.org/docs/current/extend-extensions.html
 [fdw]: https://www.postgresql.org/docs/current/ddl-foreign-data.html
 [ora_migrator]: https://github.com/cybertec-postgresql/ora_migrator

Showcase
========

This is a complete example of a simple migration of an Oracle database
using the `ora_migrator` plugin.

A superuser sets the stage:

    CREATE EXTENSION oracle_fdw;

    CREATE SERVER oracle FOREIGN DATA WRAPPER oracle_fdw
       OPTIONS (dbserver '//dbserver.mydomain.com/ORADB');

    GRANT USAGE ON FOREIGN SERVER oracle TO migrator;

    CREATE USER MAPPING FOR migrator SERVER oracle
       OPTIONS (user 'orauser', password 'orapwd');

PostgreSQL user `migrator` has the privilege to create PostgreSQL schemas
and Oracle user `orauser` has the `SELECT ANY DICTIONARY` privilege.

Now we connect as `migrator` and perform the migration so that all objects
will belong to this user:

    CREATE EXTENSION ora_migrator;

    SELECT db_migrate(
       plugin => 'ora_migrator',
       server => 'oracle',
       only_schemas => '{TESTSCHEMA1,TESTSCHEMA2}'
    );

    NOTICE:  Creating staging schemas "fdw_stage" and "pgsql_stage" ...
    NOTICE:  Creating foreign metadata views in schema "fdw_stage" ...
    NOTICE:  Creating schemas ...
    NOTICE:  Creating sequences ...
    NOTICE:  Creating foreign tables ...
    NOTICE:  Migrating table testschema1.baddata ...
    WARNING:  Error loading table data for testschema1.baddata
    DETAIL:  invalid byte sequence for encoding "UTF8": 0x00: 
    NOTICE:  Migrating table testschema1.log ...
    NOTICE:  Migrating table testschema1.tab1 ...
    NOTICE:  Migrating table testschema1.tab2 ...
    NOTICE:  Migrating table testschema2.tab3 ...
    NOTICE:  Creating UNIQUE and PRIMARY KEY constraints ...
    WARNING:  Error creating primary key or unique constraint on table testschema1.baddata
    DETAIL:  relation "testschema1.baddata" does not exist: 
    NOTICE:  Creating FOREIGN KEY constraints ...
    NOTICE:  Creating CHECK constraints ...
    NOTICE:  Creating indexes ...
    NOTICE:  Setting column default values ...
    NOTICE:  Dropping staging schemas ...
    NOTICE:  Migration completed with 2 errors.
     db_migrate 
    ------------
              2
    (1 row)

Even though the migration of one table failed because of bad data in
the Oracle database, the rest of the data were migrated successfully.

Setup
=====

Prerequisites
-------------

### Foreign Data Wrapper ###

You need to install the foreign data wrapper for the data source from which
you want to migrate.  Follow the installation instructions of that
software.  A [list of available foreign data wrappers][fdw-list] is available
in the PostgreSQL Wiki.

 [fdw-list]: https://wiki.postgresql.org/wiki/Fdw

You need to define these objects:

- a foreign server that describes how to connect to the remote data source

- a user mapping for the server to provide credentials for the user that
  performs the migration

### Permissions ###

You need a database user with

- the `CREATE` privilege on the current database

- the `USAGE` privilege on the schemas where the extensions are installed

- the `USAGE` privilege on the foreign server

- `EXECUTE` privileges on all required migration functions (this is
  usually granted by default)

The permissions can be reduced once the migration is complete.

### `db_migrator` plugin ###

You also need to install the `db_migrator` plugin for the data source from
which you want to migrate.  Again, follow the installation instructions
provided with the software.

Installation
------------

The extension files must be placed in the `extension` subdirectory of
the PostgreSQL shared files directory, which can be found with

    pg_config --sharedir

If the extension building infrastructure PGXS is installed, you can do that
simply with

    make install

The extension is installed in the database to which you want to migrate the
data with the SQL command

    CREATE EXTENSION db_migrator;

This statement can be executed by any user with the right to create
functions in the `public` schema (or the schema you specified in the
optional `SCHEMA` clause of `CREATE EXTENSION`).

Architecture
============

`db_migrator` uses two auxiliary schemas, the "FDW staging schema" and the
"Postgres staging schema".  The names are `fdw_stage` and `pgsql_stage` by
default, but you can choose different names.

In a first step, `db_migrator` calls the plugin to populate the FDW stage
with foreign tables that provide information about the metadata of the remote
data source in a standardized way (see [Plugin API](#plugin-api) for details).

In the second step, the data are copied to tables in the Postgres stage,
resulting in a kind of snapshot of the data in the FDW stage.  These tables
are described in detail at the end of this chapter.  During this snapshot,
table and column names may be translated using a function provided by the
plugin.  The plugin also provides a default mapping of remote data types to
PostgreSQL data types.

As a next step, the user modifies the data in the Postgres stage to fit
the requirements for the migration (different data types, edits to function
and view definitions etc.).  This is done with updates to the tables in the
Postgres stage.  Also, most tables have a `boolean` column `migrate` that
should be set to `TRUE` for all objects that should be migrated.

The next step is to create schemas in the PostgreSQL database and populate
them with foreign tables that point to the objects in the remote data
source.  These tables are then "materialized", that is, local tables are
created, and the data from the foreign tables is inserted into the local
tables.

Then the other objects and finally the indexes and constraints can be
migrated.

Once migration is complete, the FDW stage and the PostgreSQL stage (and the
foreign data wrapper) are not needed any more and can be removed.

Tables in the Postgres staging schema
-------------------------------------

Only edit the columns that are indicated.  For example, it you want to change
a schema or table name, it is better to rename the schema or table once you
are done with the migration.

### `schemas` ###

- `schema` (type `name`): name of the schema

- `orig_schema` (type `text`): schema name as used in the remote data source

### `tables` ###

- `schema` (type `name`): schema of the table

- `table_name` (type `name`): name of the table

- `orig_table` (type `text`): table name as used in the remote data source

- `migrate` (type `boolean`, default `TRUE`): `TRUE` if the table should
  be migrated

  Modify this column if desired.

### `columns` ###

- `schema` (type `name`): schema of the table containing the column

- `table_name` (type `name`): table containing the column

- `column_name` (type `name`): name of the column

- `column_options` (type `jsonb`): plugin-specific column options

- `orig_column` (type `text`): column name as used in the remote data source

- `position` (type `integer`): defines the order of the columns (1 for the
  first column)

- `type_name` (type `text`): PostgreSQL data type (including type modifiers)

  Modify this column if desired.

- `orig_type` (type `text`): data type in the remote data source

- `nullable` (type `boolean`): `FALSE` if the column is `NOT NULL`

  Modify this column if desired.

- `default_value` (type `text`):

  Modify this column if desired.

### `checks` (check constraints) ###

- `schema` (type `name`): schema of the table with the constraint

- `table_name` (type `name`): table with the constraint

- `constraint_name` (type `name`): name of the constraint

- `orig_name` (type `text`): name of the constraint in the remote data source

- `deferrable` (type `boolean`): `TRUE` if the constraint can be deferred

  Modify this column if desired.

- `deferred` (type `boolean`): `TRUE` if the constraint is `INITIALLY DEFERRED`

  Modify this column if desired.

- `condition` (type `text`): condition to be checked

  Modify this column if desired.

- `migrate` (type `boolean`, default `TRUE`): `TRUE` if the constraint should
  be migrated

  Modify this column if desired.

### `keys` (columns of primary and unique keys) ###

- `schema` (type `name`): schema of the table with the constraint

- `table_name` (type `name`): table with the constraint

- `constraint_name` (type `name`): name of the constraint

- `orig_name` (type `text`): name of the constraint in the remote source

- `deferrable` (type `boolean`): `TRUE` if the constraint can be deferred

  Modify this column if desired.

- `deferred` (type `boolean`): `TRUE` if the constraint is `INITIALLY DEFERRED`

  Modify this column if desired.

- `column_name` (type `name`): name of a column that is part of the key

- `position` (type `integer`): defines the order of columns in the constraint

- `is_primary` (type `boolean`): `TRUE` if this is a primary key

- `migrate` (type `boolean`, default `TRUE`): `TRUE` if the constraint should
  be migrated

  Modify this column if desired.

### `indexes` ###

- `schema` (type `name`): schema of the table with the index

- `table_name` (type `name`): table with the index

- `index_name` (type `name`): name of the index

- `orig_name` (type `text`): name of the index in the remote source

- `uniqueness` (type `boolean`): `TRUE` if this is a unique index

  Modify this column if desired.

- `migrate` (type `boolean`, default `TRUE`): `TRUE` if the constraint should
  be migrated

  Modify this column if desired.

### `index_columns` ###

- `schema` (type `name`): schema of the table with the index

- `table_name` (type `name`): table with the index

- `index_name` (type `name`): name of the index

- `position` (type `integer`): determines the index column order

- `descend` (type `boolean`): `TRUE` if the index column is sorted `DESC`

  Modify this column if desired.

- `is_expression` (type `boolean`): `TRUE` if the index column is an
  expression rather than a column name

- `column_name` (type `text`): name of the column or indexed expression
  (expressions usually must be surounded with parentheses)

  Modify this column if desired.

### `partitions` ###

- `schema` (type `name`): schema of the partitioned table

- `table_name` (type `name`): name of the partitioned table

- `partition_name` (type `name`): name of the partition

- `orig_name` (type `name`): name of the partition in the remote source

- `type` (type `text`): one of the supported partitioning methods `LIST`,
  `RANGE` or `HASH`

- `expression` (type `text`): partitioning expression used to define a table's
  partitioning

- `position` (type `integer`): defines the order of the table partitions (must
  start at 1)

- `values` (type `text`): for a `RANGE` method, contains the upper bound value,
  for a `LIST` method, contains a list of comma-separated values

- `is_default` (type `boolean`, default `FALSE`); `TRUE` if it is the default
  partition 

- `migrate` (type `boolean`, default `TRUE`): `TRUE` if the partition should
  be migrated

### `subpartitions` ###

- `schema` (type `name`): schema of the partitioned table

- `table_name` (type `name`): name of the partitioned table

- `partition_name` (type `name`): name of the parent partition

- `subpartition_name` (type `name`): name of the subpartition

- `orig_name` (type `name`): name of the subpartition in the remote source

- `type` (type `text`): one of the supported partitioning methods `LIST`,
  `RANGE` or `HASH`

- `expression` (type `text`): partitioning expression used to define a table's
  composite partitioning

- `position` (type `integer`): defines the order of the table subpartitions
  (must start at 1)

- `values` (type `text`): for a `RANGE` method, contains the upper bound value,
  for a `LIST` method, contains a list of comma-separated values

- `is_default` (type `boolean`, default `FALSE`); `TRUE` if it is the default
  subpartition 

- `migrate` (type `boolean`, default `TRUE`): `TRUE` if the partition should
  be migrated

### `views` ###

- `schema` (type `name`): schema of the table with the view

- `view_name` (type `name`): name of the view

- `definition` (type `text`): SQL statement defining the view

  Modify this column if desired.

- `orig_def` (type `text`): view definition on the remote data source

- `migrate` (type `boolean`, default `TRUE`): `TRUE` if the constraint should
  be migrated

  Modify this column if desired.

- `verified` (type `boolean`): can be used however you want

  This may be useful to store if the view has been translated successfully.

### `sequences` ###

- `schema` (type `name`): schema of the sequence

- `sequence_name` (type `name`): name of the sequence

- `min_value` (type `bigint`): minimal value for the generated value

  Modify this column if desired.

- `max_value` (type `bigint`): maximal value for the generated value

  Modify this column if desired.

- `increment_by` (type `bigint`): difference between generated values

  Modify this column if desired.

- `cyclical` (type `boolean`): `TRUE` if the sequence "wraps around"

  Modify this column if desired.

- `cache_size` (type `integer`): number of sequence values cached on the
  client side

  Modify this column if desired.

- `last_value` (type `bigint`): current position of the sequence

  Modify this column if desired.

- `orig_value` (type `bigint`): current position on the remote data source

### `functions` (functions and procedures) ###

- `schema` (type `name`): schema of the function or procedure

- `function_name` (type `name`): name of the function or procedure

- `is_procedure` (type `boolean`): `TRUE` if it is a procedure

  Modify this column if desired.

- `source` (type `text`): source code of the function or procedure

  Modify this column if desired.

- `orig_source` (type `text`): source code on the remote data source

- `migrate` (type `boolean`, default `FALSE`): `TRUE` is the object should
  be migrated

  Modify this column if desired.
  Note that since the default value is `FALSE`, functions and procedures will
  not be migrated by default.

- `verified` (type `boolean`): can be used however you want

  This may be useful to store if the source code has been translated
  successfully.

### `triggers` ###

- `schema` (type `name`): schema of the table with the trigger

- `table_name` (type `name`): name of the table with the trigger

- `trigger_name` (type `name`): name of the trigger

- `trigger_type` (type `text`): `BEFORE`, `AFTER` or `INSTEAD OF`

  Modify this column if desired.

- `triggering_event` (type `text`): `INSERT`, `UPDATE`, `DELETE`
  or `TRUNCATE` (if more than one, combine with `OR`)

  Modify this column if desired.

- `for_each_row` (type `boolean`): `TRUE` if the trigger is executed
  for each modified row rather than once per triggering statement

  Modify this column if desired.

- `when_clause` (type `text`): condition for the trigger execution

  Modify this column if desired.

- `trigger_body` (type `text`): the function body for the trigger

  Modify this column if desired.

- `orig_source` (type `text`): the trigger source code on the remote
  data source

- `migrate` (type `boolean`, default `FALSE`): `TRUE` if the trigger should
  be migrated

  Modify this column if desired.
  Note that since the default value is `FALSE`, functions and procedures will
  not be migrated by default.

- `verified` (type `boolean`): can be used however you want

  This may be useful to store if the trigger has been translated successfully.

### `table_privs` (permissions on tables) ##ä

These are not migrated by `db_migrator`, but can be used by the migration
script to migrate permissions.

- `schema` (type `name`): schema of the table with the privilege

- `table_name` (type `name`): name of the table with the privilege

- `privilege` (type `text`): name of the privilege

- `grantor` (type `name`): user who granted the privilege

- `grantee` (type `name`): user who receives the permission

- `grantable` (type `boolean`): `TRUE` if the grantee can grant the privilege
  to others

### `column_privs` (permissions on table columns) ###

These are not migrated by `db_migrator`, but can be used by the migration
script to migrate permissions.

- `schema` (type `name`):

- `table_name` (type `name`):

- `column_name` (type `name`):

- `privilege` (type `text`):

- `grantor` (type `name`):

- `grantee` (type `name`):

- `grantable` (type `boolean`):

Usage
=====

The database user that performs the migration will be the owner of all
migrated schemas and objects.  Ownership can be transferred once migration
is complete.  Permissions on database objects are not migrated (but the
plugin may offer information about the permissions on the data source).

There is no special support for translating procedural code (functions,
procedures and triggers), you will have to do that yourself.

For very simple cases (no stored procedures or triggers to migrate, all
views in standard SQL, no data type adaptions required) you can simply call
the `db_migrate` function to migrate the database schemas you want.

For more complicated migrations, you will compose an SQL script that
does the following (or parts thereof):

- Call `db_migrate_prepare` to create and populate the FDW and Postgres
  staging schemas (see [Architecture](#architecture) for details).

- Now you can update the tables in the Postgres stage to change data
  types, stored procedure code, views and similar.
  This is also the time to set the `migrate` flag in the tables in the
  Postgres stage to indicate which objects should be migrated and which
  ones not.

- At any given point before you call `db_migrate_mkforeign`, you can call
  `db_migrate_refresh` to update the snapshot in the Postgres stage with
  current metadata.

- Next, you call `db_migrate_mkforeign` to migrate the schemas and
  created foreign tables that point to the remote objects containing
  data that should be migrated.

- Now you can use `ALTER FOREIGN TABLE` if you need to make adjustments
  to these foreign tables.

- Next, you call `db_migrate_tables` to replace the foreign tables with
  actual PostgreSQL tables and migrate the data.  This step will usually
  take the most time.  Note that there is the option to perform a
  "schema-only" migration to test the object definitions without having
  to migrate all the data.

- If you wish to migrate such objects, you can now call the
  `db_migrate_functions`, `db_migrate_triggers` and `db_migrate_views`
  functions to migrate these objects.  If views depend on functions,
  call `db_migrate_views` last.

- Then you call `db_migrate_constraints` to migrate indexes and
  constraints for the migrated tables.  It is usually a good idea to do this
  last, since indexes and constraints can depend on functions.

- Finally, call `db_migrate_finish` to remove the FDW and Postgres staging
  schemas created by `db_migrate_prepare`.

An errors (except connection problems) that happen during database migration
will not terminate processing.  Rather, they will be reported as warnings.
Additionally, such errors are logged in the table `migrate_log` in the
PostgreSQL staging schema.

Later errors can be consequences of earlier errors: for example, any
failure to migrate an Oracle table will also make all views and constraints
that depend on that table fail.

After you are done, drop the migration extensions to remove all traces
of the migration.

Detailed description of the migration functions
-----------------------------------------------

### `db_migrate_prepare` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `server` (type `name`, required): name of the foreign server that describes
  the data source from which to migrate

- `staging_schema` (type `name`, default `fdw_stage`): name of the remote
  staging schema

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

- `only_schemas` (type `name[]`, default all schemas): list of schemas to
  migrate

  These must be written exactly like they are on the remote data source.

- `options` (type `jsonb`, optional): options to pass to the plugin

  Consult the documentation of the plugin for available options.

This function must be called first.  It creates the staging schemas.
The remote staging schema is populated by the plugin.  `db_migrate_refresh`
is called to create a snapshot of the remote stage in the Postgres stage.

### `db_migrate_refresh` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `staging_schema` (type `name`, default `fdw_stage`): name of the remote
  staging schema

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

- `only_schemas` (type `name[]`, default all schemas): list of schemas to
  migrate

You can call this function to refresh the Postgres stage with a new
snapshot of the remote stage.  This will work as long as no objects on the
remote data source are renamed or deleted (adding tables and columns will
work fine).  Edits made to the Postgres stage will be preserved.

### `db_migrate_mkforeign` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `server` (type `name`, required): name of the foreign server that describes
  the data source from which to migrate

- `staging_schema` (type `name`, default `fdw_stage`): name of the remote
  staging schema

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

- `options` (type `jsonb`, optional): options to pass to the plugin

  Consult the documentation of the plugin for available options.

Call this function once you have edited the Postgres stage to your
satisfaction.  It will create all schemas that should be migrated and foreign
tables for all remote tables you want to migrate.

### `db_migrate_tables` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

- `with_data` (type `boolean`, default `TRUE`): if `FALSE`, migrate everything
  but the table data

  This is useful to test the migration of the metadata.

This function calls `materialize_foreign_table` to replace all foreign tables
created by `db_migrate_mkforeign` with actual tables.
The table data are migrated unless `with_data` is `FALSE`.

### `materialize_foreign_table` ###

Parameters:

- `schema` (type `name`, required): schema of the table to migrate

- `table_name` (type `name`, required): name of the table to migrate

- `with_data` (type `boolean`, default `TRUE`): if `FALSE`, migrate everything
  but the table data

  This is useful to test the migration of the metadata.

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

This function replaces a single foreign table created by `db_migrate_mkforeign`
with an actual table.
If any partition scheme exists in `partitions` or `subpartitions` tables, table
will materialized as a partitioned table with partitions, while `migrate` are
set to `TRUE`.
The table data are migrated unless `with_data` is `FALSE`.

You don't need this function if you use `db_migrate_tables`.  It is provided as
a low-level alternative and is particularly useful if you want to migrate
several tables in parallel to improve processing speed.

### `db_migrate_functions` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

Call this to migrate functions and procedures.
Note that `migrate` is set to `FALSE` by default for functions and procedures,
so you will have to change that flag if you want to migrate functions.

### `db_migrate_triggers` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

Call this to migrate triggers.
Note that `migrate` is set to `FALSE` by default for triggers, so you will
have to change that flag if you want to migrate functions.

### `db_migrate_views` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

Call this to migrate views.

### `db_migrate_constraints` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

Call this to migrate constraints, indexes and column defaults for the
migrated tables.

This function has to run after everything else has been migrated, so that
all functions that may be needed by indexes or column defaults are
already there.

### `db_migrate_finish` ###

Parameters:

- `staging_schema` (type `name`, default `fdw_stage`): name of the remote
  staging schema

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

Call this function after you have migrated everything you need.  It will
drop the staging schemas and all their content.

### `db_migrate` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `server` (type `name`, required): name of the foreign server that describes
  the data source from which to migrate

- `staging_schema` (type `name`, default `fdw_stage`): name of the remote
  staging schema

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

- `only_schemas` (type `name[]`, default all schemas): list of schemas to
  migrate

  These must be written exactly like they are on the remote data source.

- `options` (type `jsonb`, optional): options to pass to the plugin

  Consult the documentation of the plugin for available options.

This function provides "one-click" migration by calling the other
functions in the following order:

- `db_migrate_prepare`

- `db_migrate_mkforeign`

- `db_migrate_tables`

- `db_migrate_functions`

- `db_migrate_triggers`

- `db_migrate_views`

- `db_migrate_constraints`

- `db_migrate_finish`

This provides a simple way to migrate simple databases (no user defined
functions and triggers, standard compliant view definitions, no data type
modifications necessary).

Note that it will not migrate functions and triggers, since `migrate`
is `FALSE` by default for these objects.

Plugin API
==========

A plugin for `db_migrator` must be a PostgreSQL extension and provide
a number of functions:

`db_migrator_callback`
----------------------

There are no input parameters. The output parameters are:

- `create_metadata_views_fun` (type `regprocedure`):
  the "metadata view creation function" that populates the FDW stage

- `translate_datatype_fun` (type `regprocedure`):
  the "data type translation function" that tranlates data types from the
  remote data source into PostgreSQL data types

- `translate_identifier_fun` (type `regprocedure`):
  the "identifier translation function" that translates identifier names
  from the remote data source into PostgreSQL identifiers

- `translate_expression_fun` (type `regprocedure`):
  the "expression translation function" that makes an effort at translating
  SQL expressions from the remote data source to PostgreSQL

- `create_foreign_table_fun` (type `regprocedure`):
  the "foreign table creation function" that generates an SQL string to
  define a foreign table

These functions can have arbitrary names and are described in the following.

Metadata view creation function
-------------------------------

Parameters:

- `server` (type `name`, required): the name of the foreign server whose
  metadata we want to access

- `schema` (type `name`): the name of the FDW staging schema

- `options` (type `jsonb`, optional): plugin-specific parameters

This function is called by `db_migrate_prepare` after creating the FDW
staging schema.  It has to create a number of foreign tables (or views on
foreign tables) that provide access to the metadata of the remote data
source.

If the remote data source does not provide a certain feature (for example,
if the data source has no concept of triggers), you can create an empty
table instead of the corresponding foreign table.

It is allowed to create additional objects in the FDW staging schema if
the plugin provides additional features.  Similarly, it is allowed to
provide other columns beside the ones required by the API specification.

These foreign tables or views must be created:

### table of schemas ###

    schemas (
       schema text NOT NULL
    )

### table of sequences ###

    sequences (
       schema        text    NOT NULL,
       sequence_name text    NOT NULL,
       min_value     numeric,
       max_value     numeric,
       increment_by  numeric NOT NULL,
       cyclical      boolean NOT NULL,
       cache_size    integer NOT NULL,
       last_value    numeric NOT NULL
    )

- `min_value` and `max_value` are the minimal and maximal values the
  sequence value can assume

- `last_value` is the current position of the sequence value

- `increment_by` is the difference between generated values

- `cyclical` is `TRUE` for sequences that should continue with
  `min_value` if `max_value` is exceeded

- `cache_size` is the number of sequence values cached on the client side

### table of tables ###

    tables (
       schema     text NOT NULL,
       table_name text NOT NULL
    )

### table of columns of tables and views ###

    columns (
       schema        text    NOT NULL,
       table_name    text    NOT NULL,
       column_name   text    NOT NULL,
       position      integer NOT NULL,
       type_name     text    NOT NULL,
       length        integer NOT NULL,
       precision     integer,
       scale         integer,
       nullable      boolean NOT NULL,
       default_value text
    )

Note that this table has to contain columns for both the `tables`
and the `views` table.

- `position` defines the order of the table columns

- `length` denotes the length limit for variables length data types
  like `character varying`

  Set this to 0 for data types that have fixed length or where
  `precision` and `scale` apply.

- `precision` denotes the number of significant digits for numeric
  data types of variables size

- `scale` denotes the maximum number of significant digits after
  the decimal point for numeric data types of variable size

- `default_value` is the SQL expression from the `DEFAULT` clause
  of the column definition

### table of check constraints ###

    checks (
       schema          text    NOT NULL,
       table_name      text    NOT NULL,
       constraint_name text    NOT NULL,
       deferrable      boolean NOT NULL,
       deferred        boolean NOT NULL,
       condition       text    NOT NULL
    )

- `constraint_name` identifies the constraint, but the name won't be migrated

- `deferrable` should be `TRUE` if the constraint execution can be
  deferred to the end of the transaction

- `deferred` should be `TRUE` if the constraint is automatically
  deferred

- `condition` is the SQL expression that defines the check constraint

  `db_migrator` will not migrate check constraints of the form
  `col IS NOT NULL`.  You should make sure that `columns.nullable` is FALSE
  for such columns.

### table of primary key and unique constraint columns ###

    keys (
       schema          text    NOT NULL,
       table_name      text    NOT NULL,
       constraint_name text    NOT NULL,
       deferrable      boolean NOT NULL,
       deferred        boolean NOT NULL,
       column_name     text    NOT NULL,
       position        integer NOT NULL,
       is_primary      boolean NOT NULL
    )

- `constraint_name` identifies the constraint, but the name won't be migrated

- `deferrable` should be `TRUE` if the constraint execution can be
  deferred to the end of the transaction

- `deferred` should be `TRUE` if the constraint is automatically
  deferred

- `position` defines the order of columns in a multi-column constraint

- `is_primary` is `FALSE` for unique constraints and `TRUE` for primary keys

For a multi-column constraint, the table will have one row per column.

### table of foreign key constraint columns ###

    foreign_keys (
       schema          text    NOT NULL,
       table_name      text    NOT NULL,
       constraint_name text    NOT NULL,
       deferrable      boolean NOT NULL,
       deferred        boolean NOT NULL,
       delete_rule     text    NOT NULL,
       column_name     text    NOT NULL,
       position        integer NOT NULL,
       remote_schema   text    NOT NULL,
       remote_table    text    NOT NULL,
       remote_column   text    NOT NULL
    )

- `constraint_name` identifies the constraint, but the name won't be migrated

- `deferrable` should be `TRUE` if the constraint execution can be
  deferred to the end of the transaction

- `deferred` should be `TRUE` if the constraint is automatically
  deferred

- `position` defines the order of columns in a multi-column constraint

For a multi-column constraint, the table will have one row per column.

### table of views ###

    views (
       schema     text NOT NULL,
       view_name  text NOT NULL,
       definition text NOT NULL
    )

- `definition` is the `SELECT` statement that defines the view

The columns of the view are defines in the `columns` table.

### table of functions and procedures ###

    functions (
       schema        text    NOT NULL,
       function_name text    NOT NULL,
       is_procedure  boolean NOT NULL,
       source        text    NOT NULL
    )

- `is_procedure` is `FALSE` for functions and `TRUE` for procedures

- `source` is the source code of the function, including the parameter list
  and the return type

### table of indexes ###

    indexes (
       schema        text    NOT NULL,
       table_name    text    NOT NULL,
       index_name    text    NOT NULL,
       is_expression boolean NOT NULL
    )

- `index_name` identifies the index, but the name won't be migrated

- `is_expression` is `FALSE` if `column_name` is a regular column name
  rather than an expression

### table of index columns ###

    index_columns (
       schema        text    NOT NULL,
       table_name    text    NOT NULL,
       index_name    text    NOT NULL,
       position      integer NOT NULL,
       descend       boolean NOT NULL,
       is_expression boolean NOT NULL,
       column_name   text    NOT NULL
    )

- `position` defines the order of columns in a multi-column index

- `descend` is `FALSE` for index columns in ascending sort order and `TRUE`
  for index columns in descending sort order

- `is_expression` is `FALSE` if `column_name` is a regular column name
  rather than an expression

- `column_name` is the indexed column name or expression

### table of partitions ###

    partitions (
        schema         name    NOT NULL,
        table_name     name    NOT NULL,
        partition_name name    NOT NULL,
        type           text    NOT NULL,
        expression     text    NOT NULL,
        position       integer NOT NULL,
        values         text,
        is_default     boolean NOT NULL
    )

- `type` is one of the supported partitioning methods `LIST`, `RANGE` or `HASH`

- `expression` is used to define a table's partitioning

- `position` defines the order of the table partitions (must start at 1)

- `values` contains the upper bound value for a `RANGE` method or a list of
  comma-separated values for a `LIST` method

- `is_default` is `TRUE` if it is the default partition 

### table of subpartitions ###

    subpartitions (
        schema            name    NOT NULL,
        table_name        name    NOT NULL,
        partition_name    name    NOT NULL,
        subpartition_name name    NOT NULL,
        type              text    NOT NULL,
        expression        text    NOT NULL,
        position          integer NOT NULL,
        values            text,
        is_default        boolean NOT NULL
    )

Same explanations as `partitions` above.

### table of triggers ###

    triggers (
       schema            text    NOT NULL,
       table_name        text    NOT NULL,
       trigger_name      text    NOT NULL,
       trigger_type      text    NOT NULL,
       triggering_event  text    NOT NULL,
       for_each_row      boolean NOT NULL,
       when_clause       text,
       trigger_body      text    NOT NULL
    )

- `trigger_type` should be `BEFORE`, `AFTER` or `INSTEAD OF`

- `triggering_event` describes the DML events that cause trigger execution,
  like `DELETE` or `INSERT OR UPDATE`

- `for_each_row` is `FALSE` for statement level triggers and `TRUE` for
  row level triggers

- `when_clause` is an SQL expression for conditional trigger execution

- `trigger_body` is the source code of the trigger

### table of table privileges ###

    table_privs (
       schema     text    NOT NULL,
       table_name text    NOT NULL,
       privilege  text    NOT NULL,
       grantor    text    NOT NULL,
       grantee    text    NOT NULL,
       grantable  boolean NOT NULL
    )

### table of column privileges ###

    column_privs (
       schema      text    NOT NULL,
       table_name  text    NOT NULL,
       column_name text    NOT NULL,
       privilege   text    NOT NULL,
       grantor     text    NOT NULL,
       grantee     text    NOT NULL,
       grantable   boolean NOT NULL
    )

Data type translation function
------------------------------

Parameters:

- type name (type `text`): the name of the data type on the remote data source

- length (type `integer`): the maximal length for non-numeric data types of
  variable length

- precision (type `integer`): the maximal number of significant digits for
  numeric data types of variable length

- scale (type `integer`): the number of digits after the decimal point for
  numeric data types of variable length

Result type: `text`

This function translates data types from the remote data source to PostgreSQL
data types.  The result should include the type modifiers if applicable,
for example `character varying(20)`.

Identifier translation function
-------------------------------

Parameters:

- identifier name (type `text`): the name of the identifier on the remote
  data source

Result type: `name`

This function should generate a PostgreSQL object or column name.
If no translation is required, the function should just return its
argument, which will automatically be truncated to 63 bytes.

Expression translation function
-------------------------------

Parameters:

- SQL expression (type `text`): SQL expression from the remote data source
  as used in column defaults, check constraints or index definitions

Result type: `text`

This function should make a best effort in automatically translating
expressions between the SQL dialects.  Anything that this function cannot
translate will have to be translated by hand during the migration.

Foreign table creation function
-------------------------------

Parameters:

- foreign server (type `name`): the PostgreSQL foreign server to migrate

- schema (type `name`): PostgreSQL schema name for the foreign table

- table name (type `name`): PostgreSQL name of the foreign table

- original schema (type `text`): schema of the table on the remote data
  source

- original table name (type `text`): name of the table on the remote data
  source

- column names (type `name[]`): names for the foreign table columns

- column options (type `jsonb[]`): plugin-specific FDW column options

- original column names (type `text[]`): names of the columns on the remote
  data source

- data types (type `text[]`): data types for the foreign table columns

- nullable (type `boolean[]`): `FALSE` if the foreign table column is
  `NOT NULL`

- extra options (type `jsonb`): options specific to the plugin; this is
  passed through from the `options` argument of `db_migrate_mkforeign`

Result type: `text`

This function generates a `CREATE FOREIGN TABLE` statement that creates
a foreign table with these definitions.  This is required because the syntax
varies between foreign data wrappers.

Support
=======

Create an [issue on Github][issue] or contact [Cybertec][cybertec].


 [issue]: https://github.com/cybertec-postgresql/db_migrator/issues
 [cybertec]: https://www.cybertec-postgresql.com
