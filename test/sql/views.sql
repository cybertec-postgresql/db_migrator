\i test/psql.sql

SELECT plan(2);

SELECT is(
    db_migrate_views(plugin => 'noop_migrator'),
    0,
    'Should create views without errors'
);

SELECT has_view('sch1', 'v1', 'View v1 should exist');

SELECT * FROM finish();