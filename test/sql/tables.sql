\i test/psql.sql

SELECT plan(12);

SELECT results_eq(
    $$ SELECT statement FROM extschema.construct_schemas_statements() $$,
    ARRAY[
        'CREATE SCHEMA sch1',
        'CREATE SCHEMA part1'
    ],
    'Statements for schema creation should be correct'
);

SELECT results_eq(
    $$ SELECT statement FROM extschema.construct_sequences_statements() $$,
    ARRAY[
        'CREATE SEQUENCE sch1.seq1 INCREMENT 1 MINVALUE 1 MAXVALUE 100 START 2 CACHE 10 NO CYCLE'
    ],
    'Statements for sequence creation should be correct'
);

SELECT results_eq(
    $$ SELECT regexp_replace(statement, '''.*''', '<removed>', 'g')
       FROM extschema.construct_foreign_tables_statements(plugin => 'noop_migrator', server => 'noop') $$,
    ARRAY[
        'CREATE FOREIGN TABLE part1.pt1 ( c1 int NOT NULL) SERVER noop OPTIONS (filename <removed>)',
        'CREATE FOREIGN TABLE part1.pt2 ( r1 int NOT NULL, h1 varchar(100) NOT NULL) SERVER noop OPTIONS (filename <removed>)',
        'CREATE FOREIGN TABLE sch1.t1 ( c1 int) SERVER noop OPTIONS (filename <removed>)',
        'CREATE FOREIGN TABLE sch1.t2 ( c1 int NOT NULL, t1_c1 int) SERVER noop OPTIONS (filename <removed>)'
    ],
    'Statements for foreign table creation should be correct'
);

SELECT is(
    extschema.db_migrate_mkforeign(plugin => 'noop_migrator', server => 'noop'),
    0,
    'Should create foreign tables without errors'
);

SELECT has_schema(schema_name)
FROM (
    VALUES ('sch1'), ('part1')
) AS t(schema_name);

SELECT sequences_are(
    'sch1',
    ARRAY['seq1']
);

SELECT is(
    extschema.db_migrate_tables(plugin => 'noop_migrator', with_data => true),
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
