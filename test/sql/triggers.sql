\i test/psql.sql

UPDATE pgsql_stage.triggers SET trigger_body = $$
DECLARE
    v_value integer := sch1.divide(NEW.c1, 10);
BEGIN
    RAISE NOTICE 'Trigger trg_v1_insert called';
    INSERT INTO sch1.t1 (c1) VALUES (v_value); 
    RETURN NEW;
END;$$
WHERE trigger_name = 'trg_v1_insert';

SELECT plan(3);

SELECT is(
    db_migrate_triggers(plugin => 'noop_migrator'),
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