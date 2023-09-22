\i test/psql.sql

SELECT plan(4);

SELECT results_eq(
    $$ SELECT statement FROM extschema.construct_indexes_statements(plugin => 'noop_migrator') $$,
    ARRAY[
        'CREATE INDEX t1_idx1_nonunique ON sch1.t1 (c1 ASC)',
        'CREATE UNIQUE INDEX t1_idx2_unique ON sch1.t1 (c1 ASC)',
        'CREATE INDEX t2_idx1_filtered ON sch1.t2 (c1 ASC) WHERE (c1 = 1)'
    ],
    'Statements for index creation should be correct'
);

SELECT is(
    extschema.db_migrate_indexes(plugin => 'noop_migrator'),
    0,
    'Should create user-defined indexes without errors'
);

SELECT indexes_are(
    'sch1',
    't1',
    ARRAY['t1_idx1_nonunique', 't1_idx2_unique']
);

SELECT index_is_unique(
    'sch1',
    't1',
    't1_idx2_unique'
);

SELECT * FROM finish();
