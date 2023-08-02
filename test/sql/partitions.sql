\i test/psql.sql

SELECT plan(9);

SELECT partitions_are(
    'part1',
    'pt1',
    ARRAY['part1.pt1_1', 'part1.pt1_def']
);

SELECT results_eq(
    $$ SELECT c1 FROM part1.pt1 WHERE tableoid = 'part1.pt1_1'::regclass $$,
    ARRAY[1],
    'Table part1.pt1_1 should have 1 row'
);

SELECT results_eq(
    $$ SELECT c1 FROM part1.pt1 WHERE tableoid = 'part1.pt1_def'::regclass $$,
    ARRAY[0, 2],
    'Table part1.pt1_def should have 2 rows'
);

SELECT partitions_are('part1', t.partition_name, t.subpartitions)
FROM (
    VALUES ('pt2_a', ARRAY['part1.pt2_a_1', 'part1.pt2_a_2', 'part1.pt2_a_3']),
           ('pt2_b', ARRAY['part1.pt2_b_1', 'part1.pt2_b_2', 'part1.pt2_b_3']),
           ('pt2_c', ARRAY['part1.pt2_c_1', 'part1.pt2_c_2', 'part1.pt2_c_3'])
) AS t(partition_name, subpartitions);

SELECT results_eq(
    format($$ SELECT tableoid::regclass::text, h1::text FROM part1.%I $$, partition_name),
    rows,
    format('Table part1.%I should have distributed rows across subpartitions', partition_name)
) FROM (
    VALUES ('pt2_a', $$ VALUES ('part1.pt2_a_1', 'Sed rutrum suscipit.'), ('part1.pt2_a_2', 'Lorem ipsum dolor.') $$),
           ('pt2_b', $$ VALUES ('part1.pt2_b_2', 'In hac habitasse.'), ('part1.pt2_b_3', 'Orci varius natoque.') $$),
           ('pt2_c', $$ VALUES ('part1.pt2_c_1', 'Aliquam non nibh.'), ('part1.pt2_c_3', 'Aenean efficitur congue.') $$)
) AS t(partition_name, rows);

SELECT * FROM finish();
