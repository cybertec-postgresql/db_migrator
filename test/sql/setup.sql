\i test/psql.sql

CREATE SCHEMA extschema;
CREATE EXTENSION db_migrator WITH SCHEMA extschema;

CREATE SCHEMA plugschema;
CREATE EXTENSION noop_migrator WITH SCHEMA plugschema;

CREATE SERVER noop FOREIGN DATA WRAPPER file_fdw;

SELECT plan(1);

SELECT is(
    extschema.db_migrate_prepare(plugin => 'noop_migrator', server => 'noop'),
    0,
    'Should prepare staging schemas and catalog without errors'
);

COPY pgsql_stage.schemas (schema, orig_schema) FROM stdin;
sch1	sch1
part1	part1
\.

COPY pgsql_stage.sequences (schema, sequence_name, min_value, max_value, increment_by, cyclical, cache_size, last_value, orig_value) FROM stdin;
sch1	seq1	1	100	1	f	10	1	1
sch1	seq2	1	100	10	f	1	10	10
\.

COPY pgsql_stage.tables (schema, table_name, orig_table, migrate) FROM stdin;
sch1	t1	t1	t
sch1	t2	t2	t
part1	pt1	pt1	t
part1	pt2	pt2	t
\.

COPY pgsql_stage.columns (schema, table_name, column_name, orig_column, position, type_name, orig_type, nullable, options, default_value) FROM stdin;
sch1	t1	c1	c1	1	int	int	t	{}	\N
sch1	t2	c1	c1	1	int	int	f	{}	1
sch1	t2	t1_c1	t1_c1	2	int	int	t	{}	\N
sch1	v1	c1	c1	1	int	int	f	{}	\N
part1	pt1	c1	c1	1	int	int	f	{}	\N
part1	pt2	r1	r1	1	int	int	f	{}	\N
part1	pt2	h1	h1	2	varchar(100)	varchar(100)	f	{}	\N
\.

COPY pgsql_stage.partitions (schema, table_name, partition_name, orig_name, type, key, is_default, values) FROM stdin;
part1	pt1	pt1_1	pt1_1	LIST	c1	f	{1}
part1	pt1	pt1_def	pt1_def	LIST	c1	t	\N
part1	pt2	pt2_a	pt2_a	RANGE	r1	f	{MINVALUE,10}
part1	pt2	pt2_b	pt2_b	RANGE	r1	f	{10,100}
part1	pt2	pt2_c	pt2_c	RANGE	r1	f	{100,MAXVALUE}
\.

COPY pgsql_stage.subpartitions (schema, table_name, partition_name, subpartition_name, orig_name, type, key, is_default, values) FROM stdin;
part1	pt2	pt2_a	pt2_a_1	pt2_a_1	HASH	h1	f	{0}
part1	pt2	pt2_a	pt2_a_2	pt2_a_2	HASH	h1	f	{1}
part1	pt2	pt2_a	pt2_a_3	pt2_a_3	HASH	h1	f	{2}
part1	pt2	pt2_b	pt2_b_1	pt2_b_1	HASH	h1	f	{0}
part1	pt2	pt2_b	pt2_b_2	pt2_b_2	HASH	h1	f	{1}
part1	pt2	pt2_b	pt2_b_3	pt2_b_3	HASH	h1	f	{2}
part1	pt2	pt2_c	pt2_c_1	pt2_c_1	HASH	h1	f	{0}
part1	pt2	pt2_c	pt2_c_2	pt2_c_2	HASH	h1	f	{1}
part1	pt2	pt2_c	pt2_c_3	pt2_c_3	HASH	h1	f	{2}
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
part1	pt1	pt1_pk	pt1_pk	f	f	c1	1	t	t
part1	pt2	pt2_pk	pt2_pk	f	f	r1	1	t	t
part1	pt2	pt2_pk	pt2_pk	f	f	h1	2	t	t
\.

COPY pgsql_stage.foreign_keys (schema, table_name, constraint_name, orig_name, "deferrable", deferred, delete_rule, column_name, position, remote_schema, remote_table, remote_column, migrate) FROM stdin;
sch1	t2	t2_fk	t2_fk	f	f	NO ACTION	t1_c1	1	sch1	t1	c1	t
\.

COPY pgsql_stage.checks (schema, table_name, constraint_name, orig_name, "deferrable", deferred, condition, migrate) FROM stdin;
sch1	t2	t2_ck	t2_ck	f	f	(c1 BETWEEN 1 AND 100)	t
\.

COPY pgsql_stage.functions (schema, function_name, is_procedure, source, orig_source, migrate, verified) FROM stdin;
sch1	multiply	f	FUNCTION multiply(int,int) RETURNS int LANGUAGE sql AS $$SELECT $1 * $2$$	''	t	t
sch1	divide	f	FUNCTION divide(int,int) RETURNS int LANGUAGE sql AS $$SELECT $1 / $2$$	''	t	t
\.

COPY pgsql_stage.views (schema, view_name, definition, orig_def, migrate, verified) FROM stdin;
sch1	v1	SELECT multiply(c1, 10) FROM sch1.t1	''	t	t
\.

COPY pgsql_stage.triggers (schema, table_name, trigger_name, trigger_type, triggering_event, for_each_row, when_clause, trigger_body, orig_source, migrate, verified) FROM stdin;
sch1	v1	trg_v1_insert	INSTEAD OF	INSERT	t	\N	DECLARE\n    v_value integer := sch1.divide(NEW.c1, 10);\nBEGIN\n    RAISE NOTICE 'Trigger trg_v1_insert called';\n    INSERT INTO sch1.t1 (c1) VALUES (v_value);\n    RETURN NEW;\nEND;		t	t
\.
