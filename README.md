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

See [Setup](#setup) below for installation instructions and [Usage](#usage)
for instructions how to best migrate a database.

 [ext]: https://www.postgresql.org/docs/current/extend-extensions.html
 [fdw]: https://www.postgresql.org/docs/current/ddl-foreign-data.html
 [ora_migrator]: https://github.com/cybertec-postgresql/ora_migrator

Cookbook
========

Setup
=====

Prerequisites
-------------

### Permissions ###

You need a database user with the `CREATE` privilege on the current database
who has `USAGE` privilege on the schemas where the extensions are installed
and `EXECUTE` privileges on all required migration functions (the latter are
usually granted by default).

The permissions can be reduced once the migration is complete.

### Foreign Data Wrapper ###

You need to install the foreign data wrapper for the data source from which
you want to migrate.  Follow the installation instructions of that
software.  A [list of available foreign data wrappers][fdw-list] is available
in the PostgreSQL Wiki.

 [fdw-list]: https://wiki.postgresql.org/wiki/Fdw

You need to define these objects:

- a foreign server that describes how to connect to the remote data source

- a user mapping for the server to provide credentials for the migration user

### `db_migrator` plugin ###

You also need to install the `db_migrator` plugin for the data source from
which you want to migrate.  Again, follow the installation instructions provided
with the software.

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

- `migrate` (type `boolean`): `TRUE` if the table should be migrated

  Modify this column if desired.

### `columns` ###

- `schema` (type `name`): schema of the table containing the column

- `table_name` (type `name`): table containing the column

- `column_name` (type `name`): name of the column

- `orig_column` (type `text`): column name as used in the remote data source

- `position` (type `integer`): defines the order of the columns (1 for the
  first column)

- `type_name` (type `text`): PostgreSQL data type (including type modifiers)

  Modify this column if desired.

- `orig_type` (type `text`): data type in the remote data source (without
  type modifiers)

- `nullable` (type `boolean`): `FALSE` if the column is `NOT NULL`

  Modify this column if desired.

- `default_value` (type `text`):

  Modify this column if desired.

### `checks` (check constraints) ###

- `schema` (type `name`): schema of the table with the constraint

- `table_name` (type `name`): table with the constraint

- `constraint_name` (type `name`): name of the constraint (will not be migrated)

- `deferrable` (type `boolean`): `TRUE` if the constraint can be deferred

  Modify this column if desired.

- `deferred` (type `boolean`): `TRUE` if the constraint is `INITIALLY DEFERRED`

  Modify this column if desired.

- `condition` (type `text`): condition to be checked

  Modify this column if desired.

- `migrate` (type `boolean`): `TRUE` if the constraint should be migrated

  Modify this column if desired.

### `keys` (columns of primary and unique keys) ###

- `schema` (type `name`): schema of the table with the constraint

- `table_name` (type `name`): table with the constraint

- `constraint_name` (type `name`): name of the constraint (will not be migrated)

- `deferrable` (type `boolean`): `TRUE` if the constraint can be deferred

  Modify this column if desired.

- `deferred` (type `boolean`): `TRUE` if the constraint is `INITIALLY DEFERRED`

  Modify this column if desired.

- `column_name` (type `name`): name of a column that is part of the key

- `position` (type `integer`): defines the order of columns in the constraint

- `is_primary` (type `boolean`): `TRUE` if this is a primary key

- `migrate` (type `boolean`): `TRUE` if the constraint should be migrated

  Modify this column if desired.

### `indexes` ###

- `schema` (type `name`): schema of the table with the index

- `table_name` (type `name`): table with the index

- `index_name` (type `name`): name of the index (will not be migrated)

- `uniqueness` (type `boolean`): `TRUE` if this is a unique index

  Modify this column if desired.

- `migrate` (type `boolean`): `TRUE` if the constraint should be migrated

  Modify this column if desired.

### `index_columns` ###

- `schema` (type `name`): schema of the table with the index

- `table_name` (type `name`): table with the index

- `index_name` (type `name`): name of the index (will not be migrated)

- `position` (type `integer`): determines the index column order

- `descend` (type `boolean`): `TRUE` if the index column is sorted `DESC`

  Modify this column if desired.

- `is_expression` (type `boolean`): `TRUE` if the index column is an
  expression rather than a column name

- `column_name` (type `text`): name of the column or indexed expression
  (expressions usually must be surounded with parentheses)

  Modify this column if desired.

### `views` ###

- `schema` (type `name`): schema of the table with the view

- `view_name` (type `name`): name of the view

- `definition` (type `text`): SQL statement defining the view

  Modify this column if desired.

- `orig_def` (type `text`): view definition on the remote data source

- `migrate` (type `boolean`): `TRUE` if the constraint should be migrated

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

- `migrate` (type `boolean`): `TRUE` is the object should be migrated

  Modify this column if desired.

- `verified` (type `boolean`): can be used however you want

  This may be useful to store if the source code has been translated
  successfully.

### `triggers` ###

- `schema` (type `name`): schema of the table with the trigger

- `table_name` (type `name`): name of the table with the trigger

- `trigger_name` (type `name`): name of the trigger

- `is_before` (type `boolean`): `TRUE` if it is a `BEFORE` trigger

- `triggering_event` (type `text`): `INSERT`, `UPDATE`, `DELETE`
  or `TRUNCATE` (if more than one, combine with `OR`)

- `for_each_row` (type `boolean`): `TRUE` if the trigger is executed
  for each modified row rather than once per triggering statement

- `when_clause` (type `text`): condition for the trigger execution

- `referencing_names` (type `name`): the `REFERENCING` clause for the
  `CREATE TRIGGER` statement

- `trigger_body` (type `text`): the function body for the trigger

- `orig_source` (type `text`): the trigger source code on the remote data source

- `migrate` (type `boolean`): `TRUE` if the trigger should be migrated

- `verified` (type `boolean`): can be used however you want

  This may be useful to store if the trigger has been translated successfully.

### `table_privs` (permissions on tables) ##ä

These are not migrated by `db_migrator`, but can be used by the migration script
to migrate permissions.

- `schema` (type `name`): schema of the table with the privilege

- `table_name` (type `name`): name of the table with the privilege

- `privilege` (type `text`): name of the privilege

- `grantor` (type `name`): user who granted the privilege

- `grantee` (type `name`): user who receives the permission

- `grantable` (type `boolean`): `TRUE` if the grantee can grant the privilege
  to others

### `column_privs` (permissions on table columns) ###

These are not migrated by `db_migrator`, but can be used by the migration script
to migrate permissions.

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

- `only_schemas` (type `name[]`, default all schemas): list of schemas to
  migrate

  These must be written exactly like they are on the remote data source.

- `options` (type `jsonb`, optional): options to pass to the plugin

  Consult the documentation of the plugin for available options.

Call this function once you have edited the Postgres stage to your satisfaction.
It will create all schemas that should be migrated and foreign tables for
all remote tables you want to migrate.

### `db_migrate_tables` ###

Parameters:

- `plugin` (type `name`, required): name of the `db_migrator` plugin to use

- `pgstage_schema` (type `name`, default `pgsql_stage`): name of the
  Postgres staging schema

- `only_schemas` (type `name[]`, default all schemas): list of schemas to
  migrate

  These must be written exactly like they are on the remote data source.

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
The table data are migrated unless `with_data` is `FALSE`.

You don't need this function if you use `db_migrate_tables`.  It is provided as
a low-level alternative and is particularly useful if you want to migrate
several tables in parallel to improve processing speed.

Plugin API
==========

Support
=======
