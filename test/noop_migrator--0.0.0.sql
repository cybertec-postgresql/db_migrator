/* a noop migrator plugin dedicated to db_migrator regression tests */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION noop_migrator" to load this file. \quit

CREATE FUNCTION db_migrator_callback(
    OUT create_metadata_views_fun regprocedure,
    OUT translate_datatype_fun    regprocedure,
    OUT translate_identifier_fun  regprocedure,
    OUT translate_expression_fun  regprocedure,
    OUT create_foreign_table_fun  regprocedure
) RETURNS record
    LANGUAGE sql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$db_migrator_callback$
WITH ext AS (
    SELECT extnamespace::regnamespace::text AS schema_name
    FROM pg_extension
    WHERE extname = 'noop_migrator'
)
SELECT format('%s.%I(name,name,jsonb)', ext.schema_name, 'noop_create_catalog')::regprocedure,
       format('%s.%I(text,integer,integer,integer)', ext.schema_name, 'noop_translate_datatype')::regprocedure,
       format('%s.%I(text)', ext.schema_name, 'noop_translate_identifier')::regprocedure,
       format('%s.%I(text)', ext.schema_name, 'noop_translate_expression')::regprocedure,
       format('%s.%I(name,name,name,text,text,name[],jsonb[],text[],text[],boolean[],jsonb)', ext.schema_name, 'noop_mkforeign')::regprocedure
FROM ext
$db_migrator_callback$;

COMMENT ON FUNCTION db_migrator_callback() IS
    'callback for db_migrator to get the appropriate conversion functions';

CREATE FUNCTION noop_translate_datatype(text, integer, integer, integer)
RETURNS text LANGUAGE sql CALLED ON NULL INPUT SET search_path = pg_catalog
AS $$SELECT $1; $$;

CREATE FUNCTION noop_translate_identifier(text)
RETURNS name LANGUAGE sql CALLED ON NULL INPUT SET search_path = pg_catalog
AS $$SELECT $1; $$;

CREATE FUNCTION noop_translate_expression(text)
RETURNS text LANGUAGE sql CALLED ON NULL INPUT SET search_path = pg_catalog
AS $$SELECT $1; $$;

CREATE FUNCTION noop_mkforeign(
    server         name,
    schema         name,
    table_name     name,
    orig_schema    text,
    orig_table     text,
    column_names   name[],
    column_options jsonb[],
    orig_columns   text[],
    data_types     text[],
    nullable       boolean[],
    options        jsonb
) RETURNS text 
  LANGUAGE plpgsql CALLED ON NULL INPUT SET search_path = pg_catalog
AS $noop_mkforeign$
DECLARE
    stmt       text;
    i          integer;
    sep        text := '';
    testdata   text := format('@testdata@/%I.%I.dat', schema, table_name);
BEGIN
    stmt := format(E'CREATE FOREIGN TABLE %I.%I (', schema, table_name);

    FOR i IN 1..cardinality(column_names) LOOP
        stmt := stmt || format(E'%s\n   %I %s%s',
        sep, column_names[i], data_types[i],
        CASE WHEN nullable[i] THEN '' ELSE ' NOT NULL' END
        );
        sep := ',';
    END LOOP;

    RETURN stmt || format(
        E') SERVER %I\n'
        '   OPTIONS (filename %L)',
        server, testdata
    );
END; $noop_mkforeign$;

