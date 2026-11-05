-- ==============================================================================
-- Step 6: 源库与目标库全表行数、金额汇总、整表确定性 MD5 指纹与序列状态一致性比对脚本
-- ==============================================================================
\pset pager off
\pset format aligned

SELECT
    'postgres.public.migration_heartbeat' AS table_fqn,
    COUNT(*) AS row_count,
    COALESCE(MD5(STRING_AGG(heartbeat_id::text || ':' || event_tag || ':' || payload::text, '|' ORDER BY heartbeat_id)), 'EMPTY') AS table_md5
FROM public.migration_heartbeat;

SELECT last_value AS heartbeat_seq_last_val, is_called FROM public.migration_heartbeat_heartbeat_id_seq;

\c ecommerce_prod

SELECT
    table_fqn,
    row_count,
    numeric_sum,
    table_md5
FROM (
    SELECT
        1 AS sort_id,
        'ecommerce_prod.core.customers' AS table_fqn,
        COUNT(*) AS row_count,
        0::NUMERIC(16,2) AS numeric_sum,
        MD5(STRING_AGG(customer_id::text || ':' || external_uuid::text || ':' || email || ':' || tier || ':' || profile::text, '|' ORDER BY customer_id)) AS table_md5
    FROM core.customers
    UNION ALL
    SELECT
        2 AS sort_id,
        'ecommerce_prod.core.products' AS table_fqn,
        COUNT(*) AS row_count,
        SUM(unit_price)::NUMERIC(16,2) AS numeric_sum,
        MD5(STRING_AGG(product_id::text || ':' || sku || ':' || unit_price::text || ':' || in_stock::text, '|' ORDER BY product_id)) AS table_md5
    FROM core.products
    UNION ALL
    SELECT
        3 AS sort_id,
        'ecommerce_prod.core.orders' AS table_fqn,
        COUNT(*) AS row_count,
        SUM(total_amount)::NUMERIC(16,2) AS numeric_sum,
        MD5(STRING_AGG(order_id::text || ':' || customer_id::text || ':' || order_status || ':' || total_amount::text || ':' || shipping_meta::text, '|' ORDER BY order_id)) AS table_md5
    FROM core.orders
    UNION ALL
    SELECT
        4 AS sort_id,
        'ecommerce_prod.core.order_items' AS table_fqn,
        COUNT(*) AS row_count,
        SUM(line_amount)::NUMERIC(16,2) AS numeric_sum,
        MD5(STRING_AGG(item_id::text || ':' || order_id::text || ':' || product_id::text || ':' || quantity::text || ':' || line_amount::text, '|' ORDER BY item_id)) AS table_md5
    FROM core.order_items
    UNION ALL
    SELECT
        5 AS sort_id,
        'ecommerce_prod.analytics.daily_revenue_snapshot' AS table_fqn,
        COUNT(*) AS row_count,
        SUM(gross_revenue)::NUMERIC(16,2) AS numeric_sum,
        MD5(STRING_AGG(snapshot_date::text || ':' || gross_revenue::text || ':' || order_count::text, '|' ORDER BY snapshot_date)) AS table_md5
    FROM analytics.daily_revenue_snapshot
    UNION ALL
    SELECT
        6 AS sort_id,
        'ecommerce_prod.analytics.v_customer_ltv (VIEW)' AS table_fqn,
        COUNT(*) AS row_count,
        SUM(lifetime_value)::NUMERIC(16,2) AS numeric_sum,
        MD5(STRING_AGG(customer_id::text || ':' || total_orders::text || ':' || lifetime_value::text, '|' ORDER BY customer_id)) AS table_md5
    FROM analytics.v_customer_ltv
) t
ORDER BY sort_id;

SELECT 'customers_seq' AS seq_name, last_value, is_called FROM core.customers_customer_id_seq
UNION ALL
SELECT 'products_seq', last_value, is_called FROM core.products_product_id_seq
UNION ALL
SELECT 'orders_seq', last_value, is_called FROM core.orders_order_id_seq
UNION ALL
SELECT 'order_items_seq', last_value, is_called FROM core.order_items_item_id_seq
ORDER BY 1;
