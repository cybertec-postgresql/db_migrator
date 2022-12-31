/* tools for migration of other databases to PostgreSQL */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION db_migrator" to load this file. \quit

CREATE FUNCTION adjust_to_bigint(numeric) RETURNS bigint
   LANGUAGE sql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$SELECT CASE WHEN $1 < -9223372036854775808
              THEN BIGINT '-9223372036854775808'
              WHEN $1 > 9223372036854775807
              THEN BIGINT '9223372036854775807'
              ELSE $1::bigint
         END$$;

CREATE FUNCTION materialize_foreign_table(
   schema name,
   table_name name,
   with_data boolean DEFAULT TRUE,
   pgstage_schema name DEFAULT NAME 'pgsql_stage'
) RETURNS boolean
   LANGUAGE plpgsql VOLATILE STRICT SET search_path = pg_catalog AS
$$DECLARE
   ft     name;
   errmsg text;
   detail text;
BEGIN
   BEGIN
      /* rename the foreign table */
      ft := substr(table_name, 1, 62) || E'\x07';
      EXECUTE format('ALTER FOREIGN TABLE %I.%I RENAME TO %I', schema, table_name, ft);

      /* create a table */
      EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I)', schema, table_name, schema, ft);

      /* move the data if desired */
      IF with_data THEN
         EXECUTE format('INSERT INTO %I.%I SELECT * FROM %I.%I', schema, table_name, schema, ft);
      END IF;

      /* drop the foreign table */
      EXECUTE format('DROP FOREIGN TABLE %I.%I', schema, ft);

      RETURN TRUE;
   EXCEPTION
      WHEN others THEN
         /* turn the error into a warning */
         GET STACKED DIAGNOSTICS
            errmsg := MESSAGE_TEXT,
            detail := PG_EXCEPTION_DETAIL;
         RAISE WARNING 'Error loading table data for %.%', schema, table_name
            USING DETAIL = errmsg || coalesce(': ' || detail, '');

         EXECUTE
            format(
               E'INSERT INTO %I.migrate_log\n'
               '   (operation, schema_name, object_name, failed_sql, error_message)\n'
               'VALUES (\n'
               '   ''copy table data'',\n'
               '   %L,\n'
               '   %L,\n'
               '   %L,\n'
               '   %L\n'
               ')',
               pgstage_schema,
               schema,
               table_name,
               format('INSERT INTO %I.%I SELECT * FROM %I.%I', schema, table_name, schema, ft),
               errmsg || coalesce(': ' || detail, '')
            );
   END;

   RETURN FALSE;
END;$$;

COMMENT ON FUNCTION materialize_foreign_table(name,name,boolean,name) IS
   'turn a foreign table into a PostgreSQL table';

