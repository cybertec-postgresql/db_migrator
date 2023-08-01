\i test/psql.sql

SELECT plan(7);

SELECT is(
    db_migrate_constraints(plugin => 'noop_migrator'),
    0,
    'Should create constraints without errors'
);

SELECT has_pk(
    'sch1',
    't1',
    'Table t1 should have a primary key'
);

SELECT hasnt_pk(
    'sch1',
    't2',
    'Table t2 should not have a primary key'
);

SELECT col_is_unique(
    'sch1',
    't2',
    'c1',
    'Column t2(c1) should have a unique constraint'
);

SELECT col_is_fk(
    'sch1',
    't2',
    't1_c1',
    'Column t2(t1_c1) should have a foreign key constraint'
);

SELECT col_has_check(
    'sch1',
    't2',
    'c1',
    'Column t2(c1) should have a check constraint'
);

SELECT col_default_is(
    'sch1',
    't2',
    'c1',
    1,
    'Column t2(c1) should have a default value'
);

SELECT * FROM finish();
