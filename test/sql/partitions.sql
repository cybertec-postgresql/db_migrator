\i test/psql.sql

SELECT plan(3);

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

SELECT * FROM finish();
