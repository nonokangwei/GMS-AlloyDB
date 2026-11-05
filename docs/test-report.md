# 跨项目 AlloyDB 在线迁移端到端测试验证报告（DMS + PSC Interface）

- **测试日期**：2026-11-05
- **迁移方案**：Database Migration Service (DMS) 标准持续迁移（`pglogical`）+ Private Service Connect (PSC) Interface
- **数据库引擎版本**：AlloyDB for PostgreSQL 16（`PostgreSQL 16.14 on x86_64-pc-linux-gnu`）
- **总体测试结论**：**通过（PASS）** — 跨项目私网直连免代理打通，全量导出（37,965 行）、在线实时 CDC 增删改同步（885 行变更，0 字节复制延迟）、分钟级 Promote 割接（76.7 秒）、割接后自增序列连续性及在线读写能力均 **100% 校验一致**。

---

## 目录

1. [测试目标与验证范围](#1-测试目标与验证范围)
2. [测试拓扑与环境规格](#2-测试拓扑与环境规格)
3. [仿真业务数据集设计](#3-仿真业务数据集设计)
4. [全流程关键步骤耗时统计](#4-全流程关键步骤耗时统计)
5. [跨项目网络连通性与复制流实测验证](#5-跨项目网络连通性与复制流实测验证)
6. [三阶段数据完整性与 MD5 指纹对账结果](#6-三阶段数据完整性与-md5-指纹对账结果)
7. [Promote 割接与自增序列（Sequence）行为实测](#7-promote-割接与自增序列sequence行为实测)
8. [实测发现的关键踩坑点与修复总结](#8-实测发现的关键踩坑点与修复总结)

---

## 1. 测试目标与验证范围

本次端到端测试旨在真实还原企业生产环境中**源端 AlloyDB 采用 PSA 私网架构、需跨 GCP 项目在线迁移至新项目 AlloyDB** 的典型场景，重点验证以下技术指标：

1. **跨项目免代理私网互通**：验证在不配置跨项目 VPC Peering、不部署反向 SSH 代理虚机、不修改跨项目 IAM 网络管理策略的前提下，仅通过源端 VPC 的 `Network Attachment`（`ACCEPT_MANUAL` 白名单模式）与目标端 PSC AlloyDB 实例绑定实现直连互通。
2. **多库多 Schema 复杂对象迁移**：覆盖多数据库（默认库 `postgres` + 业务库 `ecommerce_prod`）、多 Schema（`public`、`core`、`analytics`）、外键约束、B-Tree 复合索引、JSONB/ARRAY GIN 索引、聚合视图（View）及自增序列（Sequence）。
3. **持续 CDC 增量一致性**：在迁移处于 `CDC` 阶段时，模拟线上高并发混合事务（`INSERT`、`UPDATE`、`DELETE` 及 JSONB 字段增量合并），验证整表行级确定性 MD5 指纹零误差。
4. **分钟级在线割接（Promote）**：实测 `promote` 割接停机窗口时长、自增主键序列步长同步策略以及割接后目标库独立读写能力。

---

## 2. 测试拓扑与环境规格

> 注：本报告中所有项目标识已脱敏为通用占位符 `<SOURCE_PROJECT_ID>`、`<DEST_PROJECT_ID>` 与 `<ALLOYDB_SERVICE_OWNED_PROJECT_NUMBER>`。

| 维度 | 源端环境（Source） | 目标端环境（Destination） |
| :--- | :--- | :--- |
| **所属项目** | `<SOURCE_PROJECT_ID>` | `<DEST_PROJECT_ID>` |
| **部署区域（Region）** | `us-central1` | `us-central1` |
| **AlloyDB 集群 / 实例** | `src-alloydb-psa` / `src-alloydb-psa-primary`（2 vCPU） | `dst-alloydb-psc` / `dst-alloydb-psc-primary`（2 vCPU） |
| **数据库网络模式** | **Private Services Access (PSA)** | **Private Service Connect (PSC)** |
| **VPC 与子网规划** | `dms-mig-src-vpc`<br>• 业务子网：`10.10.1.0/24`<br>• PSC 接口专用子网：`10.10.2.0/24`<br>• PSA 托管网段：`10.11.0.0/16` | `dms-mig-dst-vpc`<br>• 验证业务子网：`10.20.1.0/24` |
| **关键网络接入点** | • 源库 PSA 私网 IP：`10.11.4.2`<br>• 跨项目 Network Attachment：`dms-src-net-attachment`（分配给目标端网卡 IP：`10.10.2.2`） | • 入站业务访问 PSC Endpoint：`dms-dst-psc-ep`（`10.20.1.3`）<br>• 出站绑定：`projects/<SOURCE_PROJECT_ID>/regions/us-central1/networkAttachments/dms-src-net-attachment` |
| **核心数据库参数** | `alloydb.logical_decoding=on`<br>`alloydb.enable_pglogical=on`<br>`wal_sender_timeout=0`<br>`max_replication_slots=60`<br>`max_wal_senders=60`<br>`max_worker_processes=64` | `alloydb.enable_pglogical=on`<br>`alloydb.logical_decoding=on` |

---

## 3. 仿真业务数据集设计

在源端 PSA AlloyDB 中灌入了跨 2 个数据库、3 个 Schema、6 张业务表与 1 个分析视图的初始存量数据集（共计 **37,965 行**）：

| 数据库 | Schema.对象名 | 对象类型 | 初始存量行数 | 覆盖的数据类型与约束特征 |
| :--- | :--- | :--- | ---: | :--- |
| `postgres` | `public.migration_heartbeat` | Table | 100 | `BIGSERIAL` 主键、`TEXT`、`JSONB`、`TIMESTAMPTZ` |
| `ecommerce_prod` | `core.customers` | Table | 2,000 | `BIGSERIAL` 主键、`UUID` 唯一键、`TEXT[]` 数组、`JSONB` + GIN 索引 |
| `ecommerce_prod` | `core.products` | Table | 500 | `BIGSERIAL` 主键、`SKU` 唯一约束、`NUMERIC(12,2)`、`BOOLEAN` |
| `ecommerce_prod` | `core.orders` | Table | 10,000 | 外键关联 `customers`、复合 B-Tree 索引、`JSONB` 物流扩展字段 |
| `ecommerce_prod` | `core.order_items` | Table | 25,000 | 双外键关联 `orders`（`ON DELETE CASCADE`）与 `products`、`NUMERIC(12,2)` |
| `ecommerce_prod` | `analytics.daily_revenue_snapshot` | Table | 365 | `DATE` 主键、365 天日度营收快照聚合指标 |
| `ecommerce_prod` | `analytics.v_customer_ltv` | View | 2,000（聚合视图） | `LEFT JOIN` 跨表实时计算客户历史订单数与终身价值（LTV） |

---

## 4. 全流程关键步骤耗时统计

以下为本次实测通过 GCP API Operations 记录的精确阶段耗时：

| 阶段步骤 | 执行命令 / 动作 | 实测耗时 | 状态结果 |
| :--- | :--- | ---: | :--- |
| 1. 目标端集群降级准备 | `gcloud database-migration migration-jobs demote-destination` | **13.76 秒** | 成功切换为外部复制接收状态 |
| 2. 迁移作业端到端预检 | `gcloud database-migration migration-jobs verify` | **39.45 秒** | **0 错误**通过连通性、参数与 `pglogical` 校验 |
| 3. 启动作业至全量开始 | `start` -> 进入 `FULL_DUMP` 阶段 | **130.98 秒** | 自动初始化订阅槽与多库 Schema 结构同步 |
| 4. 历史存量全量导出导入 | `FULL_DUMP` -> 自动流转进入 `CDC` 阶段（37,965 行 + 索引/视图） | **56.75 秒** | 全量快照完成，无缝切入实时增量复制 |
| 5. 在线增量写入同步 | 源库并发执行混合事务（新增 785 行、更新 300 行、删除 150 行） | **< 2 秒** | `sent_lsn` 与 `replay_lsn` 实时追平（0 字节延迟） |
| 6. **主库正式割接（停写窗口）** | `gcloud database-migration migration-jobs promote` -> `COMPLETED` | **76.69 秒** | 目标集群自动恢复为 `PRIMARY` (`READY`) 独立可读写主库 |

---

## 5. 跨项目网络连通性与复制流实测验证

### 5.1 源端 Network Attachment 跨项目自动握手验证

在目标端主实例绑定 `--psc-network-attachment-uri` 后，查询源项目 `dms-src-net-attachment` 状态，确认目标 AlloyDB 集群专属托管服务项目（`<ALLOYDB_SERVICE_OWNED_PROJECT_NUMBER>`）发起的 PSC Interface 连接被白名单精准放行，并自动从源端 `10.10.2.0/24` 子网获得本地私网 IP **`10.10.2.2`**：

```json
{
  "connectionEndpoints": [
    {
      "ipAddress": "10.10.2.2",
      "projectIdOrNum": "<ALLOYDB_SERVICE_OWNED_PROJECT_NUMBER>",
      "status": "ACCEPTED",
      "subnetwork": "https://www.googleapis.com/compute/v1/projects/<SOURCE_PROJECT_ID>/regions/us-central1/subnetworks/dms-mig-psc-nat-subnet"
    }
  ],
  "connectionPreference": "ACCEPT_MANUAL",
  "name": "dms-src-net-attachment",
  "producerAcceptLists": [
    "<ALLOYDB_SERVICE_OWNED_PROJECT_NUMBER>"
  ]
}
```

### 5.2 源库 `pg_stat_replication` 实时 WAL 复制流观测

在 `CDC` 阶段执行混合增删改压测后，于源端 PSA AlloyDB（`10.11.4.2`）查询 `pg_stat_replication`，清晰观测到来自跨项目 PSC Interface 网卡 IP **`10.10.2.2`** 的逻辑复制流处于 `streaming` 状态，且发送位点（`sent_lsn`）与目标端重放位点（`replay_lsn`）完全相等（`0/7091708`，延迟为 `0`）：

```text
     application_name      | client_addr |   state   | sent_lsn  | write_lsn | flush_lsn | replay_lsn | sync_state
---------------------------+-------------+-----------+-----------+-----------+-----------+------------+------------
 alloydb_dst_alloydb_psc_0 | 10.10.2.2   | streaming | 0/7091708 | 0/7091708 | 0/7091708 | 0/7091708  | async
 alloydb_dst_alloydb_psc_0 | 10.10.2.2   | streaming | 0/7091708 | 0/7091708 | 0/7091708 | 0/7091708  | async
 alloydb_dst_alloydb_psc_1 | 10.10.2.2   | streaming | 0/7091708 | 0/7091708 | 0/7091708 | 0/7091708  | async
```

---

## 6. 三阶段数据完整性与 MD5 指纹对账结果

我们使用 `scripts/06-verify-checksums.sql` 在以下三个关键检查点分别对源库（`10.11.4.2`）和目标库（`10.20.1.3`）进行了全表确定性排序聚合 MD5 对账：

### 检查点 1：全量快照完成（初入 `CDC` 阶段）对账结果

| 表 / 视图全限定名 | 源库行数 | 目标库行数 | 关键金额汇总 (`SUM`) | 源库整表 MD5 | 目标库整表 MD5 | 结果 |
| :--- | ---: | ---: | ---: | :--- | :--- | :---: |
| `postgres.public.migration_heartbeat` | 100 | 100 | — | `6a7505ca0d770de9ae262a4b21a702d5` | `6a7505ca0d770de9ae262a4b21a702d5` | 一致 |
| `ecommerce_prod.core.customers` | 2,000 | 2,000 | `0.00` | `79fece0ca39f48191d68eb7ea32ba991` | `79fece0ca39f48191d68eb7ea32ba991` | 一致 |
| `ecommerce_prod.core.products` | 500 | 500 | `248187.50` | `99182c4d022171c2bae4c1db3ae84bf8` | `99182c4d022171c2bae4c1db3ae84bf8` | 一致 |
| `ecommerce_prod.core.orders` | 10,000 | 10,000 | `6235350.00` | `a15d364fb90abde5ae4a3c8c5fdce661` | `a15d364fb90abde5ae4a3c8c5fdce661` | 一致 |
| `ecommerce_prod.core.order_items` | 25,000 | 25,000 | `3996025.00` | `b1222a071244f7b5d679d6b04755d234` | `b1222a071244f7b5d679d6b04755d234` | 一致 |
| `ecommerce_prod.analytics.daily_revenue_snapshot` | 365 | 365 | `19900642.55` | `096e0f865a81a794512eef7ec7433762` | `096e0f865a81a794512eef7ec7433762` | 一致 |
| `ecommerce_prod.analytics.v_customer_ltv` (VIEW) | 2,000 | 2,000 | `6235350.00` | `5f0903fe649a579f2feefcbe30825382` | `5f0903fe649a579f2feefcbe30825382` | 一致 |

### 检查点 2 & 3：在线 `CDC` 混合增删改压测后 & `Promote` 割接完成后对账结果

在 `CDC` 阶段向源库执行 `scripts/05-simulate-cdc-writes.sql`（插入 15 条心跳、插入 20 名新 VIP 客户、插入 250 笔新订单与 500 条订单明细、对 300 笔历史订单执行金额上调 `+19.99` 与 JSONB 属性合并、删除 50 笔取消订单及关联的 100 条明细），在 `CDC` 期间及 `Promote` 完成后复测，源库与目标库全部表与视图分毫不差：

| 表 / 视图全限定名 | 变更后源库行数 | 割接后目标库行数 | 变更后金额汇总 (`SUM`) | 源库整表 MD5 | 目标库整表 MD5 | 结果 |
| :--- | ---: | ---: | ---: | :--- | :--- | :---: |
| `postgres.public.migration_heartbeat` | 115 | 115 | — | `8921d81586db496ddb529915f54cbe07` | `8921d81586db496ddb529915f54cbe07` | 一致 |
| `ecommerce_prod.core.customers` | 2,020 | 2,020 | `0.00` | `c8ab1b3703311dea9eacf02836e09307` | `c8ab1b3703311dea9eacf02836e09307` | 一致 |
| `ecommerce_prod.core.products` | 500 | 500 | `248187.50` | `99182c4d022171c2bae4c1db3ae84bf8` | `99182c4d022171c2bae4c1db3ae84bf8` | 一致 |
| `ecommerce_prod.core.orders` | 10,200 | 10,200 | `6345874.50` | `76e602ee240c5c8badcecf6a13757311` | `76e602ee240c5c8badcecf6a13757311` | 一致 |
| `ecommerce_prod.core.order_items` | 25,400 | 25,400 | `4010689.50` | `53d31a2f13fbc6de77302b8a172dec59` | `53d31a2f13fbc6de77302b8a172dec59` | 一致 |
| `ecommerce_prod.analytics.daily_revenue_snapshot` | 365 | 365 | `19900642.55` | `096e0f865a81a794512eef7ec7433762` | `096e0f865a81a794512eef7ec7433762` | 一致 |
| `ecommerce_prod.analytics.v_customer_ltv` (VIEW) | 2,020 | 2,020 | `6345874.50` | `b06785dc58078668b6d20b3907292729` | `b06785dc58078668b6d20b3907292729` | 一致 |

---

## 7. Promote 割接与自增序列（Sequence）行为实测

### 7.1 序列自动 `+1000` 安全缓冲同步验证

实测对比了源库当前序列值、目标库 `CDC` 期间序列值以及 `Promote` 割接完成后的最终序列值：

| 序列名称 | 源库最终 `last_value` | 目标库 Promote 后 `last_value` | 差值说明 |
| :--- | ---: | ---: | :--- |
| `migration_heartbeat_heartbeat_id_seq` | `115` | `1115` | 自动施加 `+1000` 安全偏移，杜绝主键回退冲突 |
| `customers_customer_id_seq` | `2020` | `3020` | 自动施加 `+1000` 安全偏移 |
| `products_product_id_seq` | `500` | `1500` | 自动施加 `+1000` 安全偏移 |
| `orders_order_id_seq` | `10250` | `11250` | 自动施加 `+1000` 安全偏移 |
| `order_items_item_id_seq` | `25500` | `26500` | 自动施加 `+1000` 安全偏移 |

### 7.2 割接后目标端 PSC 主集群在线写入验证

`Promote` 完成后，检查目标集群元数据已变为 `"clusterType": "PRIMARY"` 且 `"state": "READY"`。通过目标项目的 PSC Endpoint（`10.20.1.3`）连接 `ecommerce_prod` 库，验证非恢复模式及不带显式主键的自增写入：

```text
 is_in_recovery |                                         version
----------------+------------------------------------------------------------------------------------------
 f              | PostgreSQL 16.14 on x86_64-pc-linux-gnu, compiled by Debian clang version 12.0.1, 64-bit
(1 row)

 order_id | customer_id |      order_status       | total_amount |          ordered_at
----------+-------------+-------------------------+--------------+-------------------------------
    11252 |           1 | POST_CUTOVER_LIVE_WRITE |       888.88 | 2026-11-05 10:48:03.032403+00
(1 row)

INSERT 0 1
```

测试证明目标端 PSC AlloyDB 已作为独立主库正常接管在线事务读写，自增主键平稳递增且无任何主键碰撞。

---

## 8. 实测发现的关键踩坑点与修复总结

| 编号 | 实测遇到的问题现象 | 根本原因分析 | 最终修复与最佳实践（已沉淀至自动化脚本） |
| :---: | :--- | :--- | :--- |
| 1 | 源端 AlloyDB 实例设置 `max_replication_slots=20` 报错 `minimum allowed value is 50` | AlloyDB 引擎层对 `max_replication_slots` 和 `max_wal_senders` 设定了高于开源 PostgreSQL 的最小阈值（`50`） | 统一配置为 `max_replication_slots=60,max_wal_senders=60,max_worker_processes=64` |
| 2 | 若源端 Network Attachment 的 `--producer-accept-list` 仅配置 `<DEST_PROJECT_ID>` 会导致挂载失败 | PSC AlloyDB 实例网卡挂载请求实际来自 Google 托管单租户项目 `pscConfig.serviceOwnedProjectNumber` | 先创建目标空集群，通过 `describe` 提取 `pscConfig.serviceOwnedProjectNumber` 填入源端 Network Attachment 白名单，再创建目标主实例 |
| 3 | 直接执行 `gcloud database-migration migration-jobs verify` 报错 `Destination has to be demoted` | 针对预先创建好的目标 AlloyDB 集群，CLI 需显式触发目标库降级为外部副本接收态（Console 界面会自动隐式执行该步） | 在脚本 `07-run-dms-migration.sh` 中将 `demote-destination` -> `verify` -> `start` 串联为标准流水线 |
| 4 | 清理环境时若先删源端 Network Attachment 会因资源仍被跨项目引用而失败 | 目标端 AlloyDB 实例仍在底层持有该 Network Attachment 的 PSC Interface 网卡句柄 | 在 `99-cleanup.sh` 中严格固化“先删 DMS 作业 -> 再删目标端 AlloyDB 集群释放句柄 -> 最后删源端 Network Attachment 与网络”的顺序 |
