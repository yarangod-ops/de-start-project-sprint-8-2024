/*
 * После загрузки прогоняю несколько простых проверок витрины.
 * Если всё в порядке, в issue_count будут нули.
 */

SELECT
    'duplicate_customer_period' AS check_name,
    COUNT(*) AS issue_count
FROM (
    SELECT customer_id, report_period
    FROM dwh.customer_report_datamart
    GROUP BY customer_id, report_period
    HAVING COUNT(*) > 1
) AS duplicates

UNION ALL

SELECT
    'null_required_fields',
    COUNT(*)
FROM dwh.customer_report_datamart
WHERE customer_id IS NULL
   OR customer_name IS NULL
   OR customer_address IS NULL
   OR customer_birthday IS NULL
   OR customer_email IS NULL
   OR customer_money IS NULL
   OR platform_money IS NULL
   OR count_order IS NULL
   OR avg_price_order IS NULL
   OR top_product_category IS NULL
   OR top_craftsman_id IS NULL
   OR report_period IS NULL

UNION ALL

SELECT
    'invalid_platform_commission',
    COUNT(*)
FROM dwh.customer_report_datamart
WHERE platform_money
      IS DISTINCT FROM ROUND(customer_money * 0.10, 2)

UNION ALL

SELECT
    'status_total_mismatch',
    COUNT(*)
FROM dwh.customer_report_datamart
WHERE count_order
      <> count_order_created
       + count_order_in_progress
       + count_order_delivery
       + count_order_done

UNION ALL

SELECT
    'not_done_mismatch',
    COUNT(*)
FROM dwh.customer_report_datamart
WHERE count_order_not_done <> count_order - count_order_done

UNION ALL

SELECT
    'invalid_report_period',
    COUNT(*)
FROM dwh.customer_report_datamart
WHERE report_period !~ '^[0-9]{4}-[0-9]{2}$'

UNION ALL

SELECT
    'negative_metrics',
    COUNT(*)
FROM dwh.customer_report_datamart
WHERE customer_money < 0
   OR platform_money < 0
   OR count_order < 0
   OR avg_price_order < 0
   OR count_order_created < 0
   OR count_order_in_progress < 0
   OR count_order_delivery < 0
   OR count_order_done < 0
   OR count_order_not_done < 0

UNION ALL

SELECT
    'invalid_order_status',
    COUNT(*)
FROM dwh.f_order
WHERE REPLACE(LOWER(TRIM(order_status)), '-', ' ')
      NOT IN ('created', 'in progress', 'delivery', 'done')

UNION ALL

SELECT
    'null_order_created_date',
    COUNT(*)
FROM dwh.f_order
WHERE order_created_date IS NULL;


/*
 * На всякий случай ещё раз считаю основные показатели из фактов и сравниваю
 * их с витриной.
 * В mismatch_count должен быть ноль.
 */
WITH expected AS (
    SELECT
        orders.customer_id,
        TO_CHAR(orders.order_created_date, 'YYYY-MM') AS report_period,
        SUM(products.product_price)::NUMERIC(15, 2)
            AS customer_money,
        ROUND(SUM(products.product_price)::NUMERIC * 0.10, 2)
            ::NUMERIC(15, 2) AS platform_money,
        COUNT(orders.order_id)::BIGINT AS count_order,
        ROUND(AVG(products.product_price)::NUMERIC, 2)
            ::NUMERIC(15, 2) AS avg_price_order,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY
                orders.order_completion_date
                - orders.order_created_date
        )::NUMERIC(10, 1) AS median_time_order_completed
    FROM dwh.f_order AS orders
    JOIN dwh.d_product AS products
      ON products.product_id = orders.product_id
    GROUP BY
        orders.customer_id,
        TO_CHAR(orders.order_created_date, 'YYYY-MM')
)
SELECT
    COUNT(*) AS mismatch_count
FROM expected
FULL JOIN dwh.customer_report_datamart AS actual
  ON actual.customer_id = expected.customer_id
 AND actual.report_period = expected.report_period
WHERE actual.customer_id IS NULL
   OR expected.customer_id IS NULL
   OR actual.customer_money
      IS DISTINCT FROM expected.customer_money
   OR actual.platform_money
      IS DISTINCT FROM expected.platform_money
   OR actual.count_order
      IS DISTINCT FROM expected.count_order
   OR actual.avg_price_order
      IS DISTINCT FROM expected.avg_price_order
   OR actual.median_time_order_completed
      IS DISTINCT FROM expected.median_time_order_completed;


/*
 * Отдельно проверяю популярную категорию и мастера.
 * В top_mismatch_count должен быть ноль.
 */
WITH base AS (
    SELECT
        orders.customer_id,
        TO_CHAR(orders.order_created_date, 'YYYY-MM') AS report_period,
        products.product_type,
        orders.craftsman_id
    FROM dwh.f_order AS orders
    JOIN dwh.d_product AS products
      ON products.product_id = orders.product_id
    WHERE orders.order_created_date IS NOT NULL
),
category_counts AS (
    SELECT
        customer_id,
        report_period,
        product_type,
        COUNT(*) AS order_count
    FROM base
    GROUP BY customer_id, report_period, product_type
),
expected_categories AS (
    SELECT customer_id, report_period, product_type
    FROM (
        SELECT
            category_counts.*,
            ROW_NUMBER() OVER (
                PARTITION BY customer_id, report_period
                ORDER BY order_count DESC, product_type
            ) AS row_number
        FROM category_counts
    ) AS ranked
    WHERE row_number = 1
),
craftsman_counts AS (
    SELECT
        customer_id,
        report_period,
        craftsman_id,
        COUNT(*) AS order_count
    FROM base
    GROUP BY customer_id, report_period, craftsman_id
),
expected_craftsmen AS (
    SELECT customer_id, report_period, craftsman_id
    FROM (
        SELECT
            craftsman_counts.*,
            ROW_NUMBER() OVER (
                PARTITION BY customer_id, report_period
                ORDER BY order_count DESC, craftsman_id
            ) AS row_number
        FROM craftsman_counts
    ) AS ranked
    WHERE row_number = 1
)
SELECT COUNT(*) AS top_mismatch_count
FROM dwh.customer_report_datamart AS actual
JOIN expected_categories AS categories
  USING (customer_id, report_period)
JOIN expected_craftsmen AS craftsmen
  USING (customer_id, report_period)
WHERE actual.top_product_category IS DISTINCT FROM categories.product_type
   OR actual.top_craftsman_id IS DISTINCT FROM craftsmen.craftsman_id;


/*
 * В конце вывожу количество строк в основных таблицах.
 */
SELECT
    (SELECT COUNT(*) FROM dwh.d_craftsman) AS craftsmen,
    (SELECT COUNT(*) FROM dwh.d_customer) AS customers,
    (SELECT COUNT(*) FROM dwh.d_product) AS products,
    (SELECT COUNT(*) FROM dwh.f_order) AS orders,
    (SELECT COUNT(*) FROM dwh.customer_report_datamart)
        AS customer_month_rows,
    (
        SELECT COUNT(*)
        FROM dwh.load_dates_customer_report_datamart
    ) AS successful_increment_runs;
