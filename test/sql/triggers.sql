\i test/psql.sql

SELECT plan(3);

SELECT is(
    extschema.db_migrate_triggers(plugin => 'noop_migrator'),
    0,
    'Should create triggers without errors'
);

SELECT lives_ok(
    $$INSERT INTO sch1.v1 VALUES (60)$$,
    'Should insert 60 into v1 without errors'
);

SELECT row_eq(
    'SELECT c1 FROM sch1.v1 ORDER BY c1 DESC LIMIT 1',
    ROW(60),
    'Last inserted value in sch1.v1 should be 60'
);

SELECT * FROM finish();
