\i test/psql.sql

SELECT plan(10);

SELECT results_eq(
    $$ SELECT statement FROM extschema.construct_key_constraints_statements(plugin => 'noop_migrator') $$,
    ARRAY[
        'ALTER TABLE part1.pt1 ADD CONSTRAINT pt1_pk PRIMARY KEY (c1) NOT DEFERRABLE INITIALLY IMMEDIATE',
        'ALTER TABLE part1.pt2 ADD CONSTRAINT pt2_pk PRIMARY KEY (r1, h1) NOT DEFERRABLE INITIALLY IMMEDIATE',
        'ALTER TABLE sch1.t1 ADD CONSTRAINT t1_pk PRIMARY KEY (c1) NOT DEFERRABLE INITIALLY IMMEDIATE',
        'ALTER TABLE sch1.t2 ADD CONSTRAINT t2_uk UNIQUE (c1) NOT DEFERRABLE INITIALLY IMMEDIATE'
    ],
    'Statements for key constraint creation should be correct'
);

SELECT results_eq(
    $$ SELECT statement FROM extschema.construct_fkey_constraints_statements(plugin => 'noop_migrator') $$,
    ARRAY[
        'ALTER TABLE sch1.t2 ADD CONSTRAINT t2_fk FOREIGN KEY (t1_c1) REFERENCES sch1.t1 (c1) ON DELETE NO ACTION NOT DEFERRABLE INITIALLY IMMEDIATE'
    ],
    'Statements for foreign constraint creation should be correct'
);

SELECT results_eq(
    $$ SELECT statement FROM extschema.construct_check_constraints_statements(plugin => 'noop_migrator') $$,
    ARRAY[
        'ALTER TABLE sch1.t2 ADD CONSTRAINT t2_ck CHECK ((c1 BETWEEN 1 AND 100))'
    ],
    'Statements for check constraint creation should be correct'
);

SELECT is(
    extschema.db_migrate_constraints(plugin => 'noop_migrator'),
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