CREATE FUNCTION db_migrate_refresh(
   plugin         name,
   staging_schema name    DEFAULT NAME 'fdw_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema               text;
   old_msglevel            text;
   v_plugin_schema         text;
   v_create_metadata_views regproc;
   v_translate_datatype    regproc;
   v_translate_identifier  regproc;
   v_translate_expression  regproc;
   c_col                   refcursor;
   v_trans_schema          name;
   v_trans_table           name;
   v_trans_column          name;
   v_schema                text;
   v_table                 text;
   v_column                text;
   v_pos                   integer;
   v_type                  text;
   v_length                integer;
   v_precision             integer;
   v_scale                 integer;
   v_nullable              boolean;
   v_default               text;
   n_type                  text;
   geom_type               text;
   expr                    text;
   s                       text;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   SET LOCAL client_min_messages = warning;

   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   IF NOT FOUND THEN
      RAISE EXCEPTION 'extension "%" is not installed', plugin;
   END IF;

   EXECUTE format(
              E'SELECT create_metadata_views_fun,\n'
              '       translate_datatype_fun,\n'
              '       translate_identifier_fun,\n'
              '       translate_expression_fun\n'
              'FROM %s.db_migrator_callback()',
              v_plugin_schema
           ) INTO v_create_metadata_views,
                  v_translate_datatype,
                  v_translate_identifier,
                  v_translate_expression;

   RAISE NOTICE 'Copying definitions to PostgreSQL staging schema "%" ...', pgstage_schema;

   /* set "search_path" to the foreign stage */
   EXECUTE format('SET LOCAL search_path = %I', staging_schema);

   /* open cursors for columns */
   OPEN c_col FOR
      SELECT schema, table_name, column_name, position, type_name,
             length, precision, scale, nullable, default_value
      FROM columns
      WHERE only_schemas IS NULL
         OR schema =ANY (only_schemas);

   /* set "search_path" to the PostgreSQL stage, and extension schema */
   SELECT extnamespace::regnamespace::text INTO extschema
   FROM pg_extension
   WHERE extname = 'db_migrator';

   EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, extschema);

   /* refresh "schemas" table */
   EXECUTE format(E'INSERT INTO schemas (schema, orig_schema)\n'
                   '   SELECT %s(schema),\n'
                   '          schema\n'
                   '   FROM %I.schemas\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT schemas_pkey DO NOTHING',
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "tables" table */
   EXECUTE format(E'INSERT INTO tables (schema, table_name, orig_table)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(table_name),\n'
                   '          table_name\n'
                   '   FROM %I.tables\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT tables_pkey DO NOTHING',
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* loop through foreign columns and translate them to PostgreSQL columns */
   LOOP
      FETCH c_col INTO v_schema, v_table, v_column, v_pos, v_type,
                   v_length, v_precision, v_scale, v_nullable, v_default;

      EXIT WHEN NOT FOUND;

      EXECUTE format(
                 'SELECT %s(%L, %L, %L, %L)',
                 v_translate_datatype,
                 v_type, v_length, v_precision, v_scale
              ) INTO n_type;

      EXECUTE format(
                 'SELECT %s(%L)',
                 v_translate_expression,
                 v_default
              ) INTO expr;

      EXECUTE format(
                 'SELECT %s(%L)',
                 v_translate_identifier,
                 v_schema
              ) INTO v_trans_schema;

      EXECUTE format(
                 'SELECT %s(%L)',
                 v_translate_identifier,
                 v_table
              ) INTO v_trans_table;

      EXECUTE format(
                 'SELECT %s(%L)',
                 v_translate_identifier,
                 v_column
              ) INTO v_trans_column;

      /* insert a row into the columns table */
      INSERT INTO columns (schema, table_name, column_name, orig_column, position, type_name, orig_type, nullable, default_value)
         VALUES (
            v_trans_schema,
            v_trans_table,
            v_trans_column,
            v_column,
            v_pos,
            n_type,
            CASE WHEN position('(' in v_type) <> 0  /* type name contains modifier */
                 THEN v_type
                 WHEN v_length <> 0
                 THEN v_type || '(' || v_length || ')'
                 ELSE CASE WHEN coalesce(v_scale, 0) <> 0
                           THEN concat(v_type, '(' || v_precision || ',' || v_scale || ')')
                           ELSE CASE WHEN coalesce(v_precision, 0) <> 0
                                     THEN v_type || '(' || v_precision || ')'
                                     ELSE v_type
                                END
                      END
            END,
            v_nullable,
            expr
         )
         ON CONFLICT ON CONSTRAINT columns_pkey DO UPDATE SET
            orig_column = EXCLUDED.orig_column,
            orig_type = EXCLUDED.orig_type;
   END LOOP;

   CLOSE c_col;

   /* refresh "checks" table */
   EXECUTE format(E'INSERT INTO checks (schema, table_name, constraint_name, orig_name, "deferrable", deferred, condition)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(table_name),\n'
                   '          %s(constraint_name),\n'
                   '          constraint_name,\n'
                   '          "deferrable",\n'
                   '          deferred,\n'
                   '          %s(condition)\n'
                   '   FROM %I.checks\n'
                   '   WHERE ($1 IS NULL OR schema =ANY ($1))\n'
                   '     AND condition !~ ''^"[^"]*" IS NOT NULL$''\n'
                   'ON CONFLICT ON CONSTRAINT checks_pkey DO UPDATE SET\n'
                   '   "deferrable" = EXCLUDED."deferrable",\n'
                   '   deferred     = EXCLUDED.deferred,\n'
                   '   condition    = EXCLUDED.condition',
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_expression,
                  staging_schema)
      USING only_schemas;

   /* refresh "foreign_keys" table */
   EXECUTE format(E'INSERT INTO foreign_keys (schema, table_name, constraint_name, orig_name, "deferrable", deferred, delete_rule,\n'
                   '                          column_name, position, remote_schema, remote_table, remote_column)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(table_name),\n'
                   '          %s(constraint_name),\n'
                   '          constraint_name,\n'
                   '          "deferrable",\n'
                   '          deferred,\n'
                   '          delete_rule,\n'
                   '          %s(column_name),\n'
                   '          position,\n'
                   '          %s(remote_schema),\n'
                   '          %s(remote_table),\n'
                   '          %s(remote_column)\n'
                   '   FROM %I.foreign_keys\n'
                   '   WHERE ($1 IS NULL OR schema =ANY ($1) AND remote_schema =ANY ($1))\n'
                   'ON CONFLICT ON CONSTRAINT foreign_keys_pkey DO UPDATE SET\n'
                   '   "deferrable"  = EXCLUDED."deferrable",\n'
                   '   deferred      = EXCLUDED.deferred,\n'
                   '   delete_rule   = EXCLUDED.delete_rule,\n'
                   '   column_name   = EXCLUDED.column_name,\n'
                   '   remote_schema = EXCLUDED.remote_schema,\n'
                   '   remote_table  = EXCLUDED.remote_table,\n'
                   '   remote_column = EXCLUDED.remote_column',
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "keys" table */
   EXECUTE format(E'INSERT INTO keys (schema, table_name, constraint_name, orig_name, "deferrable", deferred, column_name, position, is_primary)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(table_name),\n'
                   '          %s(constraint_name),\n'
                   '          constraint_name,\n'
                   '          "deferrable",\n'
                   '          deferred,\n'
                   '          %s(column_name),\n'
                   '          position,\n'
                   '          is_primary\n'
                   '   FROM %I.keys\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT keys_pkey DO UPDATE SET\n'
                   '   "deferrable"  = EXCLUDED."deferrable",\n'
                   '   deferred      = EXCLUDED.deferred,\n'
                   '   column_name   = EXCLUDED.column_name,\n'
                   '   is_primary    = EXCLUDED.is_primary',
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "views" table */
   EXECUTE format(E'INSERT INTO views (schema, view_name, definition, orig_def)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(view_name),\n'
                   '          definition,\n'
                   '          definition\n'
                   '   FROM %I.views\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT views_pkey DO UPDATE SET\n'
                   '   orig_def = EXCLUDED.definition',
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "functions" table */
   EXECUTE format(E'INSERT INTO functions (schema, function_name, is_procedure, source, orig_source)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(function_name),\n'
                   '          is_procedure,\n'
                   '          source,\n'
                   '          source\n'
                   '   FROM %I.functions\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT functions_pkey DO UPDATE SET\n'
                   '   is_procedure  = EXCLUDED.is_procedure,\n'
                   '   orig_source   = EXCLUDED.source',
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "sequences" table */
   EXECUTE format(E'INSERT INTO sequences (schema, sequence_name, min_value, max_value, increment_by,\n'
                   '                       cyclical, cache_size, last_value, orig_value)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(sequence_name),\n'
                   '          adjust_to_bigint(min_value),\n'
                   '          adjust_to_bigint(max_value),\n'
                   '          adjust_to_bigint(increment_by),\n'
                   '          cyclical,\n'
                   '          GREATEST(cache_size, 1) AS cache_size,\n'
                   '          adjust_to_bigint(last_value),\n'
                   '          adjust_to_bigint(last_value)\n'
                   '   FROM %I.sequences\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT sequences_pkey DO UPDATE SET\n'
                   '   min_value    = EXCLUDED.min_value,\n'
                   '   max_value    = EXCLUDED.max_value,\n'
                   '   increment_by = EXCLUDED.increment_by,\n'
                   '   cyclical     = EXCLUDED.cyclical,\n'
                   '   cache_size   = EXCLUDED.cache_size,\n'
                   '   orig_value   = EXCLUDED.orig_value',
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "indexes" table */
   EXECUTE format(E'INSERT INTO indexes (schema, table_name, index_name, orig_name, uniqueness)\n'
                   '   SELECT DISTINCT %s(schema),\n'
                   '                   %s(table_name),\n'
                   '                   %s(index_name),\n'
                   '                   index_name,\n'
                   '                   uniqueness\n'
                   '   FROM %I.indexes\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT indexes_pkey DO UPDATE SET\n'
                   '   uniqueness = EXCLUDED.uniqueness',
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "index_columns" table */
   EXECUTE format(E'INSERT INTO index_columns (schema, table_name, index_name, position, descend, is_expression, column_name)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(table_name),\n'
                   '          %s(index_name),\n'
                   '          position,\n'
                   '          descend,\n'
                   '          is_expression,\n'
                   '          CASE WHEN is_expression THEN ''('' || lower(column_name) || '')'' ELSE %s(column_name)::text END\n'
                   '   FROM %I.index_columns\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT index_columns_pkey DO UPDATE SET\n'
                   '   table_name    = EXCLUDED.table_name,\n'
                   '   descend       = EXCLUDED.descend,\n'
                   '   is_expression = EXCLUDED.is_expression,\n'
                   '   column_name   = EXCLUDED.column_name',
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "triggers" table */
   EXECUTE format(E'INSERT INTO triggers (schema, table_name, trigger_name, trigger_type, triggering_event,\n'
                   '                      for_each_row, when_clause, trigger_body, orig_source)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(table_name),\n'
                   '          %s(trigger_name),\n'
                   '          trigger_type,\n'
                   '          triggering_event,\n'
                   '          for_each_row,\n'
                   '          when_clause,\n'
                   '          trigger_body,\n'
                   '          trigger_body\n'
                   '   FROM %I.triggers\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT triggers_pkey DO UPDATE SET\n'
                   '   trigger_type      = EXCLUDED.trigger_type,\n'
                   '   triggering_event  = EXCLUDED.triggering_event,\n'
                   '   for_each_row      = EXCLUDED.for_each_row,\n'
                   '   when_clause       = EXCLUDED.when_clause,\n'
                   '   orig_source       = EXCLUDED.orig_source',
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "table_privs" table */
   EXECUTE format(E'INSERT INTO table_privs (schema, table_name, privilege, grantor, grantee, grantable)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(table_name),\n'
                   '          privilege,\n'
                   '          %s(grantor),\n'
                   '          %s(grantee),\n'
                   '          grantable\n'
                   '   FROM %I.table_privs\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT table_privs_pkey DO UPDATE SET\n'
                   '   grantor   = EXCLUDED.grantor,\n'
                   '   grantable = EXCLUDED.grantable',
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* refresh "column_privs" table */
   EXECUTE format(E'INSERT INTO column_privs (schema, table_name, column_name, privilege, grantor, grantee, grantable)\n'
                   '   SELECT %s(schema),\n'
                   '          %s(table_name),\n'
                   '          %s(column_name),\n'
                   '          privilege,\n'
                   '          %s(grantor),\n'
                   '          %s(grantee),\n'
                   '          grantable\n'
                   '   FROM %I.column_privs\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT column_privs_pkey DO UPDATE SET\n'
                   '   grantor   = EXCLUDED.grantor,\n'
                   '   grantable = EXCLUDED.grantable',
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  v_translate_identifier,
                  staging_schema)
      USING only_schemas;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN 0;
END;$$;

COMMENT ON FUNCTION db_migrate_refresh(name,name,name,name[]) IS
  'update the PostgreSQL stage with values from the remote stage';

CREATE FUNCTION db_migrate_prepare(
   plugin         name,
   server         name,
   staging_schema name    DEFAULT NAME 'fdw_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL,
   options        jsonb   DEFAULT NULL
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel            text;
   v_plugin_schema         text;
   v_create_metadata_views regproc;
   v_translate_datatype    regproc;
   v_translate_identifier  regproc;
   v_translate_expression  regproc;
BEGIN
   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   IF NOT FOUND THEN
      RAISE EXCEPTION 'extension "%" is not installed', plugin;
   END IF;

   EXECUTE format(
              E'SELECT create_metadata_views_fun,\n'
              '       translate_datatype_fun,\n'
              '       translate_identifier_fun,\n'
              '       translate_expression_fun\n'
              'FROM %s.db_migrator_callback()',
              v_plugin_schema
           ) INTO v_create_metadata_views,
                  v_translate_datatype,
                  v_translate_identifier,
                  v_translate_expression;

   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating staging schemas "%" and "%" ...', staging_schema, pgstage_schema;
   SET LOCAL client_min_messages = warning;

   /* create remote staging schema */
   BEGIN
      EXECUTE format('CREATE SCHEMA %I', staging_schema);
   EXCEPTION
      WHEN insufficient_privilege THEN
         RAISE insufficient_privilege USING
            MESSAGE = 'you do not have permission to create a schema in this database';
      WHEN duplicate_schema THEN
         RAISE duplicate_schema USING
            MESSAGE = 'staging schema "' || staging_schema || '" already exists',
            HINT = 'Drop the staging schema first or use a different one.';
   END;

   /* create PostgreSQL staging schema */
   BEGIN
      EXECUTE format('CREATE SCHEMA %I', pgstage_schema);
   EXCEPTION
      WHEN duplicate_schema THEN
         RAISE duplicate_schema USING
            MESSAGE = 'staging schema "' || pgstage_schema || '" already exists',
            HINT = 'Drop the staging schema first or use a different one.';
   END;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating foreign metadata views in schema "%" ...', staging_schema;
   SET LOCAL client_min_messages = warning;

   /* create the migration views in the remote staging schema */
   EXECUTE format('SET LOCAL search_path = %I', v_plugin_schema);
   EXECUTE format(
              'SELECT %s($1, $2, $3)',
              v_create_metadata_views
           ) USING
              server,
              staging_schema,
              options;

   /* set "search_path" to the PostgreSQL stage */
   EXECUTE format('SET LOCAL search_path = %I, %I, %s', pgstage_schema, staging_schema, v_plugin_schema);

   /* create tables in the PostgreSQL stage */
   CREATE TABLE schemas (
      schema      name NOT NULL PRIMARY KEY,
      orig_schema text NOT NULL
   );

   CREATE TABLE tables (
      schema        name    NOT NULL REFERENCES schemas,
      table_name    name    NOT NULL,
      orig_table    text    NOT NULL,
      migrate       boolean NOT NULL DEFAULT TRUE,
      CONSTRAINT tables_pkey
         PRIMARY KEY (schema, table_name)
   );

   CREATE TABLE columns(
      schema        name    NOT NULL REFERENCES schemas,
      table_name    name    NOT NULL,
      column_name   name    NOT NULL,
      orig_column   text    NOT NULL,
      position      integer NOT NULL,
      type_name     text    NOT NULL,
      orig_type     text    NOT NULL,
      nullable      boolean NOT NULL,
      options       jsonb,
      default_value text,
      CONSTRAINT columns_pkey
         PRIMARY KEY (schema, table_name, column_name),
      CONSTRAINT columns_unique
         UNIQUE (schema, table_name, position)
   );

   CREATE TABLE checks (
      schema          name    NOT NULL,
      table_name      name    NOT NULL,
      constraint_name name    NOT NULL,
      orig_name       text    NOT NULL,
      "deferrable"    boolean NOT NULL,
      deferred        boolean NOT NULL,
      condition       text    NOT NULL,
      migrate         boolean NOT NULL DEFAULT TRUE,
      CONSTRAINT checks_pkey
         PRIMARY KEY (schema, table_name, constraint_name),
      CONSTRAINT checks_fkey
         FOREIGN KEY (schema, table_name) REFERENCES tables
   );

   CREATE TABLE foreign_keys (
      schema          name    NOT NULL,
      table_name      name    NOT NULL,
      constraint_name name    NOT NULL,
      orig_name       text    NOT NULL,
      "deferrable"    boolean NOT NULL,
      deferred        boolean NOT NULL,
      delete_rule     text    NOT NULL,
      column_name     name    NOT NULL,
      position        integer NOT NULL,
      remote_schema   name    NOT NULL,
      remote_table    name    NOT NULL,
      remote_column   name    NOT NULL,
      migrate         boolean NOT NULL DEFAULT TRUE,
      CONSTRAINT foreign_keys_pkey
         PRIMARY KEY (schema, table_name, constraint_name, position),
      CONSTRAINT foreign_keys_fkey
         FOREIGN KEY (schema, table_name) REFERENCES tables,
      CONSTRAINT foreign_keys_remote_fkey
         FOREIGN KEY (remote_schema, remote_table) REFERENCES tables
   );

   CREATE TABLE keys (
      schema          name    NOT NULL,
      table_name      name    NOT NULL,
      constraint_name name    NOT NULL,
      orig_name       text    NOT NULL,
      "deferrable"    boolean NOT NULL,
      deferred        boolean NOT NULL,
      column_name     name    NOT NULL,
      position        integer NOT NULL,
      is_primary      boolean NOT NULL,
      migrate         boolean NOT NULL DEFAULT TRUE,
      CONSTRAINT keys_pkey
         PRIMARY KEY (schema, table_name, constraint_name, position),
      CONSTRAINT keys_fkey
         FOREIGN KEY (schema, table_name, column_name) REFERENCES columns
   );

   CREATE TABLE views (
      schema     name    NOT NULL REFERENCES schemas,
      view_name  name    NOT NULL,
      definition text    NOT NULL,
      orig_def   text    NOT NULL,
      migrate    boolean NOT NULL DEFAULT TRUE,
      verified   boolean NOT NULL DEFAULT FALSE,
      CONSTRAINT views_pkey
         PRIMARY KEY (schema, view_name)
   );

   CREATE TABLE functions (
      schema         name    NOT NULL REFERENCES schemas,
      function_name  name    NOT NULL,
      is_procedure   boolean NOT NULL,
      source         text    NOT NULL,
      orig_source    text    NOT NULL,
      migrate        boolean NOT NULL DEFAULT FALSE,
      verified       boolean NOT NULL DEFAULT FALSE,
      CONSTRAINT functions_pkey
         PRIMARY KEY (schema, function_name)
   );

   CREATE TABLE sequences (
      schema        name    NOT NULL REFERENCES schemas,
      sequence_name name    NOT NULL,
      min_value     bigint,
      max_value     bigint,
      increment_by  bigint  NOT NULL,
      cyclical      boolean NOT NULL,
      cache_size    integer NOT NULL,
      last_value    bigint  NOT NULL,
      orig_value    bigint  NOT NULL,
      CONSTRAINT sequences_pkey
         PRIMARY KEY (schema, sequence_name)
   );

   CREATE TABLE indexes (
      schema     name    NOT NULL,
      table_name name    NOT NULL,
      index_name name    NOT NULL,
      orig_name  text    NOT NULL,
      uniqueness boolean NOT NULL,
      migrate    boolean NOT NULL DEFAULT TRUE,
      CONSTRAINT indexes_pkey
         PRIMARY KEY (schema, index_name),
      CONSTRAINT indexes_fkey
         FOREIGN KEY (schema, table_name) REFERENCES tables,
      CONSTRAINT indexes_unique
         UNIQUE (schema, table_name, index_name)
   );

   CREATE TABLE index_columns (
      schema        name NOT NULL,
      table_name    name NOT NULL,
      index_name    name NOT NULL,
      position      integer NOT NULL,
      descend       boolean NOT NULL,
      is_expression boolean NOT NULL,
      column_name   text    NOT NULL,
      CONSTRAINT index_columns_pkey
         PRIMARY KEY (schema, index_name, position),
      CONSTRAINT index_columns_fkey
         FOREIGN KEY (schema, table_name, index_name)
            REFERENCES indexes (schema, table_name, index_name)
   );

   CREATE TABLE triggers (
      schema            name    NOT NULL,
      table_name        name    NOT NULL,
      trigger_name      name    NOT NULL,
      trigger_type      text    NOT NULL,
      triggering_event  text    NOT NULL,
      for_each_row      boolean NOT NULL,
      when_clause       text,
      trigger_body      text    NOT NULL,
      orig_source       text    NOT NULL,
      migrate           boolean NOT NULL DEFAULT FALSE,
      verified          boolean NOT NULL DEFAULT FALSE,
      CONSTRAINT triggers_pkey
         PRIMARY KEY (schema, table_name, trigger_name),
      CONSTRAINT triggers_fkey
         FOREIGN KEY (schema) REFERENCES schemas
   );

   CREATE TABLE table_privs (
      schema     name    NOT NULL,
      table_name name    NOT NULL,
      privilege  text    NOT NULL,
      grantor    name    NOT NULL,
      grantee    name    NOT NULL,
      grantable  boolean NOT NULL,
      CONSTRAINT table_privs_pkey
         PRIMARY KEY (schema, table_name, grantee, privilege, grantor),
      CONSTRAINT table_privs_fkey
         FOREIGN KEY (schema, table_name) REFERENCES tables
   );

   CREATE TABLE column_privs (
      schema      name    NOT NULL,
      table_name  name    NOT NULL,
      column_name name    NOT NULL,
      privilege   text    NOT NULL,
      grantor     name    NOT NULL,
      grantee     name    NOT NULL,
      grantable   boolean NOT NULL,
      CONSTRAINT column_privs_pkey
         PRIMARY KEY (schema, table_name, column_name, grantee, privilege),
      CONSTRAINT column_privs_fkey
         FOREIGN KEY (schema, table_name, column_name) REFERENCES columns
   );

   /* table to record errors during migration */
   CREATE TABLE migrate_log (
      log_time timestamp with time zone PRIMARY KEY DEFAULT clock_timestamp(),
      operation text NOT NULL,
      schema_name name NOT NULL,
      object_name name NOT NULL,
      failed_sql text,
      error_message text NOT NULL
   );

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   /* copy data from the remote stage to the PostgreSQL stage */
   EXECUTE format('SET LOCAL search_path = %s', v_plugin_schema);
   RETURN db_migrate_refresh(plugin, staging_schema, pgstage_schema, only_schemas);
END;$$;

COMMENT ON FUNCTION db_migrate_prepare(name,name,name,name,name[],jsonb) IS
   'first step of "db_migrate": create and populate staging schemas';

CREATE FUNCTION db_migrate_mkforeign(
   plugin         name,
   server         name,
   staging_schema name    DEFAULT NAME 'fdw_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   options        jsonb   DEFAULT NULL
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema               text;
   v_plugin_schema         text;
   v_translate_identifier  regproc;
   v_create_foreign_tab    regproc;
   stmt                    text;
   s                       name;
   t                       name;
   sch                     name;
   seq                     name;
   coloptions              jsonb;
   minv                    numeric;
   maxv                    numeric;
   incr                    numeric;
   cycl                    boolean;
   cachesiz                integer;
   lastval                 numeric;
   tab                     name;
   colname                 name;
   fcolname                text;
   typ                     text;
   pos                     integer;
   nul                     boolean;
   fsch                    text;
   ftab                    text;
   o_fsch                  text;
   o_ftab                  text;
   o_sch                   name;
   o_tab                   name;
   col_array               name[] := ARRAY[]::name[];
   col_options_array       jsonb[] := ARRAY[]::jsonb[];
   fcol_array              text[] := ARRAY[]::text[];
   type_array              text[] := ARRAY[]::text[];
   null_array              boolean[] := ARRAY[]::boolean[];
   old_msglevel            text;
   errmsg                  text;
   detail                  text;
   rc                      integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   IF NOT FOUND THEN
      RAISE EXCEPTION 'extension "%" is not installed', plugin;
   END IF;

   EXECUTE format(
              E'SELECT create_foreign_table_fun,\n'
              '       translate_identifier_fun\n'
              'FROM %s.db_migrator_callback()',
              v_plugin_schema
           ) INTO v_create_foreign_tab,
                  v_translate_identifier;

   /* set "search_path" to the PostgreSQL staging schema and the extension schema */
   SELECT extnamespace::regnamespace::text INTO extschema
      FROM pg_extension
      WHERE extname = 'db_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, extschema);

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating schemas ...';
   SET LOCAL client_min_messages = warning;

   /* loop through the schemas that should be migrated */
   FOR s IN
      SELECT schema FROM schemas
   LOOP
      BEGIN
         /* create schema */
         EXECUTE format('CREATE SCHEMA %I', s);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating schema "%"', s
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create schema'',\n'
                  '   %L,\n'
                  '   '''',\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  s,
                  format('CREATE SCHEMA %I', s),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating sequences ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all sequences */
   FOR sch, seq, minv, maxv, incr, cycl, cachesiz, lastval IN
      SELECT schema, sequence_name, min_value, max_value, increment_by, cyclical, cache_size, last_value
         FROM sequences
   LOOP
      BEGIN
      EXECUTE format('CREATE SEQUENCE %I.%I INCREMENT %s MINVALUE %s %s START %s CACHE %s %sCYCLE',
                     sch, seq, incr, minv, CASE WHEN maxv IS NULL THEN 'NO MAXVALUE' ELSE 'MAXVALUE ' || maxv END,
                     lastval + 1, cachesiz, CASE WHEN cycl THEN '' ELSE 'NO ' END);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating sequence %.%', sch, seq
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create sequence'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  seq,
                  format('CREATE SEQUENCE %I.%I INCREMENT %s MINVALUE %s %s START %s CACHE %s %sCYCLE',
                         sch, seq, incr, minv, CASE WHEN maxv IS NULL THEN 'NO MAXVALUE' ELSE 'MAXVALUE ' || maxv END,
                         lastval + 1, cachesiz, CASE WHEN cycl THEN '' ELSE 'NO ' END),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating foreign tables ...';
   SET LOCAL client_min_messages = warning;

   /* create foreign tables */
   o_sch := '';
   o_tab := '';
   FOR sch, tab, colname, fcolname, pos, typ, nul, coloptions, fsch, ftab IN
      EXECUTE format(
         E'SELECT schema,\n'
          '       table_name,\n'
          '       pc.column_name,\n'
          '       pc.orig_column,\n'
          '       pc.position,\n'
          '       pc.type_name,\n'
          '       pc.nullable,\n'
          '       pc.options,\n'
          '       ps.orig_schema,\n'
          '       pt.orig_table\n'
          'FROM columns pc\n'
          '   JOIN tables pt\n'
          '      USING (schema, table_name)\n'
          '   JOIN schemas ps\n'
          '      USING (schema)\n'
          'WHERE pt.migrate\n'
          'ORDER BY schema, table_name, pc.position',
         staging_schema)
   LOOP
      IF o_sch <> sch OR o_tab <> tab THEN
         IF o_tab <> '' THEN
            /* get the CREATE FOREIGN TABLE statement */
            EXECUTE format(
               'SELECT %s($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)',
               v_create_foreign_tab
            ) INTO stmt
            USING server, o_sch, o_tab, o_fsch, o_ftab,
                  col_array, col_options_array, fcol_array,
                  type_array, null_array, options;
            /* execute the statement and log errors */
            BEGIN
               EXECUTE stmt;
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT,
                     detail := PG_EXCEPTION_DETAIL;
                  RAISE WARNING 'Error creating foreign table %.%', sch, tab
                     USING DETAIL = errmsg || coalesce(': ' || detail, '');

                  EXECUTE
                     format(
                        E'INSERT INTO %I.migrate_log\n'
                        '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                        'VALUES (\n'
                        '   ''create foreign table'',\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L\n'
                        ')',
                        pgstage_schema,
                        sch,
                        tab,
                        stmt,
                        errmsg || coalesce(': ' || detail, '')
                     );

                  rc := rc + 1;
            END;
         END IF;

         o_sch := sch;
         o_tab := tab;
         o_fsch := fsch;
         o_ftab := ftab;
         col_array := ARRAY[]::name[];
         col_options_array := ARRAY[]::jsonb[];
         fcol_array := ARRAY[]::text[];
         type_array := ARRAY[]::text[];
         null_array := ARRAY[]::boolean[];
      END IF;

      col_array := col_array || colname;
      IF coloptions IS NOT NULL THEN
         col_options_array := col_options_array || coloptions;
      END IF;
      fcol_array := fcol_array || fcolname;
      type_array := type_array || typ;
      null_array := null_array || nul;
   END LOOP;

   /* last foreign table */
   IF o_tab <> '' THEN
      /* get the CREATE FOREIGN TABLE statement */
      EXECUTE format(
         'SELECT %s($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)',
         v_create_foreign_tab
      ) INTO stmt
      USING server, o_sch, o_tab, o_fsch, o_ftab,
            col_array, col_options_array, fcol_array,
            type_array, null_array, options;
      /* execute the statement and log errors */
      BEGIN
         EXECUTE stmt;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating foreign table %.%', sch, tab
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create foreign table'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  tab,
                  stmt,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END IF;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION db_migrate_mkforeign(name,name,name,name,jsonb) IS
   'second step of "db_migrate": create schemas, sequences and foreign tables';

CREATE FUNCTION db_migrate_tables(
   plugin         name,
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   with_data      boolean DEFAULT TRUE
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel           text;
   v_plugin_schema        text;
   v_translate_identifier regproc;
   sch                    name;
   tab                    name;
   rc                     integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   IF NOT FOUND THEN
      RAISE EXCEPTION 'extension "%" is not installed', plugin;
   END IF;

   EXECUTE format(
              E'SELECT translate_identifier_fun\n'
              'FROM %s.db_migrator_callback()',
              v_plugin_schema
           ) INTO v_translate_identifier;

   /* set "search_path" to the remote stage and the extension schema */
   EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, v_plugin_schema);

   /* loop through all foreign tables to be migrated */
   FOR sch, tab IN
      SELECT schema, table_name FROM tables
      WHERE migrate
   LOOP
      EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
      RAISE NOTICE 'Migrating table %.% ...', sch, tab;
      SET LOCAL client_min_messages = warning;

      /* turn that foreign table into a real table */
      IF NOT materialize_foreign_table(sch, tab, with_data, pgstage_schema) THEN
         rc := rc + 1;
         /* remove the foreign table if it failed */
         EXECUTE format('DROP FOREIGN TABLE %I.%I', sch, tab);
      END IF;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION db_migrate_tables(name,name,boolean) IS
   'third step of "db_migrate": copy table data from the remote database';

CREATE FUNCTION db_migrate_functions(
   plugin         name,
   pgstage_schema name    DEFAULT NAME 'pgsql_stage'
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog SET check_function_bodies = off AS
$$DECLARE
   old_msglevel           text;
   v_plugin_schema        text;
   v_translate_identifier regproc;
   sch                    name;
   fname                  name;
   src                    text;
   errmsg                 text;
   detail                 text;
   rc                     integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   IF NOT FOUND THEN
      RAISE EXCEPTION 'extension "%" is not installed', plugin;
   END IF;

   EXECUTE format(
              E'SELECT translate_identifier_fun\n'
              'FROM %s.db_migrator_callback()',
              v_plugin_schema
           ) INTO v_translate_identifier;

   /* set "search_path" to the remote stage and the extension schema */
   EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, v_plugin_schema);

   FOR sch, fname, src IN
      SELECT schema, function_name, source
      FROM functions
      WHERE migrate
   LOOP
      BEGIN
         /* set "search_path" so that the function can be created without schema */
         EXECUTE format('SET LOCAL search_path = %I', sch);

         EXECUTE 'CREATE ' || src;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating function %.%', sch, fname
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create function'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  fname,
                  'CREATE ' || src,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION db_migrate_functions(name,name) IS
   'fourth step of "db_migrate": create functions';

CREATE FUNCTION db_migrate_triggers(
   plugin         name,
   pgstage_schema name    DEFAULT NAME 'pgsql_stage'
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog SET check_function_bodies = off AS
$$DECLARE
   old_msglevel           text;
   v_plugin_schema        text;
   v_translate_identifier regproc;
   sch                    name;
   tabname                name;
   trigname               name;
   trigtype               text;
   event                  text;
   eachrow                boolean;
   whencl                 text;
   src                    text;
   errmsg                 text;
   detail                 text;
   rc                     integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   IF NOT FOUND THEN
      RAISE EXCEPTION 'extension "%" is not installed', plugin;
   END IF;

   EXECUTE format(
              E'SELECT translate_identifier_fun\n'
              'FROM %s.db_migrator_callback()',
              v_plugin_schema
           ) INTO v_translate_identifier;

   /* set "search_path" to the remote stage and the extension schema */
   EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, v_plugin_schema);

   FOR sch, tabname, trigname, trigtype, event, eachrow, whencl, src IN
      SELECT schema, table_name, trigger_name, trigger_type, triggering_event,
             for_each_row, when_clause, trigger_body
      FROM triggers
      WHERE migrate
   LOOP
      BEGIN
         /* create the trigger function */
         EXECUTE format(E'CREATE FUNCTION %I.%I() RETURNS trigger\n'
                        '   LANGUAGE plpgsql SET search_path = %L AS\n$_f_$%s$_f_$',
                        sch, trigname, sch, src);
         /* create the trigger itself */
         EXECUTE format(E'CREATE TRIGGER %I %s %s ON %I.%I FOR EACH %s\n'
                        '   EXECUTE PROCEDURE %I.%I()',
                        trigname,
                        trigtype,
                        event,
                        sch, tabname,
                        CASE WHEN eachrow THEN 'ROW' ELSE 'STATEMENT' END,
                        sch, trigname);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating trigger % on %.%', trigname, sch, tabname
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create trigger'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  tabname,
                  format(E'CREATE FUNCTION %I.%I() RETURNS trigger\n'
                         '   LANGUAGE plpgsql SET search_path = %L AS\n$_f_$%s$_f_$',
                         sch, trigname, sch, src) || E';\n' ||
                  format(E'CREATE TRIGGER %I %s %s ON %I.%I FOR EACH %s\n'
                         '   EXECUTE PROCEDURE %I.%I()',
                         trigname,
                         trigtype,
                         event,
                         sch, tabname,
                         CASE WHEN eachrow THEN 'ROW' ELSE 'STATEMENT' END,
                         sch, trigname),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION db_migrate_triggers(name,name) IS
   'fifth step of "db_migrate": create triggers';

CREATE FUNCTION db_migrate_views(
   plugin         name,
   pgstage_schema name    DEFAULT NAME 'pgsql_stage'
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel           text;
   v_plugin_schema        text;
   v_translate_identifier regproc;
   sch                    name;
   vname                  name;
   col                    name;
   src                    text;
   stmt                   text;
   separator              text;
   errmsg                 text;
   detail                 text;
   rc                     integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   IF NOT FOUND THEN
      RAISE EXCEPTION 'extension "%" is not installed', plugin;
   END IF;

   EXECUTE format(
              E'SELECT translate_identifier_fun\n'
              'FROM %s.db_migrator_callback()',
              v_plugin_schema
           ) INTO v_translate_identifier;

   /* set "search_path" to the remote stage and the extension schema */
   EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, v_plugin_schema);

   FOR sch, vname, src IN
      SELECT schema, view_name, definition
      FROM views
      WHERE migrate
   LOOP
      stmt := format(E'CREATE VIEW %I.%I (', sch, vname);
      separator := E'\n   ';
      FOR col IN
         SELECT column_name
            FROM columns
            WHERE schema = sch
              AND table_name = vname
            ORDER BY position
      LOOP
         stmt := stmt || separator || quote_ident(col);
         separator := E',\n   ';
      END LOOP;
      stmt := stmt || E'\n) AS ' || src;

      BEGIN
         /* set "search_path" so that the function body can reference objects without schema */
         EXECUTE format('SET LOCAL search_path = %I', sch);

         EXECUTE stmt;

         EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, extschema);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating view %.%', sch, vname
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create view'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  vname,
                  stmt,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION db_migrate_views(name,name) IS
   'sixth step of "db_migrate": create views';

CREATE FUNCTION db_migrate_constraints(
   plugin         name,
   pgstage_schema name    DEFAULT NAME 'pgsql_stage'
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel           text;
   v_plugin_schema        text;
   v_translate_identifier regproc;
   stmt                   text;
   stmt_middle            text;
   stmt_suffix            text;
   separator              text;
   old_s                  name;
   old_t                  name;
   old_c                  name;
   loc_s                  name;
   loc_t                  name;
   ind_name               name;
   cons_name              name;
   candefer               boolean;
   is_deferred            boolean;
   delrule                text;
   colname                name;
   colpos                 integer;
   rem_s                  name;
   rem_t                  name;
   rem_colname            name;
   prim                   boolean;
   expr                   text;
   uniq                   boolean;
   des                    boolean;
   is_expr                boolean;
   errmsg                 text;
   detail                 text;
   rc                     integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   IF NOT FOUND THEN
      RAISE EXCEPTION 'extension "%" is not installed', plugin;
   END IF;

   EXECUTE format(
              E'SELECT translate_identifier_fun\n'
              'FROM %s.db_migrator_callback()',
              v_plugin_schema
           ) INTO v_translate_identifier;

   /* set "search_path" to the PostgreSQL staging schema and the extension schema */
   EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, v_plugin_schema);

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating UNIQUE and PRIMARY KEY constraints ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all key constraint columns */
   old_s := '';
   old_t := '';
   old_c := '';
   FOR loc_s, loc_t, cons_name, candefer, is_deferred, colname, colpos, prim IN
      SELECT schema, table_name, k.constraint_name, k."deferrable", k.deferred,
             k.column_name, k.position, k.is_primary
      FROM keys k
         JOIN tables t
            USING (schema, table_name)
      WHERE t.migrate
        AND k.migrate
      ORDER BY schema, table_name, k.constraint_name, k.position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> cons_name THEN
         IF old_t <> '' THEN
            BEGIN
                  EXECUTE stmt || stmt_suffix;
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT,
                     detail := PG_EXCEPTION_DETAIL;
                  RAISE WARNING 'Error creating primary key or unique constraint on table %.%', old_s, old_t
                     USING DETAIL = errmsg || coalesce(': ' || detail, '');

                  EXECUTE
                     format(
                        E'INSERT INTO %I.migrate_log\n'
                        '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                        'VALUES (\n'
                        '   ''unique constraint'',\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L\n'
                        ')',
                        pgstage_schema,
                        old_s,
                        old_t,
                        stmt || stmt_suffix,
                        errmsg || coalesce(': ' || detail, '')
                     );

                  rc := rc + 1;
            END;
         END IF;

         stmt := format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s (', loc_s, loc_t, cons_name,
                        CASE WHEN prim THEN 'PRIMARY KEY' ELSE 'UNIQUE' END);
         stmt_suffix := format(')%s DEFERRABLE INITIALLY %s',
                              CASE WHEN candefer THEN '' ELSE ' NOT' END,
                              CASE WHEN is_deferred THEN 'DEFERRED' ELSE 'IMMEDIATE' END);
         old_s := loc_s;
         old_t := loc_t;
         old_c := cons_name;
         separator := '';
      END IF;

      stmt := stmt || separator || format('%I', colname);
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || stmt_suffix;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating primary key or unique constraint on table %.%',
                          old_s, old_t
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''unique constraint'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  old_s,
                  old_t,
                  stmt || stmt_suffix,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END IF;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating FOREIGN KEY constraints ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all foreign key constraint columns */
   old_s := '';
   old_t := '';
   old_c := '';
   FOR loc_s, loc_t, cons_name, candefer, is_deferred, delrule,
       colname, colpos, rem_s, rem_t, rem_colname IN
      SELECT fk.schema, fk.table_name, fk.constraint_name, fk."deferrable", fk.deferred, fk.delete_rule,
             fk.column_name, fk.position, fk.remote_schema, fk.remote_table, fk.remote_column
      FROM foreign_keys fk
         JOIN tables tl
            USING (schema, table_name)
         JOIN tables tf
            ON fk.remote_schema = tf.schema AND fk.remote_table = tf.table_name
      WHERE tl.migrate
        AND tf.migrate
        AND fk.migrate
      ORDER BY fk.schema, fk.table_name, fk.constraint_name, fk.position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> cons_name THEN
         IF old_t <> '' THEN
            BEGIN
               EXECUTE stmt || stmt_middle || stmt_suffix;
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT,
                     detail := PG_EXCEPTION_DETAIL;
                  RAISE WARNING 'Error creating foreign key constraint on table %.%', old_s, old_t
                     USING DETAIL = errmsg || coalesce(': ' || detail, '');

                  EXECUTE
                     format(
                        E'INSERT INTO %I.migrate_log\n'
                        '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                        'VALUES (\n'
                        '   ''foreign key constraint'',\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L\n'
                        ')',
                        pgstage_schema,
                        old_s,
                        old_t,
                        stmt || stmt_middle || stmt_suffix,
                        errmsg || coalesce(': ' || detail, '')
                     );

                  rc := rc + 1;
            END;
         END IF;

         stmt := format('ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (', loc_s, loc_t, cons_name);
         stmt_middle := format(') REFERENCES %I.%I (', rem_s, rem_t);
         stmt_suffix := format(') ON DELETE %s%s DEFERRABLE INITIALLY %s',
                              delrule,
                              CASE WHEN candefer THEN '' ELSE ' NOT' END,
                              CASE WHEN is_deferred THEN 'DEFERRED' ELSE 'IMMEDIATE' END);
         old_s := loc_s;
         old_t := loc_t;
         old_c := cons_name;
         separator := '';
      END IF;

      stmt := stmt || separator || format('%I', colname);
      stmt_middle := stmt_middle || separator || format('%I', rem_colname);
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || stmt_middle || stmt_suffix;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating foreign key constraint on table %.%', old_s, old_t
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''foreign key constraint'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  old_s,
                  old_t,
                  stmt || stmt_middle || stmt_suffix,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END IF;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating CHECK constraints ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all check constraints except NOT NULL checks */
   FOR loc_s, loc_t, cons_name, candefer, is_deferred, expr IN
      SELECT schema, table_name, c.constraint_name, c."deferrable", c.deferred, c.condition
      FROM checks c
         JOIN tables t
            USING (schema, table_name)
      WHERE t.migrate
        AND c.migrate
   LOOP
      BEGIN
         EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%s)', loc_s, loc_t, cons_name, expr);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating CHECK constraint on table %.% with expression "%"', loc_s, loc_t, expr
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''check constraint'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  loc_s,
                  loc_t,
                  format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%s)', loc_s, loc_t, cons_name, expr),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating indexes ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all index columns */
   old_s := '';
   old_t := '';
   old_c := '';
   FOR loc_s, loc_t, ind_name, uniq, colpos, des, is_expr, expr IN
      SELECT schema, table_name, i.index_name, ind.uniqueness, i.position, i.descend, i.is_expression, i.column_name
      FROM index_columns i
         JOIN indexes ind
            USING (schema, table_name, index_name)
         JOIN tables t
            USING (schema, table_name)
      WHERE t.migrate
        AND ind.migrate
      ORDER BY schema, table_name, i.index_name, i.position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> ind_name THEN
         IF old_t <> '' THEN
            BEGIN
               EXECUTE stmt || ')';
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT,
                     detail := PG_EXCEPTION_DETAIL;
                  RAISE WARNING 'Error executing "%"', stmt || ')'
                     USING DETAIL = errmsg || coalesce(': ' || detail, '');

                  EXECUTE
                     format(
                        E'INSERT INTO %I.migrate_log\n'
                        '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                        'VALUES (\n'
                        '   ''create index'',\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L\n'
                        ')',
                        pgstage_schema,
                        old_s,
                        old_t,
                        stmt || ')',
                        errmsg || coalesce(': ' || detail, '')
                     );

                  rc := rc + 1;
            END;
         END IF;

         stmt := format('CREATE %sINDEX %I ON %I.%I (',
                        CASE WHEN uniq THEN 'UNIQUE ' ELSE '' END, ind_name, loc_s, loc_t);
         old_s := loc_s;
         old_t := loc_t;
         old_c := ind_name;
         separator := '';
      END IF;

      /* fold expressions to lower case */
      stmt := stmt || separator || expr
                   || CASE WHEN des THEN ' DESC' ELSE ' ASC' END;
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || ')';
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error executing "%"', stmt || ')'
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create index'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  old_s,
                  old_t,
                  stmt || ')',
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END IF;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Setting column default values ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all default expressions */
   FOR loc_s, loc_t, colname, expr IN
      SELECT schema, table_name, c.column_name, c.default_value
      FROM columns c
         JOIN tables t
            USING (schema, table_name)
      WHERE t.migrate
        AND c.default_value IS NOT NULL
   LOOP
      BEGIN
         EXECUTE format('ALTER TABLE %I.%I ALTER %I SET DEFAULT %s',
                        loc_s, loc_t, colname, expr);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error setting default value on % of table %.% to "%"',
                          colname, loc_s, loc_t, expr
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''column default'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  loc_s,
                  loc_t,
                  format('ALTER TABLE %I.%I ALTER %I SET DEFAULT %s',
                         loc_s, loc_t, colname, expr),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION db_migrate_constraints(name,name)
   IS 'seventh step of "db_migrate": create constraints and indexes';

CREATE FUNCTION db_migrate_finish(
   staging_schema name    DEFAULT NAME 'fdw_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage'
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel text;
BEGIN
   RAISE NOTICE 'Dropping staging schemas ...';

   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   EXECUTE format('DROP SCHEMA %I CASCADE', staging_schema);
   EXECUTE format('DROP SCHEMA %I CASCADE', pgstage_schema);

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN 0;
END;$$;

COMMENT ON FUNCTION db_migrate_finish(name,name) IS
   'final step of "db_migrate": drop staging schemas';

CREATE FUNCTION db_migrate(
   plugin         name,
   server         name,
   staging_schema name    DEFAULT NAME 'fdw_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL,
   options        jsonb   DEFAULT NULL,
   with_data      boolean DEFAULT TRUE
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   v_plugin_schema text;
   rc        integer := 0;
BEGIN

   /* get the plugin callback functions */
   SELECT extnamespace::regnamespace::text INTO v_plugin_schema
   FROM pg_extension
   WHERE extname = plugin;

   /* set "search_path" to the extension schema */
   EXECUTE format('SET LOCAL search_path = %s', v_plugin_schema);

   /*
    * First step:
    * Create staging schema and define the remote metadata views there.
    */
   rc := rc + db_migrate_prepare(plugin, server, staging_schema, pgstage_schema, only_schemas, options);

   /*
    * Second step:
    * Create the destination schemas and the foreign tables and sequences there.
    */
   rc := rc + db_migrate_mkforeign(plugin, server, staging_schema, pgstage_schema, options);

   /*
    * Third step:
    * Copy the tables data from the remote database.
    */
   rc := rc + db_migrate_tables(plugin, pgstage_schema, with_data);

   /*
    * Fourth step:
    * Create functions (this won't do anything since they have "migrate = FALSE").
    */
   rc := rc + db_migrate_functions(plugin, pgstage_schema);

   /*
    * Fifth step:
    * Create triggers (this won't do anything since they have "migrate = FALSE").
    */
   rc := rc + db_migrate_triggers(plugin, pgstage_schema);

   /*
    * Sixth step:
    * Create views.
    */
   rc := rc + db_migrate_views(plugin, pgstage_schema);

   /*
    * Seventh step:
    * Create constraints and indexes.
    */
   rc := rc + db_migrate_constraints(plugin, pgstage_schema);

   /*
    * Final step:
    * Drop the staging schema.
    */
   rc := rc + db_migrate_finish(staging_schema, pgstage_schema);

   RAISE NOTICE 'Migration completed with % errors.', rc;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION db_migrate(name,name,name,name,name[],jsonb,boolean) IS
   'migrate a remote database from a foreign server to PostgreSQL';
