/*
 * Если нужно быстро проверить подключение и структуру базы, можно начать с
 * этого файла.
 *
 * Скрипт выполняет только SELECT-запросы и ничего не меняет в базе.
 * Его можно запустить целиком в открытом SQL Editor DBeaver.
 */

/* 1. К какой базе и под каким пользователем я подключён. */
SELECT
    current_database() AS database_name,
    current_user AS current_user_name,
    session_user AS session_user_name,
    inet_server_addr() AS server_address,
    inet_server_port() AS server_port,
    current_schema() AS current_schema_name,
    current_setting('search_path') AS search_path,
    current_setting('application_name') AS application_name,
    current_setting('server_version') AS server_version,
    pg_backend_pid() AS backend_pid,
    pg_postmaster_start_time() AS server_started_at,
    current_timestamp AS checked_at;

/* 2. Используется ли SSL. */
SELECT
    ssl,
    version AS ssl_version,
    cipher AS ssl_cipher,
    bits AS ssl_bits
FROM pg_stat_ssl
WHERE pid = pg_backend_pid();

/* 3. Доступные схемы и права пользователя. */
SELECT
    schema_name,
    schema_owner,
    has_schema_privilege(current_user, schema_name, 'USAGE') AS can_use,
    has_schema_privilege(current_user, schema_name, 'CREATE') AS can_create
FROM information_schema.schemata
WHERE schema_name NOT IN ('pg_catalog', 'information_schema')
  AND schema_name NOT LIKE 'pg_toast%'
  AND schema_name NOT LIKE 'pg_temp_%'
ORDER BY schema_name;

/* 4. Таблицы и представления, которые есть в базе. */
SELECT
    namespaces.nspname AS table_schema,
    classes.relname AS relation_name,
    CASE classes.relkind
        WHEN 'r' THEN 'TABLE'
        WHEN 'p' THEN 'PARTITIONED TABLE'
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'f' THEN 'FOREIGN TABLE'
        ELSE classes.relkind::TEXT
    END AS relation_type,
    pg_get_userbyid(classes.relowner) AS owner_name,
    CASE
        WHEN classes.relkind IN ('r', 'p', 'm')
            THEN classes.reltuples::BIGINT
        ELSE NULL
    END AS estimated_rows,
    CASE
        WHEN classes.relkind IN ('r', 'p', 'm')
            THEN pg_size_pretty(pg_total_relation_size(classes.oid))
        ELSE NULL
    END AS total_size,
    has_table_privilege(
        current_user,
        format('%I.%I', namespaces.nspname, classes.relname),
        'SELECT'
    ) AS can_select
FROM pg_class AS classes
JOIN pg_namespace AS namespaces
  ON namespaces.oid = classes.relnamespace
WHERE namespaces.nspname NOT IN ('pg_catalog', 'information_schema')
  AND namespaces.nspname NOT LIKE 'pg_toast%'
  AND namespaces.nspname NOT LIKE 'pg_temp_%'
  AND classes.relkind IN ('r', 'p', 'v', 'm', 'f')
ORDER BY namespaces.nspname, classes.relname;

/* 5. Столбцы таблиц и представлений. */
SELECT
    columns.table_schema,
    columns.table_name,
    columns.ordinal_position,
    columns.column_name,
    CASE
        WHEN columns.data_type IN ('character varying', 'character')
             AND columns.character_maximum_length IS NOT NULL
            THEN format(
                '%s(%s)',
                columns.data_type,
                columns.character_maximum_length
            )
        WHEN columns.data_type = 'numeric'
             AND columns.numeric_precision IS NOT NULL
            THEN format(
                'numeric(%s,%s)',
                columns.numeric_precision,
                COALESCE(columns.numeric_scale, 0)
            )
        ELSE columns.data_type
    END AS full_data_type,
    columns.is_nullable,
    columns.column_default,
    columns.is_identity,
    columns.identity_generation
FROM information_schema.columns AS columns
WHERE columns.table_schema NOT IN ('pg_catalog', 'information_schema')
  AND columns.table_schema NOT LIKE 'pg_toast%'
  AND columns.table_schema NOT LIKE 'pg_temp_%'
ORDER BY
    columns.table_schema,
    columns.table_name,
    columns.ordinal_position;

