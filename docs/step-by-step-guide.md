# 跨项目 AlloyDB 在线迁移保姆级实施手册（DMS + PSC Interface）

本文档提供从 **源项目（`<SOURCE_PROJECT_ID>`，采用 Private Services Access [PSA] 私网连接）** 将 AlloyDB for PostgreSQL 在线迁移至 **目标项目（`<DEST_PROJECT_ID>`，采用 Private Service Connect [PSC] 连接）** 的完整端到端操作指南，同时涵盖 **Google Cloud Console 界面指引** 与 **`gcloud` CLI 可直接复制命令**。

---

## 目录

- [一、迁移前准备与环境规划](#一迁移前准备与环境规划)
- [二、阶段 1：配置源端网络与源端 AlloyDB 逻辑复制参数](#二阶段-1配置源端网络与源端-alloydb-逻辑复制参数)
- [三、阶段 2：在源库安装 pglogical 并创建最小权限迁移账号](#三阶段-2在源库安装-pglogical-并创建最小权限迁移账号)
- [四、阶段 3：创建目标端 PSC AlloyDB 与跨项目 Network Attachment](#四阶段-3创建目标端-psc-alloydb-与跨项目-network-attachment)
- [五、阶段 4：配置目标端业务接入端点（PSC Endpoint / Auth Proxy）](#五阶段-4配置目标端业务接入端点psc-endpoint--auth-proxy)
- [六、阶段 5：创建 DMS 连接配置并启动持续迁移作业](#六阶段-5创建-dms-连接配置并启动持续迁移作业)
- [七、阶段 6：全量与 CDC 增量监控、数据一致性对账](#七阶段-6全量与-cdc-增量监控数据一致性对账)
- [八、阶段 7：业务停写追平、正式割接（Promote）与收尾](#八阶段-7业务停写追平正式割接promote与收尾)
- [九、常见问题与排障指南（Troubleshooting FAQ）](#九常见问题与排障指南troubleshooting-faq)

---

## 一、迁移前准备与环境规划

### 1.1 变量与规划表

在开始操作前，建议在本地终端统一声明以下环境变量（亦可直接运行仓库中的 `source ./scripts/env.example.sh` 交互式填充）：

```bash
export SOURCE_PROJECT_ID="<SOURCE_PROJECT_ID>"     # 源端 AlloyDB 所在的 GCP 项目 ID
export DEST_PROJECT_ID="<DEST_PROJECT_ID>"         # 目标端 AlloyDB 与 DMS 所在的 GCP 项目 ID
export REGION="us-central1"                        # 源端与目标端必须位于同一区域 (Region)

# 源端已有（或测试新建）的 VPC 与 AlloyDB 资源名
export SRC_VPC_NAME="dms-mig-src-vpc"
export SRC_PSC_NAT_SUBNET="dms-mig-psc-nat-subnet" # 为 Network Attachment 准备的专用子网
export SRC_PSC_NAT_CIDR="10.10.2.0/24"             # 建议 >= /28，避免与源端现有子网重叠
export SRC_NETWORK_ATTACHMENT="dms-src-net-attachment"
export SRC_CLUSTER_ID="src-alloydb-psa"
export SRC_INSTANCE_ID="src-alloydb-psa-primary"

# 目标端新建的 PSC AlloyDB 与 DMS 资源名
export DST_CLUSTER_ID="dst-alloydb-psc"
export DST_INSTANCE_ID="dst-alloydb-psc-primary"
export DMS_SRC_PROFILE_ID="src-alloydb-cp"
export DMS_DST_PROFILE_ID="dst-alloydb-cp"
export DMS_MIGRATION_JOB_ID="alloydb-cross-proj-mj"
export MIGRATOR_USER="dms_migrator"
```

### 1.2 确认所需 API 已启用

- **源项目 `<SOURCE_PROJECT_ID>`**：Compute Engine API (`compute.googleapis.com`)、AlloyDB API (`alloydb.googleapis.com`)、Service Networking API (`servicenetworking.googleapis.com`)。
- **目标项目 `<DEST_PROJECT_ID>`**：除上述三项 API 外，还需启用 **Database Migration API (`datamigration.googleapis.com`)**。

### 1.3 数据库对象与兼容性检查清单

| 检查项 | 行为说明与建议 |
| :--- | :--- |
| **表主键（Primary Key）** | 包含主键的表完整支持全量快照与 `INSERT` / `UPDATE` / `DELETE` 实时同步；**无主键表**仅支持全量导出及后续 `INSERT` 同步（不支持 `UPDATE` / `DELETE`）。建议迁移前为业务核心表补齐主键或使用 `REPLICA IDENTITY` 替代方案。 |
| **多数据库自动发现** | DMS 会自动发现并迁移源端集群下所有非系统数据库（排除 `template0`、`template1`、`alloydbadmin`、`alloydbmetadata`）。 |
| **自定义账号与角色** | 逻辑复制会自动迁移表结构、索引、视图、函数与序列，但**不会自动迁移除 `postgres` 以外的普通数据库角色与密码**。请在割接前于目标端重建应用账号并赋权。 |
| **大对象（Large Objects）** | PostgreSQL `lo_*` 大对象不支持逻辑复制，普通 `BYTEA`、`JSONB`、`TEXT`、`ARRAY` 等字段均完整支持。 |

---

## 二、阶段 1：配置源端网络与源端 AlloyDB 逻辑复制参数

> 如果您是在空项目中从零模拟完整 PoC，可直接运行 `./scripts/01-setup-source-psa.sh`。若您正在迁移**线上已有的 PSA AlloyDB**，请按本节步骤增量配置。

### 2.1 在源端 VPC 创建 PSC Interface 专用子网与防火墙规则

为了安全审计与最小权限隔离，建议在源端 PSA AlloyDB 所在的 VPC（`${SRC_VPC_NAME}`）中单独划分一个小型 RFC 1918 子网专门供 `Network Attachment` 分配网卡 IP，并允许该子网访问源端 AlloyDB 的 `5432` 端口。

```bash
# 1. 在源端 VPC 创建 PSC Interface 专用子网
gcloud compute networks subnets create "${SRC_PSC_NAT_SUBNET}" \
  --project="${SOURCE_PROJECT_ID}" \
  --network="${SRC_VPC_NAME}" \
  --region="${REGION}" \
  --range="${SRC_PSC_NAT_CIDR}" \
  --enable-private-ip-google-access

# 2. 放行该子网内的出站网卡连接访问源端 PSA 网段的 PostgreSQL 5432 端口
gcloud compute firewall-rules create "${SRC_VPC_NAME}-allow-dms-psc-if" \
  --project="${SOURCE_PROJECT_ID}" \
  --network="${SRC_VPC_NAME}" \
  --direction=INGRESS \
  --allow=tcp:5432 \
  --source-ranges="${SRC_PSC_NAT_CIDR}"
```

*Console 界面路径*：进入源项目 **VPC 网络 (VPC networks)** -> 选择源端 VPC -> **子网 (Subnets)** -> 点击 **添加子网 (Add subnet)**。

### 2.2 开启源端 AlloyDB 主实例的逻辑复制参数

DMS 标准持续迁移依赖 PostgreSQL 的 `pglogical` 扩展。请为源端 AlloyDB 主实例配置以下 Database Flags：

> **重要避坑提示**：在 AlloyDB 中，`max_replication_slots` 和 `max_wal_senders` 的**系统允许最小值为 `50`**（而非常规自建 PostgreSQL 文档中的 `10` 或 `20`）。传入小于 `50` 的数值会导致参数更新直接报错！此外，修改 `max_replication_slots`、`max_wal_senders` 或 `alloydb.enable_pglogical` 会触发实例短暂重启，请在维护窗口操作。

```bash
gcloud alloydb instances update "${SRC_INSTANCE_ID}" \
  --project="${SOURCE_PROJECT_ID}" \
  --cluster="${SRC_CLUSTER_ID}" \
  --region="${REGION}" \
  --database-flags=alloydb.logical_decoding=on,alloydb.enable_pglogical=on,wal_sender_timeout=0,max_replication_slots=60,max_wal_senders=60,max_worker_processes=64
```

查询并记录源端 AlloyDB 主实例的 PSA 私网 IP（例如 `10.11.4.2`）：

```bash
gcloud alloydb instances describe "${SRC_INSTANCE_ID}" \
  --project="${SOURCE_PROJECT_ID}" \
  --cluster="${SRC_CLUSTER_ID}" \
  --region="${REGION}" \
  --format="value(ipAddress)"
```

---

## 三、阶段 2：在源库安装 pglogical 并创建最小权限迁移账号

使用源端 VPC 内的客户端机器（或 Bastion 跳板机）以 `postgres` 管理员连接源端 AlloyDB：

### 3.1 创建专用迁移角色（全局执行一次）

```sql
CREATE USER dms_migrator WITH LOGIN REPLICATION PASSWORD '<STRONG_MIGRATOR_PASSWORD>';
GRANT alloydbsuperuser TO dms_migrator;
```

### 3.2 在**每一个需要迁移的数据库**中安装 `pglogical` 并赋权

> 注意：哪怕业务数据存放在自定义的业务库（如 `ecommerce_prod`），也建议同时在默认库 `postgres` 和所有自定义业务库中执行以下授权语句（可直接复用 `scripts/03-prepare-source-pglogical.sql`）：

```sql
CREATE EXTENSION IF NOT EXISTS pglogical;

-- 对该数据库中除 pg_catalog、information_schema 以外的所有业务 Schema 赋权：
GRANT USAGE ON SCHEMA public TO dms_migrator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dms_migrator;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO dms_migrator;

-- 若存在其他自定义业务 Schema（如 core、analytics），请一并赋权：
-- GRANT USAGE ON SCHEMA core, analytics TO dms_migrator;
-- GRANT SELECT ON ALL TABLES IN SCHEMA core, analytics TO dms_migrator;
-- GRANT SELECT ON ALL SEQUENCES IN SCHEMA core, analytics TO dms_migrator;

-- 赋予 pglogical 元数据读取权限
GRANT USAGE ON SCHEMA pglogical TO dms_migrator;
GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO dms_migrator;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA pglogical TO dms_migrator;
```

*说明*：在 AlloyDB 上执行 `GRANT SELECT ON ALL TABLES IN SCHEMA public` 时，终端可能会输出几行 `WARNING: no privileges were granted for "g_columnar_*"` 或 `"google_db_advisor_*"` 提示。这是 AlloyDB 内置列存与顾问系统视图的正常行为，完全不影响 DMS 预检与数据迁移。

---

## 四、阶段 3：创建目标端 PSC AlloyDB 与跨项目 Network Attachment

这一阶段是整个无代理跨项目连通方案的核心（对应脚本 `./scripts/02-setup-dest-psc-and-na.sh`）。**请严格按照“先建目标空集群 -> 查服务托管项目号 -> 建源端 Network Attachment -> 建目标主实例”的顺序执行**：

### 4.1 在目标项目创建启用 PSC 的 AlloyDB 集群

```bash
gcloud alloydb clusters create "${DST_CLUSTER_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --password="<DST_POSTGRES_PASSWORD>" \
  --database-version=POSTGRES_16 \
  --enable-private-service-connect
```

*Console 界面路径*：在目标项目进入 **AlloyDB** -> **创建集群 (Create cluster)** -> 在 **网络 (Networking)** 部分选择 **Private Service Connect**。

### 4.2 获取目标集群专属的后台服务项目编号（`serviceOwnedProjectNumber`）

启用 PSC 的 AlloyDB 集群在底层运行于 Google 为该集群独立分配的单租户托管项目中。我们需要提取该项目编号用于源端跨项目白名单授权：

```bash
SERVICE_OWNED_PROJECT_NUM="$(gcloud alloydb clusters describe "${DST_CLUSTER_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(pscConfig.serviceOwnedProjectNumber)')"

echo "目标集群专属服务项目编号: ${SERVICE_OWNED_PROJECT_NUM}"
```

### 4.3 在源项目创建手动白名单模式（`ACCEPT_MANUAL`）的 Network Attachment

> **关键安全实践**：使用 `--connection-preference=ACCEPT_MANUAL` 并仅将上一步查出的 `${SERVICE_OWNED_PROJECT_NUM}` 加入 `--producer-accept-list`。
> **切勿误填 `<DEST_PROJECT_ID>`**：因为实际发起跨项目网卡连接请求的是目标 AlloyDB 所在的托管服务项目 `${SERVICE_OWNED_PROJECT_NUM}`；若只填 `<DEST_PROJECT_ID>`，网卡挂载会被拒绝！

```bash
gcloud compute network-attachments create "${SRC_NETWORK_ATTACHMENT}" \
  --project="${SOURCE_PROJECT_ID}" \
  --region="${REGION}" \
  --subnets="${SRC_PSC_NAT_SUBNET}" \
  --connection-preference=ACCEPT_MANUAL \
  --producer-accept-list="${SERVICE_OWNED_PROJECT_NUM}" \
  --description="Cross-project PSC Interface for AlloyDB DMS migration"
```

*Console 界面路径*：在源项目进入 **Network Services (网络服务)** -> **Private Service Connect** -> **Network attachments (网络挂载点)** -> **Create network attachment** -> 选择专用子网，连接偏好选择 **Accept connections for selected projects**，填入 `${SERVICE_OWNED_PROJECT_NUM}`。

### 4.4 在目标项目创建 AlloyDB 主实例并绑定跨项目 Network Attachment

```bash
NA_URI="projects/${SOURCE_PROJECT_ID}/regions/${REGION}/networkAttachments/${SRC_NETWORK_ATTACHMENT}"

gcloud alloydb instances create "${DST_INSTANCE_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --cluster="${DST_CLUSTER_ID}" \
  --region="${REGION}" \
  --instance-type=PRIMARY \
  --availability-type=ZONAL \
  --cpu-count=2 \
  --allowed-psc-projects="${DEST_PROJECT_ID}" \
  --psc-network-attachment-uri="${NA_URI}" \
  --database-flags=alloydb.enable_pglogical=on,alloydb.logical_decoding=on
```

> 生产高可用建议：线上正式集群请将 `--availability-type=ZONAL` 替换为 `--availability-type=REGIONAL`，并根据源库规格匹配 `--cpu-count`。若您的客户端分布在多个消费端项目中，可在 `--allowed-psc-projects` 中以逗号分隔填入多个项目 ID 或项目编号。

### 4.5 验证跨项目 PSC Interface 是否已自动握手成功

目标主实例创建完成后，在源项目查看 `Network Attachment` 状态：

```bash
gcloud compute network-attachments describe "${SRC_NETWORK_ATTACHMENT}" \
  --project="${SOURCE_PROJECT_ID}" \
  --region="${REGION}" \
  --format="json(name,connectionPreference,producerAcceptLists,connectionEndpoints)"
```

当返回的 `connectionEndpoints` 数组中出现 `"status": "ACCEPTED"` 且已从 `${SRC_PSC_NAT_SUBNET}` 分配出内网 IP（例如 `10.10.2.2`）时，说明跨项目私网直连通道已成功打通！

---

## 五、阶段 4：配置目标端业务接入端点（PSC Endpoint / Auth Proxy）

由于目标端 AlloyDB 采用了 PSC 架构，目标项目中的应用若要通过私网 IP 直连目标数据库（用于迁移对账及割接后承载业务），只需在目标端业务 VPC 中创建一个指向目标实例 `serviceAttachmentLink` 的 **PSC Endpoint（转发规则）**：

```bash
# 1. 查询目标 AlloyDB 实例的 Service Attachment URI
SA_LINK="$(gcloud alloydb instances describe "${DST_INSTANCE_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --cluster="${DST_CLUSTER_ID}" \
  --region="${REGION}" \
  --format='value(pscInstanceConfig.serviceAttachmentLink)')"

# 2. 在目标端业务 VPC 的子网中预留一个内部静态 IP
gcloud compute addresses create dms-dst-psc-ip \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --subnet="<DEST_APP_SUBNET>"

# 3. 创建 PSC Endpoint 转发规则并开启全局访问（如需跨区连接）
gcloud compute forwarding-rules create dms-dst-psc-ep \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --network="<DEST_APP_VPC>" \
  --address=dms-dst-psc-ip \
  --target-service-attachment="${SA_LINK}"
```

创建后执行 `gcloud compute forwarding-rules describe dms-dst-psc-ep --region="${REGION}" --project="${DEST_PROJECT_ID}"`，确认 `pscConnectionStatus: ACCEPTED`，目标端客户端即可直接通过 `dms-dst-psc-ip` 的内网 IP 连接目标库 `5432` 端口。

*(进阶推荐：您也可以在目标端 VPC 配置针对 `pscDnsName` 的 Cloud DNS 私网解析记录，并搭配 **AlloyDB Auth Proxy** 连接，无需手写 IP 地址。)*

---

## 六、阶段 5：创建 DMS 连接配置并启动持续迁移作业

对应自动化脚本：`./scripts/07-run-dms-migration.sh`。以下操作均在 **目标项目 `<DEST_PROJECT_ID>`** 中执行：

### 6.1 创建源端连接配置（Source Connection Profile）

将 `--host` 指向阶段 1 查询到的源端 PSA AlloyDB 内网 IP（如 `10.11.4.2`）：

```bash
gcloud database-migration connection-profiles create postgresql "${DMS_SRC_PROFILE_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --role=SOURCE \
  --host="<SOURCE_PSA_PRIVATE_IP>" \
  --port=5432 \
  --username="${MIGRATOR_USER}" \
  --password="<STRONG_MIGRATOR_PASSWORD>" \
  --display-name="Source AlloyDB PSA Profile" \
  --no-async
```

### 6.2 创建目标端连接配置（指向已创建的 PSC AlloyDB 集群）

```bash
gcloud database-migration connection-profiles create postgresql "${DMS_DST_PROFILE_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --role=DESTINATION \
  --alloydb-cluster="${DST_CLUSTER_ID}" \
  --username=postgres \
  --password="<DST_POSTGRES_PASSWORD>" \
  --display-name="Destination AlloyDB PSC Profile" \
  --no-async
```

### 6.3 创建持续迁移作业（Continuous Migration Job）

> 注意：因为目标端 AlloyDB 集群已经通过 PSC Interface 具备了直连源端 VPC 的能力，此处创建迁移作业时**不需要**传 `--peer-vpc` 或 `--static-ip` 参数（对应 Console 向导中选择连通性方式为 **None / PSC Interface**）。

```bash
gcloud database-migration migration-jobs create "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --display-name="Cross-Project AlloyDB PSA to PSC Migration" \
  --source="${DMS_SRC_PROFILE_ID}" \
  --destination="${DMS_DST_PROFILE_ID}" \
  --type=CONTINUOUS \
  --no-async
```

### 6.4 执行目标库降级（`demote-destination`）与预检（`verify`）

> **CLI 必读细节**：如果通过 Google Cloud Console 网页点击“Test Job / Start Job”，控制台会自动先执行目标集群降级；若通过 `gcloud` CLI 操作，**必须先显式执行 `demote-destination`** 将新建的空目标主集群切换为外部复制接收状态，再运行 `verify` 预检：

```bash
# 1. 将目标空集群切换为 DMS 外部副本接收状态（耗时约 15 秒）
gcloud database-migration migration-jobs demote-destination "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}"

# 等待返回的 operation 完成后，执行端到端连通性、插件与权限预检（耗时约 30~45 秒）
gcloud database-migration migration-jobs verify "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}"
```

可通过以下命令确认异步操作完成且无 `error` 字段：
```bash
gcloud database-migration operations describe <OPERATION_ID> \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}"
```

### 6.5 启动正式迁移

```bash
gcloud database-migration migration-jobs start "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}"
```

---

## 七、阶段 6：全量与 CDC 增量监控、数据一致性对账

### 7.1 观察迁移阶段从 `FULL_DUMP` 进入 `CDC`

```bash
gcloud database-migration migration-jobs describe "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --format="table(name.basename(), state, phase, duration)"
```

- `phase: FULL_DUMP`：正在并发导出源库 Schema 与历史存量全量数据。
- `state: RUNNING` 且 `phase: CDC`：历史全量已导入完毕，正在通过逻辑复制槽实时追平增量 WAL 变更！

### 7.2 在源库查看实时复制流与延迟（LSN 对账）

连接源端 AlloyDB 执行以下 SQL，您会直观看到 `client_addr` 正是源端 `Network Attachment` 分配给目标端 AlloyDB 的 PSC Interface 本地 IP（例如 `10.10.2.2`）：

```sql
SELECT
    application_name,
    usename,
    client_addr,
    state,
    sent_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replication_lag_bytes
FROM pg_stat_replication
WHERE usename = 'dms_migrator';
```

当 `replication_lag_bytes` 趋近于 `0` 时，说明目标端与源端已处于准实时同步状态。

### 7.3 执行跨库数据行数、金额汇总与整表 MD5 指纹对账

在迁移过程中，目标端 AlloyDB 支持只读查询。您可以在业务低峰期分别对源库与目标库运行对账 SQL（参考仓库中的 `scripts/06-verify-checksums.sql`），逐表比对 `COUNT(*)`、关键数值列 `SUM()` 以及基于主键排序聚合的 `MD5` 摘要。

> **关于序列（Sequence）值的正常现象说明**：在 `CDC` 阶段以及 `promote` 完成后，您查询目标库的自增序列 `last_value` 时，会发现目标库的 `last_value` 比源库大 **`1000`**（例如源库订单序列为 `10250`，目标库同步为 `11250`）。这是 DMS / `pglogical` 为防止割接瞬间高并发自增主键冲突而自动预留的安全缓冲步长（`+1000`），属于正常的保护机制！

---

## 八、阶段 7：业务停写追平、正式割接（Promote）与收尾

当您完成目标端业务联调并进入计划割接窗口后，按以下步骤执行分钟级切流：

### 8.1 暂停源库业务写入并确认零延迟

1. 将业务应用置为短暂维护/只读模式，或停止向源端 AlloyDB 写入新事务。
2. 在源端 AlloyDB 执行第 `7.2` 节的 `pg_stat_replication` 查询，确认所有 `dms_migrator` 复制流的 `sent_lsn = replay_lsn`（`replication_lag_bytes = 0`），并在 DMS 控制台确认 **Replication Delay = 0 秒**。

### 8.2 执行一键割接提升（Promote）

```bash
gcloud database-migration migration-jobs promote "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}"
```

*耗时参考*：Promote 操作会自动完成最终序列值同步、断开逻辑复制订阅并将目标端 AlloyDB 集群恢复为独立的 `PRIMARY` 主集群，实测耗时约 **60 ~ 90 秒**。

### 8.3 验证目标端读写能力与切换业务流量

1. 检查迁移作业状态变为 `COMPLETED`，且目标集群 `clusterType` 为 `PRIMARY`、`state` 为 `READY`。
2. 连接目标端 PSC Endpoint 执行 `SELECT pg_is_in_recovery();`（应返回 `f`，代表可正常读写），并验证插入一条测试记录及自增序列生成正常。
3. 在目标库核对自定义业务账号与权限已就绪，将应用系统的数据库连接串指向目标项目的 PSC Endpoint（或 AlloyDB Auth Proxy），恢复业务对外服务！

### 8.4 割接稳定后的清理收尾工作

待业务在新项目稳定运行度过回滚观察期后：
1. 可删除目标项目的 DMS 迁移作业与连接配置。
2. 如需彻底清理源库历史测试对象，可按依赖顺序删除源端测试资源（PoC 环境可运行 `./scripts/99-cleanup.sh`）。**注意**：若要删除源项目中的 `Network Attachment`，必须先删除目标端实例或解除目标端实例上的 `--psc-network-attachment-uri` 绑定，否则 Compute Engine 会因挂载点仍在使用中而拒绝删除。

---

## 九、常见问题与排障指南（Troubleshooting FAQ）

### Q1：设置源端 AlloyDB 参数时报错 `value 20 for flag "max_replication_slots" is invalid, minimum allowed value is 50`？
- **原因**：AlloyDB 为保障系统高可用与内部复制组件运行，规定 `max_replication_slots` 和 `max_wal_senders` 的最小合法值为 `50`。
- **解决**：将两个参数均设置为 `>= 50` 的整数（如 `60`）。

### Q2：创建目标端 AlloyDB 实例后，源端 Network Attachment 中连接状态显示 `REJECTED` 或 `PENDING`？
- **原因**：在 `ACCEPT_MANUAL` 模式下，`--producer-accept-list` 误填了用户自己的 `<DEST_PROJECT_ID>`，而没有填写目标 AlloyDB 集群的后台托管租户项目编号 `pscConfig.serviceOwnedProjectNumber`。
- **解决**：运行 `gcloud alloydb clusters describe <DST_CLUSTER_ID> --project=<DEST_PROJECT_ID> --region=<REGION> --format="value(pscConfig.serviceOwnedProjectNumber)"` 获取项目编号，并通过 `gcloud compute network-attachments update` 将该编号加入 `--producer-accept-list`。

### Q3：使用 `gcloud database-migration migration-jobs verify` 时报错 `FAILED_PRECONDITION: Destination has to be demoted in order to be able to start/verify the migration`？
- **原因**：当目标端是预先创建好的 AlloyDB 集群时，命令行不会像网页控制台那样自动帮您做前置降级。
- **解决**：先运行 `gcloud database-migration migration-jobs demote-destination <JOB_ID> --region=<REGION> --project=<DEST_PROJECT_ID>`，等待其异步操作完成后再运行 `verify` 和 `start`。

### Q4：`verify` 预检超时或报无法连接源端私网 IP（`Connection timed out`）？
- **排查清单**：
  1. 检查源端 VPC 防火墙是否放行了 **Network Attachment 所属子网 CIDR** 访问源端 PSA 地址段的 `TCP 5432` 入站流量。
  2. 检查目标端 AlloyDB 主实例是否已正确传入 `--psc-network-attachment-uri`。
  3. 检查源端、Network Attachment、目标端 AlloyDB 与 DMS 迁移作业是否严格位于**同一个 GCP Region**。

### Q5：删除源项目的 Network Attachment 时报错 `The network_attachment resource is already being used`？
- **原因**：目标项目的 AlloyDB 实例仍然挂载着该跨项目 Network Attachment。
- **解决**：在销毁 PoC 环境时，必须**先删除目标端 AlloyDB 实例/集群**（或更新目标端实例移除 Network Attachment 配置），待引用释放后再删除源项目的 Network Attachment 与子网。
