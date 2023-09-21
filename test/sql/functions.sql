\i test/psql.sql

SELECT plan(4);

SELECT results_eq(
    $$ SELECT statement FROM extschema.construct_functions_statements(plugin => 'noop_migrator') $$,
    ARRAY[
        'SET LOCAL search_path = sch1; CREATE FUNCTION multiply(int,int) RETURNS int LANGUAGE sql AS $$SELECT $1 * $2$$',
        'SET LOCAL search_path = sch1; CREATE FUNCTION divide(int,int) RETURNS int LANGUAGE sql AS $$SELECT $1 / $2$$'
    ],
    'Statements for function creation should be correct'
);

SELECT is(
    extschema.db_migrate_functions(plugin => 'noop_migrator'),
    0,
    'Should create functions without errors'
);

SELECT has_function('sch1', t.function_name, t.args)
FROM (
    VALUES ('multiply', ARRAY['int', 'int']),
           ('divide', ARRAY['int', 'int'])
) AS t(function_name, args);

SELECT * FROM finish();
