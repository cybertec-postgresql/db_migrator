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
sch1	t1	c1	c1	1	int	int	t	{}	\N
sch1	t2	c1	c1	1	int	int	f	{}	1
sch1	t2	t1_c1	t1_c1	2	int	int	t	{}	\N
\.

COPY pgsql_stage.indexes (schema, table_name, index_name, orig_name, uniqueness, where_clause, migrate) FROM stdin;
sch1	t1	t1_idx1_nonunique	t1_idx1_nonunique	f	\N	t
sch1	t1	t1_idx2_unique	t1_idx2_unique	t	\N	t
sch1	t1	t1_idx3_ignored	t1_idx3_ignored	f	\N	f
sch1	t2	t2_idx1_filtered	t2_idx1_filtered	f	(c1 = 1)	t
\.

COPY pgsql_stage.index_columns (schema, table_name, index_name, position, descend, is_expression, column_name) FROM stdin;
sch1	t1	t1_idx1_nonunique	1	f	f	c1
sch1	t1	t1_idx2_unique	1	f	f	c1
sch1	t1	t1_idx3_ignored	1	f	f	c1
sch1	t2	t2_idx1_filtered	1	f	f	c1
\.

COPY pgsql_stage.keys (schema, table_name, constraint_name, orig_name, "deferrable", deferred, column_name, position, is_primary, migrate) FROM stdin;
sch1	t1	t1_pk	t1_pk	f	f	c1	1	t	t
sch1	t2	t2_pk_ignored	t2_pk_ignored	f	f	c1	1	t	f
sch1	t2	t2_uk	t2_uk	f	f	c1	1	f	t
\.

COPY pgsql_stage.foreign_keys (schema, table_name, constraint_name, orig_name, "deferrable", deferred, delete_rule, column_name, position, remote_schema, remote_table, remote_column, migrate) FROM stdin;
sch1	t2	t2_fk	t2_fk	f	f	NO ACTION	t1_c1	1	sch1	t1	c1	t
\.

COPY pgsql_stage.checks (schema, table_name, constraint_name, orig_name, "deferrable", deferred, condition, migrate) FROM stdin;
sch1	t2	t2_ck	t2_ck	f	f	(c1 BETWEEN 1 AND 100)	t
\.
