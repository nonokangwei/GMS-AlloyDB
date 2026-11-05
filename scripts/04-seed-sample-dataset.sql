-- ==============================================================================
-- Step 4 (可选 PoC 压测): 构造双库多 Schema 仿真电商数据集 (共 37,965 行) 并完成迁移授权
-- 用法示例:
--   PGPASSWORD="<SRC_POSTGRES_PASSWORD>" psql -h <SRC_PSA_PRIVATE_IP> -U postgres -d postgres \
--     -v migrator_user="dms_migrator" -v migrator_password="<MIGRATOR_PASSWORD>" \
--     -f scripts/04-seed-sample-dataset.sql
-- ==============================================================================
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pglogical;

CREATE TABLE IF NOT EXISTS public.migration_heartbeat (
    heartbeat_id SERIAL PRIMARY KEY,
    event_tag VARCHAR(64) NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT TIMESTAMPTZ '2026-11-01 00:00:00+00'
);

TRUNCATE TABLE public.migration_heartbeat RESTART IDENTITY;

INSERT INTO public.migration_heartbeat (event_tag, payload, created_at)
SELECT
    'INIT_SNAPSHOT_' || g,
    jsonb_build_object('seq', g, 'phase', 'pre_migration', 'checksum_seed', md5(g::text)),
    TIMESTAMPTZ '2026-11-01 00:00:00+00' + (g || ' minutes')::interval
FROM generate_series(1, 100) AS g;

SELECT format(
  'CREATE ROLE %I WITH LOGIN PASSWORD %L REPLICATION',
  :'migrator_user',
  :'migrator_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'migrator_user')\gexec

SELECT format('GRANT alloydbsuperuser TO %I', :'migrator_user')\gexec
SELECT format('ALTER ROLE %I WITH REPLICATION', :'migrator_user')\gexec

SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'migrator_user')\gexec
GRANT USAGE ON SCHEMA pglogical TO PUBLIC;
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO %I', :'migrator_user')\gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'migrator_user')\gexec
SELECT format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO %I', :'migrator_user')\gexec

SELECT 'CREATE DATABASE ecommerce_prod OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ecommerce_prod')\gexec

\c ecommerce_prod

CREATE EXTENSION IF NOT EXISTS pglogical;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS analytics;

