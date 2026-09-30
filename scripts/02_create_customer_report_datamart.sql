/*
 * Здесь создаются витрина по заказчикам и таблица с датами загрузки.
 * Логика простая: одна строка витрины — один заказчик за один месяц.
 */

BEGIN;

CREATE TABLE IF NOT EXISTS dwh.customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    customer_id BIGINT NOT NULL,
    customer_name VARCHAR NOT NULL,
    customer_address VARCHAR NOT NULL,
    customer_birthday DATE NOT NULL,
    customer_email VARCHAR NOT NULL,
    customer_money NUMERIC(15, 2) NOT NULL,
    platform_money NUMERIC(15, 2) NOT NULL,
    count_order BIGINT NOT NULL,
    avg_price_order NUMERIC(15, 2) NOT NULL,
    median_time_order_completed NUMERIC(10, 1),
    top_product_category VARCHAR NOT NULL,
    top_craftsman_id BIGINT NOT NULL,
    count_order_created BIGINT NOT NULL,
    count_order_in_progress BIGINT NOT NULL,
    count_order_delivery BIGINT NOT NULL,
    count_order_done BIGINT NOT NULL,
    count_order_not_done BIGINT NOT NULL,
    report_period VARCHAR(7) NOT NULL,
    CONSTRAINT customer_report_datamart_pk PRIMARY KEY (id),
    CONSTRAINT customer_report_datamart_customer_period_uq
        UNIQUE (customer_id, report_period),
    CONSTRAINT customer_report_datamart_period_ck
        CHECK (report_period ~ '^[0-9]{4}-[0-9]{2}$'),
    CONSTRAINT customer_report_datamart_nonnegative_ck
        CHECK (
            customer_money >= 0
            AND platform_money >= 0
            AND count_order >= 0
            AND avg_price_order >= 0
            AND count_order_created >= 0
            AND count_order_in_progress >= 0
            AND count_order_delivery >= 0
            AND count_order_done >= 0
            AND count_order_not_done >= 0
        )
);

COMMENT ON TABLE dwh.customer_report_datamart IS
    'Месячная инкрементальная витрина активности заказчиков';
COMMENT ON COLUMN dwh.customer_report_datamart.id IS
    'Идентификатор записи витрины';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_id IS
    'Идентификатор заказчика в DWH';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_name IS
    'ФИО заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_address IS
    'Адрес заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_birthday IS
    'Дата рождения заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_email IS
    'Электронная почта заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_money IS
    'Сумма покупок заказчика за отчётный месяц';
COMMENT ON COLUMN dwh.customer_report_datamart.platform_money IS
    'Комиссия платформы: 10 процентов от суммы покупок';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order IS
    'Количество заказов за отчётный месяц';
COMMENT ON COLUMN dwh.customer_report_datamart.avg_price_order IS
    'Средняя стоимость заказа за отчётный месяц';
COMMENT ON COLUMN dwh.customer_report_datamart.median_time_order_completed IS
    'Медианное число дней между созданием и завершением заказа';
COMMENT ON COLUMN dwh.customer_report_datamart.top_product_category IS
    'Самая популярная категория товаров заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.top_craftsman_id IS
    'Идентификатор самого популярного мастера заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_created IS
    'Количество заказов в статусе created';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_in_progress IS
    'Количество заказов в статусе in progress';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_delivery IS
    'Количество заказов в статусе delivery';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_done IS
    'Количество заказов в статусе done';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_not_done IS
    'Количество незавершённых заказов';
COMMENT ON COLUMN dwh.customer_report_datamart.report_period IS
    'Отчётный период в формате YYYY-MM';

CREATE TABLE IF NOT EXISTS dwh.load_dates_customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    load_dttm TIMESTAMP NOT NULL,
    CONSTRAINT load_dates_customer_report_datamart_pk PRIMARY KEY (id)
);

COMMENT ON TABLE dwh.load_dates_customer_report_datamart IS
    'Верхние границы успешно обработанных инкрементальных загрузок витрины';

CREATE INDEX IF NOT EXISTS customer_report_datamart_period_idx
    ON dwh.customer_report_datamart (report_period);

CREATE INDEX IF NOT EXISTS f_order_load_dttm_idx
    ON dwh.f_order (load_dttm);

CREATE INDEX IF NOT EXISTS f_order_customer_created_idx
    ON dwh.f_order (customer_id, order_created_date);

CREATE INDEX IF NOT EXISTS d_customer_load_dttm_idx
    ON dwh.d_customer (load_dttm);

CREATE INDEX IF NOT EXISTS d_product_load_dttm_idx
    ON dwh.d_product (load_dttm);

CREATE INDEX IF NOT EXISTS d_craftsman_load_dttm_idx
    ON dwh.d_craftsman (load_dttm);

COMMIT;
