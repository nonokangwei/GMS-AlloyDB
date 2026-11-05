#!/usr/bin/env bash
# ==============================================================================
# Step 99 (可选 PoC 清理): 按严格依赖顺序清理跨项目迁移验证环境中的所有测试云资源
# 重要提示: 必须先删除或解绑目标端 AlloyDB 实例的 psc-network-attachment-uri，
#           之后才能删除源项目中的 Network Attachment！
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.example.sh
source "${SCRIPT_DIR}/env.example.sh"

read -r -p "警告: 即将删除源项目 (${SOURCE_PROJECT_ID}) 与目标项目 (${DEST_PROJECT_ID}) 中创建的 PoC 验证资源，确认继续请输入 YES: " CONFIRM
if [[ "${CONFIRM}" != "YES" ]]; then
  echo "已取消清理操作。"
  exit 0
fi

echo "[1/4] 删除目标项目 (${DEST_PROJECT_ID}) 中的 DMS 迁移作业与连接配置..."
gcloud database-migration migration-jobs delete "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" --region="${REGION}" --quiet 2>/dev/null || true
gcloud database-migration connection-profiles delete "${DMS_SRC_PROFILE_ID}" \
  --project="${DEST_PROJECT_ID}" --region="${REGION}" --force --quiet 2>/dev/null || true
gcloud database-migration connection-profiles delete "${DMS_DST_PROFILE_ID}" \
  --project="${DEST_PROJECT_ID}" --region="${REGION}" --force --quiet 2>/dev/null || true

echo "[2/4] 删除目标项目 (${DEST_PROJECT_ID}) 中的 AlloyDB 集群 (--force 会一并删除实例并释放跨项目 Network Attachment 占用)..."
gcloud alloydb clusters delete "${DST_CLUSTER_ID}" \
  --project="${DEST_PROJECT_ID}" --region="${REGION}" --force --quiet 2>/dev/null || true

echo "[3/4] 删除源项目 (${SOURCE_PROJECT_ID}) 中的 AlloyDB 集群与 Network Attachment..."
gcloud alloydb clusters delete "${SRC_CLUSTER_ID}" \
  --project="${SOURCE_PROJECT_ID}" --region="${REGION}" --force --quiet 2>/dev/null || true
gcloud compute network-attachments delete "${SRC_NETWORK_ATTACHMENT}" \
  --project="${SOURCE_PROJECT_ID}" --region="${REGION}" --quiet 2>/dev/null || true

echo "[4/4] 删除测试子网、防火墙、PSC Endpoint 及隔离测试 VPC（如为新建测试网络）..."
gcloud compute forwarding-rules delete "${DST_PSC_ENDPOINT_NAME}" \
  --project="${DEST_PROJECT_ID}" --region="${REGION}" --quiet 2>/dev/null || true
gcloud compute addresses delete "${DST_PSC_IP_NAME}" \
  --project="${DEST_PROJECT_ID}" --region="${REGION}" --quiet 2>/dev/null || true
gcloud compute firewall-rules delete "${DST_VPC_NAME}-allow-iap" \
  --project="${DEST_PROJECT_ID}" --quiet 2>/dev/null || true
gcloud compute networks subnets delete "${DST_SUBNET_NAME}" \
  --project="${DEST_PROJECT_ID}" --region="${REGION}" --quiet 2>/dev/null || true
gcloud compute networks delete "${DST_VPC_NAME}" \
  --project="${DEST_PROJECT_ID}" --quiet 2>/dev/null || true

gcloud compute firewall-rules delete "${SRC_VPC_NAME}-allow-pg" "${SRC_VPC_NAME}-allow-iap" \
  --project="${SOURCE_PROJECT_ID}" --quiet 2>/dev/null || true
gcloud services vpc-peerings delete \
  --project="${SOURCE_PROJECT_ID}" --service=servicenetworking.googleapis.com --network="${SRC_VPC_NAME}" --quiet 2>/dev/null || true
gcloud compute addresses delete "${SRC_PSA_RANGE_NAME}" \
  --project="${SOURCE_PROJECT_ID}" --global --quiet 2>/dev/null || true
gcloud compute networks subnets delete "${SRC_PSC_NAT_SUBNET}" "${SRC_WORKLOAD_SUBNET}" \
  --project="${SOURCE_PROJECT_ID}" --region="${REGION}" --quiet 2>/dev/null || true
gcloud compute networks delete "${SRC_VPC_NAME}" \
  --project="${SOURCE_PROJECT_ID}" --quiet 2>/dev/null || true

echo "所有 PoC 测试资源清理完毕。"
