#!/usr/bin/env bash
# ==============================================================================
# Step 1: 在源项目创建或配置 PSA VPC 网络、PSC 接口专用子网及源端 AlloyDB 集群
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.example.sh
source "${SCRIPT_DIR}/env.example.sh"

echo "[1/5] 创建源端自定义模式 VPC 与子网 (${SOURCE_PROJECT_ID})..."
if ! gcloud compute networks describe "${SRC_VPC_NAME}" --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud compute networks create "${SRC_VPC_NAME}" \
    --project="${SOURCE_PROJECT_ID}" \
    --subnet-mode=custom \
    --bgp-routing-mode=regional \
    --quiet
fi

if ! gcloud compute networks subnets describe "${SRC_WORKLOAD_SUBNET}" --region="${REGION}" --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud compute networks subnets create "${SRC_WORKLOAD_SUBNET}" \
    --project="${SOURCE_PROJECT_ID}" \
    --network="${SRC_VPC_NAME}" \
    --region="${REGION}" \
    --range="${SRC_WORKLOAD_CIDR}" \
    --enable-private-ip-google-access \
    --quiet
fi

# 为 Network Attachment 创建独立的 RFC 1918 子网，便于精细化防火墙控制与流日志审计
if ! gcloud compute networks subnets describe "${SRC_PSC_NAT_SUBNET}" --region="${REGION}" --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud compute networks subnets create "${SRC_PSC_NAT_SUBNET}" \
    --project="${SOURCE_PROJECT_ID}" \
    --network="${SRC_VPC_NAME}" \
    --region="${REGION}" \
    --range="${SRC_PSC_NAT_CIDR}" \
    --enable-private-ip-google-access \
    --quiet
fi

echo "[2/5] 配置源端 VPC 的 Private Services Access (PSA) 地址段与服务对等连接..."
if ! gcloud compute addresses describe "${SRC_PSA_RANGE_NAME}" --global --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud compute addresses create "${SRC_PSA_RANGE_NAME}" \
    --project="${SOURCE_PROJECT_ID}" \
    --global \
    --addresses="${SRC_PSA_BASE_IP}" \
    --prefix-length="${SRC_PSA_PREFIX_LEN}" \
    --purpose=VPC_PEERING \
    --network="${SRC_VPC_NAME}" \
    --quiet
fi

gcloud services vpc-peerings connect \
  --project="${SOURCE_PROJECT_ID}" \
  --service=servicenetworking.googleapis.com \
  --ranges="${SRC_PSA_RANGE_NAME}" \
  --network="${SRC_VPC_NAME}" \
  --quiet

echo "[3/5] 配置源端 VPC 内部数据库访问与 IAP SSH 防火墙规则..."
if ! gcloud compute firewall-rules describe "${SRC_VPC_NAME}-allow-pg" --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud compute firewall-rules create "${SRC_VPC_NAME}-allow-pg" \
    --project="${SOURCE_PROJECT_ID}" \
    --network="${SRC_VPC_NAME}" \
    --direction=INGRESS \
    --allow=tcp:5432,icmp \
    --source-ranges="${SRC_WORKLOAD_CIDR},${SRC_PSC_NAT_CIDR},${SRC_PSA_BASE_IP}/${SRC_PSA_PREFIX_LEN}" \
    --quiet
fi

if ! gcloud compute firewall-rules describe "${SRC_VPC_NAME}-allow-iap" --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud compute firewall-rules create "${SRC_VPC_NAME}-allow-iap" \
    --project="${SOURCE_PROJECT_ID}" \
    --network="${SRC_VPC_NAME}" \
    --direction=INGRESS \
    --allow=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --quiet
fi

echo "[4/5] 创建源端 PSA AlloyDB 集群 (${SRC_CLUSTER_ID})..."
if ! gcloud alloydb clusters describe "${SRC_CLUSTER_ID}" --region="${REGION}" --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud alloydb clusters create "${SRC_CLUSTER_ID}" \
    --project="${SOURCE_PROJECT_ID}" \
    --region="${REGION}" \
    --password="${SRC_POSTGRES_PASSWORD}" \
    --database-version="${DB_VERSION}" \
    --network="${SRC_VPC_NAME}" \
    --allocated-ip-range-name="${SRC_PSA_RANGE_NAME}" \
    --quiet
fi

echo "[5/5] 创建源端 AlloyDB 主实例 (${SRC_INSTANCE_ID}) 并开启 pglogical 逻辑复制参数..."
# 注意: AlloyDB 中 max_replication_slots 和 max_wal_senders 最小允许值为 50，切勿照搬标准 PG 设为 <50 的数值
if ! gcloud alloydb instances describe "${SRC_INSTANCE_ID}" --cluster="${SRC_CLUSTER_ID}" --region="${REGION}" --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud alloydb instances create "${SRC_INSTANCE_ID}" \
    --project="${SOURCE_PROJECT_ID}" \
    --cluster="${SRC_CLUSTER_ID}" \
    --region="${REGION}" \
    --instance-type=PRIMARY \
    --availability-type=ZONAL \
    --cpu-count=2 \
    --database-flags=alloydb.logical_decoding=on,alloydb.enable_pglogical=on,wal_sender_timeout=0,max_replication_slots=60,max_wal_senders=60,max_worker_processes=64 \
    --quiet
fi

SRC_PRIVATE_IP="$(gcloud alloydb instances describe "${SRC_INSTANCE_ID}" \
  --cluster="${SRC_CLUSTER_ID}" \
  --region="${REGION}" \
  --project="${SOURCE_PROJECT_ID}" \
  --format='value(ipAddress)')"

echo "源端 AlloyDB 主实例已就绪，PSA 私网 IP: ${SRC_PRIVATE_IP}"
