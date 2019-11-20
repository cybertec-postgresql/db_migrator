/* tools for migration of other databases to PostgreSQL */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION db_migrator" to load this file. \quit

/* This table contains the registered plugins for migrating specific databases */

CREATE TABLE migrator_plugins (
   extension_name                name PRIMARY KEY,
   view_creation_function        name NOT NULL,
   code_count_function           name,
   identifier_transform_function name
);

CREATE FUNCTION get_migrator_plugins() RETURNS SETOF migrator_plugins
   LANGUAGE sql SET search_path = @extschema@ AS
'DELETE FROM migrator_plugins
WHERE NOT EXISTS (SELECT 1 FROM pg_extension
                  WHERE pg_extension.extname = migrator_plugins.extension_name);
SELECT * FROM migrator_plugins;';

GRANT EXECUTE ON FUNCTION get_migrator_plugins() TO PUBLIC;

CREATE FUNCTION get_migrator_plugin(extension_name name) RETURNS migrator_plugins
   LANGUAGE sql SET search_path = @extschema@ AS
'DELETE FROM migrator_plugins
WHERE NOT EXISTS (SELECT 1 FROM pg_extension
                  WHERE pg_extension.extname = migrator_plugins.extension_name);
SELECT * FROM migrator_plugins
WHERE plugins.extension_name = $1';

GRANT EXECUTE ON FUNCTION get_migrator_plugin(name) TO PUBLIC;

CREATE FUNCTION register_migrator_plugin(
   extension_name                name,
   view_creation_function        name,
   code_count_function           name,
   identifier_transform_function name
) RETURNS void
   LANGUAGE sql SET search_path = @extschema@ AS
'DELETE FROM migrator_plugins
WHERE NOT EXISTS (SELECT 1 FROM pg_extension
                  WHERE pg_extension.extname = migrator_plugins.extension_name);
INSERT INTO migrator_plugins
   (extension_name, view_creation_function, code_count_function, identifier_transform_function)
VALUES ($1, $2, $3, $4)';

GRANT EXECUTE ON FUNCTION register_migrator_plugin(name, name, name, name) TO PUBLIC;

CREATE FUNCTION unregister_migrator_plugin(extension_name name) RETURNS void
   LANGUAGE sql SET search_path = @extschema@ AS
'DELETE FROM migrator_plugins
WHERE NOT EXISTS (SELECT 1 FROM pg_extension
                  WHERE pg_extension.extname = migrator_plugins.extension_name)
   OR migrator_plugins.extension_name = $1';

GRANT EXECUTE ON FUNCTION unregister_migrator_plugin(name) TO PUBLIC;
