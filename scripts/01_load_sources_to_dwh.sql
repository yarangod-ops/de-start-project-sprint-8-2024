/*
 * Сначала собираю данные из четырёх источников в один формат, а потом загружаю
 * их в DWH. Файл можно запускать повторно — новые дубли появиться не должны.
 */

BEGIN;

DO $$
BEGIN
    IF to_regclass('external_source.craft_products_orders') IS NULL THEN
        RAISE EXCEPTION
            'Не найдена таблица external_source.craft_products_orders';
    END IF;

    IF to_regclass('external_source.customers') IS NULL THEN
        RAISE EXCEPTION
            'Не найдена таблица external_source.customers';
    END IF;

    IF to_regclass('dwh.f_order') IS NULL THEN
        RAISE EXCEPTION
            'Не найдена таблица dwh.f_order';
    END IF;
END
$$;

DROP TABLE IF EXISTS tmp_sources;

CREATE TEMP TABLE tmp_sources ON COMMIT DROP AS
SELECT DISTINCT
    src.order_id,
    src.order_created_date,
    src.order_completion_date,
    REPLACE(LOWER(TRIM(src.order_status)), '-', ' ') AS order_status,
    src.craftsman_id,
    src.craftsman_name,
    src.craftsman_address,
    src.craftsman_birthday,
    src.craftsman_email,
    src.product_id,
    src.product_name,
    src.product_description,
    src.product_type,
    src.product_price,
    src.customer_id,
    src.customer_name,
    src.customer_address,
    src.customer_birthday,
    src.customer_email
FROM (
    SELECT
        order_id,
        order_created_date,
        order_completion_date,
        order_status,
        craftsman_id,
        craftsman_name,
        craftsman_address,
        craftsman_birthday,
        craftsman_email,
        product_id,
        product_name,
        product_description,
        product_type,
        product_price,
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email
    FROM source1.craft_market_wide

    UNION ALL

    SELECT
        orders.order_id,
        orders.order_created_date,
        orders.order_completion_date,
        orders.order_status,
        products.craftsman_id,
        products.craftsman_name,
        products.craftsman_address,
        products.craftsman_birthday,
        products.craftsman_email,
        products.product_id,
        products.product_name,
        products.product_description,
        products.product_type,
        products.product_price,
        orders.customer_id,
        orders.customer_name,
        orders.customer_address,
        orders.customer_birthday,
        orders.customer_email
    FROM source2.craft_market_masters_products AS products
    JOIN source2.craft_market_orders_customers AS orders
      ON orders.product_id = products.product_id
     AND orders.craftsman_id = products.craftsman_id

    UNION ALL

    SELECT
        orders.order_id,
        orders.order_created_date,
        orders.order_completion_date,
        orders.order_status,
        craftsmen.craftsman_id,
        craftsmen.craftsman_name,
        craftsmen.craftsman_address,
        craftsmen.craftsman_birthday,
        craftsmen.craftsman_email,
        orders.product_id,
        orders.product_name,
        orders.product_description,
        orders.product_type,
        orders.product_price,
        customers.customer_id,
        customers.customer_name,
        customers.customer_address,
        customers.customer_birthday,
        customers.customer_email
    FROM source3.craft_market_orders AS orders
    JOIN source3.craft_market_craftsmans AS craftsmen
      ON craftsmen.craftsman_id = orders.craftsman_id
    JOIN source3.craft_market_customers AS customers
      ON customers.customer_id = orders.customer_id

    UNION ALL

    SELECT
        orders.order_id,
        orders.order_created_date,
        orders.order_completion_date,
        orders.order_status,
        orders.craftsman_id,
        orders.craftsman_name,
        orders.craftsman_address,
        orders.craftsman_birthday,
        orders.craftsman_email,
        orders.product_id,
        orders.product_name,
        orders.product_description,
        orders.product_type,
        orders.product_price,
        customers.customer_id,
        customers.customer_name,
        customers.customer_address,
        customers.customer_birthday,
        customers.customer_email
    FROM external_source.craft_products_orders AS orders
    JOIN external_source.customers AS customers
      ON customers.customer_id = orders.customer_id
) AS src
WHERE src.order_created_date IS NOT NULL
  AND src.craftsman_name IS NOT NULL
  AND src.craftsman_email IS NOT NULL
  AND src.product_name IS NOT NULL
  AND src.product_description IS NOT NULL
  AND src.product_price IS NOT NULL
  AND src.customer_name IS NOT NULL
  AND src.customer_email IS NOT NULL;

ANALYZE tmp_sources;