/* 6. Первичные, внешние и уникальные ключи. */
SELECT
    constraints.table_schema,
    constraints.table_name,
    constraints.constraint_type,
    constraints.constraint_name,
    string_agg(
        key_columns.column_name,
        ', '
        ORDER BY key_columns.ordinal_position
    ) AS constrained_columns
FROM information_schema.table_constraints AS constraints
LEFT JOIN information_schema.key_column_usage AS key_columns
  ON key_columns.constraint_catalog = constraints.constraint_catalog
 AND key_columns.constraint_schema = constraints.constraint_schema
 AND key_columns.constraint_name = constraints.constraint_name
 AND key_columns.table_name = constraints.table_name
WHERE constraints.table_schema NOT IN ('pg_catalog', 'information_schema')
  AND constraints.constraint_type IN (
      'PRIMARY KEY',
      'FOREIGN KEY',
      'UNIQUE'
  )
GROUP BY
    constraints.table_schema,
    constraints.table_name,
    constraints.constraint_type,
    constraints.constraint_name
ORDER BY
    constraints.table_schema,
    constraints.table_name,
    constraints.constraint_type,
    constraints.constraint_name;

/* 7. Между какими столбцами настроены внешние ключи. */
SELECT
    source_constraints.table_schema AS source_schema,
    source_constraints.table_name AS source_table,
    source_columns.column_name AS source_column,
    target_columns.table_schema AS target_schema,
    target_columns.table_name AS target_table,
    target_columns.column_name AS target_column,
    source_constraints.constraint_name
FROM information_schema.table_constraints AS source_constraints
JOIN information_schema.key_column_usage AS source_columns
  ON source_columns.constraint_catalog = source_constraints.constraint_catalog
 AND source_columns.constraint_schema = source_constraints.constraint_schema
 AND source_columns.constraint_name = source_constraints.constraint_name
JOIN information_schema.constraint_column_usage AS target_columns
  ON target_columns.constraint_catalog = source_constraints.constraint_catalog
 AND target_columns.constraint_schema = source_constraints.constraint_schema
 AND target_columns.constraint_name = source_constraints.constraint_name
WHERE source_constraints.constraint_type = 'FOREIGN KEY'
  AND source_constraints.table_schema NOT IN (
      'pg_catalog',
      'information_schema'
  )
ORDER BY
    source_constraints.table_schema,
    source_constraints.table_name,
    source_columns.ordinal_position;

/* 8. Есть ли все объекты, которые нужны для проекта. */
WITH required_objects(object_name) AS (
    VALUES
        ('source1.craft_market_wide'),
        ('source2.craft_market_masters_products'),
        ('source2.craft_market_orders_customers'),
        ('source3.craft_market_craftsmans'),
        ('source3.craft_market_customers'),
        ('source3.craft_market_orders'),
        ('external_source.craft_products_orders'),
        ('external_source.customers'),
        ('dwh.d_craftsman'),
        ('dwh.d_customer'),
        ('dwh.d_product'),
        ('dwh.f_order'),
        ('dwh.customer_report_datamart'),
        ('dwh.load_dates_customer_report_datamart')
)
SELECT
    object_name,
    CASE
        WHEN to_regclass(object_name) IS NOT NULL THEN 'OK'
        ELSE 'MISSING'
    END AS object_status
FROM required_objects
ORDER BY object_name;

/* 9. Короткий итог: всё ли нужное на месте. */
WITH required_objects(object_name) AS (
    VALUES
        ('source1.craft_market_wide'),
        ('source2.craft_market_masters_products'),
        ('source2.craft_market_orders_customers'),
        ('source3.craft_market_craftsmans'),
        ('source3.craft_market_customers'),
        ('source3.craft_market_orders'),
        ('external_source.craft_products_orders'),
        ('external_source.customers'),
        ('dwh.d_craftsman'),
        ('dwh.d_customer'),
        ('dwh.d_product'),
        ('dwh.f_order')
)
SELECT
    COUNT(*) FILTER (
        WHERE to_regclass(object_name) IS NOT NULL
    ) AS required_objects_found,
    COUNT(*) FILTER (
        WHERE to_regclass(object_name) IS NULL
    ) AS required_objects_missing,
    string_agg(
        object_name,
        ', '
        ORDER BY object_name
    ) FILTER (
        WHERE to_regclass(object_name) IS NULL
    ) AS missing_objects
FROM required_objects;
