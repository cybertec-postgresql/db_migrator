\i test/psql.sql

SELECT plan(3);

SELECT is(
    db_migrate_functions(plugin => 'noop_migrator'),
    0,
    'Should create functions without errors'
);

SELECT has_function('sch1', t.function_name, t.args)
FROM (
    VALUES ('multiply', ARRAY['int', 'int']),
           ('divide', ARRAY['int', 'int'])
) AS t(function_name, args);

SELECT * FROM finish();