CREATE TABLE IF NOT EXISTS core.customers (
    customer_id BIGSERIAL PRIMARY KEY,
    external_uuid UUID NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    tier VARCHAR(32) NOT NULL,
    tags TEXT[] NOT NULL,
    profile JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS core.products (
    product_id BIGSERIAL PRIMARY KEY,
    sku VARCHAR(64) NOT NULL UNIQUE,
    name TEXT NOT NULL,
    unit_price NUMERIC(12, 2) NOT NULL,
    specs JSONB NOT NULL,
    in_stock BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS core.orders (
    order_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES core.customers(customer_id),
    order_status VARCHAR(32) NOT NULL,
    total_amount NUMERIC(12, 2) NOT NULL,
    shipping_meta JSONB NOT NULL,
    ordered_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS core.order_items (
    item_id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES core.orders(order_id),
    product_id BIGINT NOT NULL REFERENCES core.products(product_id),
    quantity INT NOT NULL,
    line_amount NUMERIC(12, 2) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON core.orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON core.orders(order_status);
CREATE INDEX IF NOT EXISTS idx_customers_profile_gin ON core.customers USING GIN (profile);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON core.order_items(order_id);

CREATE TABLE IF NOT EXISTS analytics.daily_revenue_snapshot (
    snapshot_date DATE PRIMARY KEY,
    gross_revenue NUMERIC(14, 2) NOT NULL,
    order_count INT NOT NULL,
    top_skus TEXT[] NOT NULL
);

CREATE OR REPLACE VIEW analytics.v_customer_ltv AS
SELECT
    c.customer_id,
    c.email,
    c.tier,
    COUNT(o.order_id) AS total_orders,
    COALESCE(SUM(o.total_amount), 0)::NUMERIC(14,2) AS lifetime_value
FROM core.customers c
LEFT JOIN core.orders o ON c.customer_id = o.customer_id
GROUP BY c.customer_id, c.email, c.tier;

TRUNCATE TABLE core.order_items, core.orders, core.products, core.customers, analytics.daily_revenue_snapshot RESTART IDENTITY CASCADE;

INSERT INTO core.customers (external_uuid, email, tier, tags, profile, created_at)
SELECT
    md5('cust-' || g)::uuid,
    'customer_' || g || '@example.internal',
    CASE (g % 4)
        WHEN 0 THEN 'ENTERPRISE'
        WHEN 1 THEN 'VIP'
        WHEN 2 THEN 'PLUS'
        ELSE 'STANDARD'
    END,
    ARRAY['region_' || (g % 5), 'cohort_2026'],
    jsonb_build_object(
        'loyalty_points', (g * 17) % 5000,
        'verified', (g % 2 = 0),
        'country', CASE (g % 3) WHEN 0 THEN 'US' WHEN 1 THEN 'SG' ELSE 'JP' END
    ),
    TIMESTAMPTZ '2026-01-01 00:00:00+00' + (g || ' hours')::interval
FROM generate_series(1, 2000) AS g;

INSERT INTO core.products (sku, name, unit_price, specs, in_stock)
SELECT
    'SKU-' || lpad(g::text, 5, '0'),
    'Cloud Workload Appliance Model ' || g,
    ROUND(((g * 13.37) % 950 + 19.99)::numeric, 2),
    jsonb_build_object('weight_kg', ROUND(((g % 25) + 0.5)::numeric, 1), 'category_id', (g % 12) + 1),
    (g % 15 <> 0)
FROM generate_series(1, 500) AS g;

INSERT INTO core.orders (customer_id, order_status, total_amount, shipping_meta, ordered_at)
SELECT
    ((g - 1) % 2000) + 1,
    CASE
        WHEN g > 9950 THEN 'CANCELLED_PENDING_CLEANUP'
        WHEN (g % 5 = 0) THEN 'DELIVERED'
        WHEN (g % 5 = 1) THEN 'PROCESSING'
        WHEN (g % 5 = 2) THEN 'PAID'
        ELSE 'COMPLETED'
    END,
    ROUND((((g * 29.15) % 1200) + 25.00)::numeric, 2),
    jsonb_build_object('carrier', CASE (g % 3) WHEN 0 THEN 'DHL' WHEN 1 THEN 'FEDEX' ELSE 'UPS' END, 'priority', (g % 4 = 0)),
    TIMESTAMPTZ '2026-06-01 00:00:00+00' + (g || ' minutes')::interval
FROM generate_series(1, 10000) AS g;

INSERT INTO core.order_items (order_id, product_id, quantity, line_amount)
SELECT
    ((g - 1) % 10000) + 1,
    ((g * 7) % 500) + 1,
    (g % 5) + 1,
    ROUND((((g * 11.23) % 300) + 9.99)::numeric, 2)
FROM generate_series(1, 25000) AS g;

INSERT INTO analytics.daily_revenue_snapshot (snapshot_date, gross_revenue, order_count, top_skus)
SELECT
    DATE '2025-11-01' + (g - 1),
    ROUND((((g * 4321.89) % 90000) + 10000)::numeric, 2),
    ((g * 37) % 400) + 50,
    ARRAY['SKU-' || lpad(((g % 500) + 1)::text, 5, '0'), 'SKU-' || lpad((((g + 7) % 500) + 1)::text, 5, '0')]
FROM generate_series(1, 365) AS g;

SELECT format('GRANT CONNECT ON DATABASE ecommerce_prod TO %I', :'migrator_user')\gexec
SELECT format('GRANT USAGE ON SCHEMA public, core, analytics TO %I', :'migrator_user')\gexec
GRANT USAGE ON SCHEMA pglogical TO PUBLIC;
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO %I', :'migrator_user')\gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public, core, analytics TO %I', :'migrator_user')\gexec
SELECT format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA public, core, analytics TO %I', :'migrator_user')\gexec
