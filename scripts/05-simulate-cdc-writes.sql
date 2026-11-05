-- ==============================================================================
-- Step 5 (可选 PoC 压测): 在 DMS 处于 CDC 阶段时模拟线上持续写入 (INSERT/UPDATE/DELETE)
-- ==============================================================================
\set ON_ERROR_STOP on

INSERT INTO public.migration_heartbeat (event_tag, payload, created_at)
SELECT
    'CDC_LIVE_EVENT_' || g,
    jsonb_build_object('cdc_batch', 1, 'seq', g, 'mode', 'live_replication'),
    TIMESTAMPTZ '2026-11-05 10:00:00+00' + (g || ' seconds')::interval
FROM generate_series(1, 15) AS g;

\c ecommerce_prod

BEGIN;

INSERT INTO core.customers (external_uuid, email, tier, tags, profile, created_at)
SELECT
    md5('cdc-cust-' || g)::uuid,
    'cdc_customer_' || g || '@example.internal',
    'VIP',
    ARRAY['cdc_live', 'cohort_2026_q4'],
    jsonb_build_object('loyalty_points', 1000 + g, 'verified', true, 'country', 'US'),
    TIMESTAMPTZ '2026-11-05 10:05:00+00' + (g || ' seconds')::interval
FROM generate_series(1, 20) AS g;

INSERT INTO core.orders (customer_id, order_status, total_amount, shipping_meta, ordered_at)
SELECT
    2000 + ((g - 1) % 20) + 1,
    'CDC_NEW_ORDER',
    ROUND((150.00 + (g * 3.25))::numeric, 2),
    jsonb_build_object('carrier', 'DHL_EXPRESS', 'cdc_streamed', true),
    TIMESTAMPTZ '2026-11-05 10:10:00+00' + (g || ' seconds')::interval
FROM generate_series(1, 250) AS g;

INSERT INTO core.order_items (order_id, product_id, quantity, line_amount)
SELECT
    10000 + ((g - 1) % 250) + 1,
    ((g * 3) % 500) + 1,
    2,
    ROUND((49.50 + (g % 25))::numeric, 2)
FROM generate_series(1, 500) AS g;

UPDATE core.orders
SET
    order_status = 'SHIPPED_VIA_CDC',
    total_amount = total_amount + 19.99,
    shipping_meta = shipping_meta || '{"cdc_updated": true, "tracking_verified": true}'::jsonb
WHERE order_id BETWEEN 1 AND 300;

DELETE FROM core.order_items WHERE order_id BETWEEN 9951 AND 10000;
DELETE FROM core.orders WHERE order_id BETWEEN 9951 AND 10000;

COMMIT;
