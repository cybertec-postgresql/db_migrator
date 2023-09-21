\i test/psql.sql

SELECT plan(3);

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