CREATE FUNCTION noop_create_catalog (name, name, jsonb)
RETURNS void LANGUAGE plpgsql CALLED ON NULL INPUT SET search_path = pg_catalog
AS $noop_create_catalog$
DECLARE
    schemas_sql text := $$
        CREATE FOREIGN TABLE %I.schemas (
            schema text NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    sequences_sql text := $$
        CREATE FOREIGN TABLE %I.sequences (
            schema        text    NOT NULL,
            sequence_name text    NOT NULL,
            min_value     numeric,
            max_value     numeric,
            increment_by  numeric NOT NULL,
            cyclical      boolean NOT NULL,
            cache_size    integer NOT NULL,
            last_value    numeric NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    tables_sql text := $$
        CREATE FOREIGN TABLE %I.tables (
            schema     text NOT NULL,
            table_name text NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    columns_sql text := $$
        CREATE FOREIGN TABLE %I.columns (
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
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    check_sql text := $$
        CREATE FOREIGN TABLE %I.checks (
            schema          text    NOT NULL,
            table_name      text    NOT NULL,
            constraint_name text    NOT NULL,
            "deferrable"    boolean NOT NULL,
            deferred        boolean NOT NULL,
            condition       text    NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    keys_sql text := $$
        CREATE FOREIGN TABLE %I.keys (
            schema          text    NOT NULL,
            table_name      text    NOT NULL,
            constraint_name text    NOT NULL,
            "deferrable"    boolean NOT NULL,
            deferred        boolean NOT NULL,
            column_name     text    NOT NULL,
            position        integer NOT NULL,
            is_primary      boolean NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    foreign_keys_sql text := $$
        CREATE FOREIGN TABLE %I.foreign_keys (
            schema          text    NOT NULL,
            table_name      text    NOT NULL,
            constraint_name text    NOT NULL,
            "deferrable"    boolean NOT NULL,
            deferred        boolean NOT NULL,
            delete_rule     text    NOT NULL,
            column_name     text    NOT NULL,
            position        integer NOT NULL,
            remote_schema   text    NOT NULL,
            remote_table    text    NOT NULL,
            remote_column   text    NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    partitions_sql text := $$
        CREATE FOREIGN TABLE %I.partitions (
            schema         name    NOT NULL,
            table_name     name    NOT NULL,
            partition_name name    NOT NULL,
            type           text    NOT NULL,
            key            text    NOT NULL,
            is_default     boolean NOT NULL,
            values         text[]
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    subpartitions_sql text := $$
        CREATE FOREIGN TABLE %I.subpartitions (
            schema            name    NOT NULL,
            table_name        name    NOT NULL,
            partition_name    name    NOT NULL,
            subpartition_name name    NOT NULL,
            type              text    NOT NULL,
            key               text    NOT NULL,
            is_default        boolean NOT NULL,
            values            text[]
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    views_sql text := $$
        CREATE FOREIGN TABLE %I.views (
            schema     text NOT NULL,
            view_name  text NOT NULL,
            definition text NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    functions_sql text := $$
        CREATE FOREIGN TABLE %I.functions (
            schema        text    NOT NULL,
            function_name text    NOT NULL,
            is_procedure  boolean NOT NULL,
            source        text    NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    indexes_sql text := $$
        CREATE FOREIGN TABLE %I.indexes (
            schema        text    NOT NULL,
            table_name    text    NOT NULL,
            index_name    text    NOT NULL,
            uniqueness    boolean NOT NULL,
            where_clause  text
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    index_columns_sql text := $$
        CREATE FOREIGN TABLE %I.index_columns (
            schema        text    NOT NULL,
            table_name    text    NOT NULL,
            index_name    text    NOT NULL,
            position      integer NOT NULL,
            descend       boolean NOT NULL,
            is_expression boolean NOT NULL,
            column_name   text    NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    triggers_sql text := $$
        CREATE FOREIGN TABLE %I.triggers (
            schema            text    NOT NULL,
            table_name        text    NOT NULL,
            trigger_name      text    NOT NULL,
            trigger_type      text    NOT NULL,
            triggering_event  text    NOT NULL,
            for_each_row      boolean NOT NULL,
            when_clause       text,
            trigger_body      text    NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    table_privs_sql text := $$
        CREATE FOREIGN TABLE %I.table_privs (
            schema     text    NOT NULL,
            table_name text    NOT NULL,
            privilege  text    NOT NULL,
            grantor    text    NOT NULL,
            grantee    text    NOT NULL,
            grantable  boolean NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

    column_privs_sql text := $$
        CREATE FOREIGN TABLE %I.column_privs (
            schema      text    NOT NULL,
            table_name  text    NOT NULL,
            column_name text    NOT NULL,
            privilege   text    NOT NULL,
            grantor     text    NOT NULL,
            grantee     text    NOT NULL,
            grantable   boolean NOT NULL
        ) SERVER %I OPTIONS (filename '/dev/null');
    $$;

BEGIN
    /* create catalog with empty tables */
    EXECUTE format(schemas_sql, $2, $1);
    EXECUTE format(sequences_sql, $2, $1);
    EXECUTE format(tables_sql, $2, $1);
    EXECUTE format(columns_sql, $2, $1);
    EXECUTE format(check_sql, $2, $1);
    EXECUTE format(keys_sql, $2, $1);
    EXECUTE format(foreign_keys_sql, $2, $1);
    EXECUTE format(partitions_sql, $2, $1);
    EXECUTE format(subpartitions_sql, $2, $1);
    EXECUTE format(views_sql, $2, $1);
    EXECUTE format(functions_sql, $2, $1);
    EXECUTE format(indexes_sql, $2, $1);
    EXECUTE format(index_columns_sql, $2, $1);
    EXECUTE format(triggers_sql, $2, $1);
    EXECUTE format(table_privs_sql, $2, $1);
    EXECUTE format(column_privs_sql, $2, $1);
END; $noop_create_catalog$;