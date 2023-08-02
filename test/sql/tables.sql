\i test/psql.sql

SELECT plan(6);

SELECT is(
    db_migrate_mkforeign(plugin => 'noop_migrator', server => 'noop'),
    0,
    'Should create foreign tables without errors'
);

SELECT is(
    db_migrate_tables(plugin => 'noop_migrator', with_data => true),
    0,
    'Should migrate tables without errors'
);

SELECT tables_are(
    'sch1',
    ARRAY['t1', 't2']
);

SELECT has_column(
    'sch1',
    't1',
    'c1',
    'Column t1.c1 should exist'
);

SELECT col_not_null(
    'sch1',
    't2',
    'c1',
    'Column t2.c1 should be NOT NULL'
);

SELECT results_eq(
    'SELECT c1 FROM sch1.t1',
    ARRAY[1, 2, 3, 4, 5],
    'Table t1 should have 5 rows'
);

SELECT * FROM finish();
