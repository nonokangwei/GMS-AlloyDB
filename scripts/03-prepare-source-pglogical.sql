-- ==============================================================================
-- Step 3: 源端 AlloyDB 生产库逻辑复制 (pglogical) 与最小权限账号初始化模板
-- 用法示例:
--   PGPASSWORD="<SRC_POSTGRES_PASSWORD>" psql -h <SRC_PSA_PRIVATE_IP> -U postgres -d postgres \
--     -v migrator_user="dms_migrator" -v migrator_password="<MIGRATOR_PASSWORD>" \
--     -f scripts/03-prepare-source-pglogical.sql
--
-- 说明:
--   1. DMS 会迁移除 template0 / template1 之外的所有数据库（可按需通过 --databases-filter 指定）。
--   2. 请对默认库 `postgres` 以及每一个待迁移的业务数据库执行步骤 B。
-- ==============================================================================
\set ON_ERROR_STOP on

-- [步骤 A] 创建迁移专用角色并赋予 AlloyDB 逻辑复制权限（全局只需执行一次）
SELECT format(
  'CREATE ROLE %I WITH LOGIN PASSWORD %L REPLICATION',
  :'migrator_user',
  :'migrator_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'migrator_user')\gexec

SELECT format('GRANT alloydbsuperuser TO %I', :'migrator_user')\gexec
SELECT format('ALTER ROLE %I WITH REPLICATION', :'migrator_user')\gexec

-- [步骤 B] 在当前连接的数据库上安装 pglogical 并对非系统 Schema 批量赋权
CREATE EXTENSION IF NOT EXISTS pglogical;
GRANT USAGE ON SCHEMA pglogical TO PUBLIC;
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO %I', :'migrator_user')\gexec

DO $$
DECLARE
  target_user text := current_setting('my.migrator_user', true);
  s record;
BEGIN
  -- 兼容通过 psql 变量传入的场景
  NULL;
END
$$;

-- 对当前库中所有非 pg_* / information_schema 的业务 Schema 自动授予只读快照与序列读取权限
SELECT format('GRANT USAGE ON SCHEMA %I TO %I', nspname, :'migrator_user')
FROM pg_namespace
WHERE nspname NOT LIKE 'pg_%'
  AND nspname NOT IN ('information_schema', 'pglogical')\gexec

SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', nspname, :'migrator_user')
FROM pg_namespace
WHERE nspname NOT LIKE 'pg_%'
  AND nspname NOT IN ('information_schema', 'pglogical')\gexec

SELECT format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', nspname, :'migrator_user')
FROM pg_namespace
WHERE nspname NOT LIKE 'pg_%'
  AND nspname NOT IN ('information_schema', 'pglogical')\gexec

-- 巡检当前数据库中缺少主键 (Primary Key) 的业务表（无主键表在 CDC 阶段仅同步 INSERT，不同步 UPDATE/DELETE）
SELECT
  n.nspname AS schema_name,
  c.relname AS table_without_pk
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT LIKE 'pg_%'
  AND n.nspname NOT IN ('information_schema', 'pglogical')
  AND NOT EXISTS (
    SELECT 1 FROM pg_constraint con
    WHERE con.conrelid = c.oid AND con.contype = 'p'
  )
ORDER BY 1, 2;
