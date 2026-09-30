/*
 * Этот файл обновляет dwh.customer_report_datamart только там, где данные
 * действительно изменились.
 *
 * 1. Сначала смотрю дату прошлого запуска.
 * 2. Затем нахожу заказчиков и месяцы, в которых были изменения.
 * 3. Пересчитываю только эти строки и делаю UPSERT.
 * 4. В конце сохраняю дату текущего запуска.
 */

BEGIN;

WITH
load_window AS (
    SELECT
        COALESCE(
            MAX(load_dttm),
            TIMESTAMP '1900-01-01 00:00:00'
        ) AS previous_watermark,
        clock_timestamp()::timestamp AS current_watermark
    FROM dwh.load_dates_customer_report_datamart
),
changed_keys AS (
    SELECT DISTINCT
        orders.customer_id,
        TO_CHAR(orders.order_created_date, 'YYYY-MM') AS report_period
    FROM dwh.f_order AS orders
    JOIN dwh.d_customer AS customers
      ON customers.customer_id = orders.customer_id
    JOIN dwh.d_product AS products
      ON products.product_id = orders.product_id
    JOIN dwh.d_craftsman AS craftsmen
      ON craftsmen.craftsman_id = orders.craftsman_id
    CROSS JOIN load_window
    WHERE GREATEST(
              orders.load_dttm,
              customers.load_dttm,
              products.load_dttm,
              craftsmen.load_dttm
          ) > load_window.previous_watermark
      AND GREATEST(
              orders.load_dttm,
              customers.load_dttm,
              products.load_dttm,
              craftsmen.load_dttm
          ) <= load_window.current_watermark
),
scoped_orders AS (
    SELECT
        customers.customer_id,
        customers.customer_name,
        customers.customer_address,
        customers.customer_birthday,
        customers.customer_email,
        orders.order_id,
        orders.order_status,
        orders.order_created_date,
        orders.order_completion_date,
        products.product_id,
        products.product_type,
        products.product_price,
        craftsmen.craftsman_id,
        changed_keys.report_period
    FROM changed_keys
    JOIN dwh.f_order AS orders
      ON orders.customer_id = changed_keys.customer_id
     AND TO_CHAR(orders.order_created_date, 'YYYY-MM')
         = changed_keys.report_period
    JOIN dwh.d_customer AS customers
      ON customers.customer_id = orders.customer_id
    JOIN dwh.d_product AS products
      ON products.product_id = orders.product_id
    JOIN dwh.d_craftsman AS craftsmen
      ON craftsmen.craftsman_id = orders.craftsman_id
),
monthly_metrics AS (
    SELECT
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        report_period,
        SUM(product_price)::NUMERIC(15, 2) AS customer_money,
        ROUND(SUM(product_price)::NUMERIC * 0.10, 2)
            ::NUMERIC(15, 2) AS platform_money,
        COUNT(order_id)::BIGINT AS count_order,
        ROUND(AVG(product_price)::NUMERIC, 2)
            ::NUMERIC(15, 2) AS avg_price_order,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY order_completion_date - order_created_date
        )::NUMERIC(10, 1) AS median_time_order_completed,
        COUNT(*) FILTER (
            WHERE order_status = 'created'
        )::BIGINT AS count_order_created,
        COUNT(*) FILTER (
            WHERE order_status = 'in progress'
        )::BIGINT AS count_order_in_progress,
        COUNT(*) FILTER (
            WHERE order_status = 'delivery'
        )::BIGINT AS count_order_delivery,
        COUNT(*) FILTER (
            WHERE order_status = 'done'
        )::BIGINT AS count_order_done,
        COUNT(*) FILTER (
            WHERE order_status <> 'done'
        )::BIGINT AS count_order_not_done
    FROM scoped_orders
    GROUP BY
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        report_period
),
product_category_rating AS (
    SELECT
        customer_id,
        report_period,
        product_type,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id, report_period
            ORDER BY COUNT(*) DESC, product_type ASC
        ) AS rating_position
    FROM scoped_orders
    GROUP BY
        customer_id,
        report_period,
        product_type
),
craftsman_rating AS (
    SELECT
        customer_id,
        report_period,
        craftsman_id,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id, report_period
            ORDER BY COUNT(*) DESC, craftsman_id ASC
        ) AS rating_position
    FROM scoped_orders
    GROUP BY
        customer_id,
        report_period,
        craftsman_id
),
calculated_rows AS (
    SELECT
        metrics.customer_id,
        metrics.customer_name,
        metrics.customer_address,
        metrics.customer_birthday,
        metrics.customer_email,
        metrics.customer_money,
        metrics.platform_money,
        metrics.count_order,
        metrics.avg_price_order,
        metrics.median_time_order_completed,
        categories.product_type AS top_product_category,
        craftsmen.craftsman_id AS top_craftsman_id,
        metrics.count_order_created,
        metrics.count_order_in_progress,
        metrics.count_order_delivery,
        metrics.count_order_done,
        metrics.count_order_not_done,
        metrics.report_period
    FROM monthly_metrics AS metrics
    JOIN product_category_rating AS categories
      ON categories.customer_id = metrics.customer_id
     AND categories.report_period = metrics.report_period
     AND categories.rating_position = 1
    JOIN craftsman_rating AS craftsmen
      ON craftsmen.customer_id = metrics.customer_id
     AND craftsmen.report_period = metrics.report_period
     AND craftsmen.rating_position = 1
),
upserted_rows AS (
    INSERT INTO dwh.customer_report_datamart (
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        customer_money,
        platform_money,
        count_order,
        avg_price_order,
        median_time_order_completed,
        top_product_category,
        top_craftsman_id,
        count_order_created,
        count_order_in_progress,
        count_order_delivery,
        count_order_done,
        count_order_not_done,
        report_period
    )
    SELECT
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        customer_money,
        platform_money,
        count_order,
        avg_price_order,
        median_time_order_completed,
        top_product_category,
        top_craftsman_id,
        count_order_created,
        count_order_in_progress,
        count_order_delivery,
        count_order_done,
        count_order_not_done,
        report_period
    FROM calculated_rows
    ON CONFLICT ON CONSTRAINT
        customer_report_datamart_customer_period_uq
    DO UPDATE SET
        customer_name = EXCLUDED.customer_name,
        customer_address = EXCLUDED.customer_address,
        customer_birthday = EXCLUDED.customer_birthday,
        customer_email = EXCLUDED.customer_email,
        customer_money = EXCLUDED.customer_money,
        platform_money = EXCLUDED.platform_money,
        count_order = EXCLUDED.count_order,
        avg_price_order = EXCLUDED.avg_price_order,
        median_time_order_completed =
            EXCLUDED.median_time_order_completed,
        top_product_category = EXCLUDED.top_product_category,
        top_craftsman_id = EXCLUDED.top_craftsman_id,
        count_order_created = EXCLUDED.count_order_created,
        count_order_in_progress = EXCLUDED.count_order_in_progress,
        count_order_delivery = EXCLUDED.count_order_delivery,
        count_order_done = EXCLUDED.count_order_done,
        count_order_not_done = EXCLUDED.count_order_not_done
    RETURNING customer_id, report_period
)
INSERT INTO dwh.load_dates_customer_report_datamart (load_dttm)
SELECT load_window.current_watermark
FROM load_window
WHERE EXISTS (SELECT 1 FROM changed_keys);

COMMIT;