MERGE INTO dwh.d_craftsman AS target
USING (
    SELECT DISTINCT ON (craftsman_name, craftsman_email)
        craftsman_name,
        craftsman_address,
        craftsman_birthday,
        craftsman_email
    FROM tmp_sources
    ORDER BY
        craftsman_name,
        craftsman_email,
        order_created_date DESC,
        order_id DESC
) AS source
ON target.craftsman_name = source.craftsman_name
AND target.craftsman_email = source.craftsman_email
WHEN MATCHED
 AND (target.craftsman_address, target.craftsman_birthday)
     IS DISTINCT FROM
     (source.craftsman_address, source.craftsman_birthday)
THEN UPDATE SET
    craftsman_address = source.craftsman_address,
    craftsman_birthday = source.craftsman_birthday,
    load_dttm = current_timestamp
WHEN NOT MATCHED THEN
INSERT (
    craftsman_name,
    craftsman_address,
    craftsman_birthday,
    craftsman_email,
    load_dttm
)
VALUES (
    source.craftsman_name,
    source.craftsman_address,
    source.craftsman_birthday,
    source.craftsman_email,
    current_timestamp
);

MERGE INTO dwh.d_product AS target
USING (
    SELECT DISTINCT ON (
        product_name,
        product_description,
        product_price
    )
        product_name,
        product_description,
        product_type,
        product_price
    FROM tmp_sources
    ORDER BY
        product_name,
        product_description,
        product_price,
        order_created_date DESC,
        order_id DESC
) AS source
ON target.product_name = source.product_name
AND target.product_description = source.product_description
AND target.product_price = source.product_price
WHEN MATCHED
 AND target.product_type IS DISTINCT FROM source.product_type
THEN UPDATE SET
    product_type = source.product_type,
    load_dttm = current_timestamp
WHEN NOT MATCHED THEN
INSERT (
    product_name,
    product_description,
    product_type,
    product_price,
    load_dttm
)
VALUES (
    source.product_name,
    source.product_description,
    source.product_type,
    source.product_price,
    current_timestamp
);

MERGE INTO dwh.d_customer AS target
USING (
    SELECT DISTINCT ON (customer_name, customer_email)
        customer_name,
        customer_address,
        customer_birthday,
        customer_email
    FROM tmp_sources
    ORDER BY
        customer_name,
        customer_email,
        order_created_date DESC,
        order_id DESC
) AS source
ON target.customer_name = source.customer_name
AND target.customer_email = source.customer_email
WHEN MATCHED
 AND (target.customer_address, target.customer_birthday)
     IS DISTINCT FROM
     (source.customer_address, source.customer_birthday)
THEN UPDATE SET
    customer_address = source.customer_address,
    customer_birthday = source.customer_birthday,
    load_dttm = current_timestamp
WHEN NOT MATCHED THEN
INSERT (
    customer_name,
    customer_address,
    customer_birthday,
    customer_email,
    load_dttm
)
VALUES (
    source.customer_name,
    source.customer_address,
    source.customer_birthday,
    source.customer_email,
    current_timestamp
);

DROP TABLE IF EXISTS tmp_sources_fact;

CREATE TEMP TABLE tmp_sources_fact ON COMMIT DROP AS
SELECT DISTINCT ON (
    products.product_id,
    craftsmen.craftsman_id,
    customers.customer_id,
    source.order_created_date
)
    products.product_id,
    craftsmen.craftsman_id,
    customers.customer_id,
    source.order_created_date,
    source.order_completion_date,
    source.order_status
FROM tmp_sources AS source
JOIN dwh.d_craftsman AS craftsmen
  ON craftsmen.craftsman_name = source.craftsman_name
 AND craftsmen.craftsman_email = source.craftsman_email
JOIN dwh.d_customer AS customers
  ON customers.customer_name = source.customer_name
 AND customers.customer_email = source.customer_email
JOIN dwh.d_product AS products
  ON products.product_name = source.product_name
 AND products.product_description = source.product_description
 AND products.product_price = source.product_price
ORDER BY
    products.product_id,
    craftsmen.craftsman_id,
    customers.customer_id,
    source.order_created_date,
    source.order_completion_date DESC NULLS LAST;

ANALYZE tmp_sources_fact;

MERGE INTO dwh.f_order AS target
USING tmp_sources_fact AS source
ON target.product_id = source.product_id
AND target.craftsman_id = source.craftsman_id
AND target.customer_id = source.customer_id
AND target.order_created_date = source.order_created_date
WHEN MATCHED
 AND (target.order_completion_date, target.order_status)
     IS DISTINCT FROM
     (source.order_completion_date, source.order_status)
THEN UPDATE SET
    order_completion_date = source.order_completion_date,
    order_status = source.order_status,
    load_dttm = current_timestamp
WHEN NOT MATCHED THEN
INSERT (
    product_id,
    craftsman_id,
    customer_id,
    order_created_date,
    order_completion_date,
    order_status,
    load_dttm
)
VALUES (
    source.product_id,
    source.craftsman_id,
    source.customer_id,
    source.order_created_date,
    source.order_completion_date,
    source.order_status,
    current_timestamp
);

COMMIT;
