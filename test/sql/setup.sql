\i test/psql.sql

SELECT plan(1);

CREATE SERVER noop FOREIGN DATA WRAPPER file_fdw; 

SELECT is(
    db_migrate_prepare(plugin => 'noop_migrator', server => 'noop'),
    0,
    'Should prepare staging schemas and catalog without errors'
);

COPY pgsql_stage.schemas (schema, orig_schema) FROM stdin;
sch1	sch1
\.

COPY pgsql_stage.tables (schema, table_name, orig_table, migrate) FROM stdin;
sch1	t1	t1	t
sch1	t2	t2	t
\.

COPY pgsql_stage.columns (schema, table_name, column_name, orig_column, position, type_name, orig_type, nullable, options, default_value) FROM stdin;
sch1	t1	c1	c1	1	int	int	t	{}	{}
sch1	t2	c1	c1	1	int	int	t	{}	{}
\.

COPY pgsql_stage.indexes (schema, table_name, index_name, orig_name, uniqueness, where_clause, migrate) FROM stdin;
sch1	t1	t1_idx1_nonunique	t1_idx1_nonunique	f	null	t
sch1	t1	t1_idx2_unique	t1_idx2_unique	t	null	t
sch1	t1	t1_idx3_ignored	t1_idx3_ignored	f	null	f
sch1	t2	t2_idx1_filtered	t2_idx1_filtered	f	'(c1 = 1)'	t
\.
