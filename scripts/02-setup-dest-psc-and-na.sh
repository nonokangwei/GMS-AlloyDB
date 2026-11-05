#!/usr/bin/env bash
# ==============================================================================
# Step 2: 创建目标端 PSC AlloyDB 集群、源端跨项目 Network Attachment 及目标主实例
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.example.sh
source "${SCRIPT_DIR}/env.example.sh"

echo "[1/5] 在目标项目 (${DEST_PROJECT_ID}) 创建启用 PSC 的 AlloyDB 集群 (${DST_CLUSTER_ID})..."
if ! gcloud alloydb clusters describe "${DST_CLUSTER_ID}" --region="${REGION}" --project="${DEST_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud alloydb clusters create "${DST_CLUSTER_ID}" \
    --project="${DEST_PROJECT_ID}" \
    --region="${REGION}" \
    --password="${DST_POSTGRES_PASSWORD}" \
    --database-version="${DB_VERSION}" \
    --enable-private-service-connect \
    --quiet
fi

echo "[2/5] 提取目标集群专属的后台服务项目编号 (pscConfig.serviceOwnedProjectNumber)..."
SERVICE_OWNED_PROJECT_NUM="$(gcloud alloydb clusters describe "${DST_CLUSTER_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(pscConfig.serviceOwnedProjectNumber)')"

if [[ -z "${SERVICE_OWNED_PROJECT_NUM}" ]]; then
  echo "错误: 未能获取 pscConfig.serviceOwnedProjectNumber，请确认目标集群已开启 PSC。" >&2
  exit 1
fi
echo "获取到目标集群服务托管项目编号: ${SERVICE_OWNED_PROJECT_NUM}"

echo "[3/5] 在源项目 (${SOURCE_PROJECT_ID}) 创建最小权限 Network Attachment (${SRC_NETWORK_ATTACHMENT})..."
# 生产最佳实践: 使用 ACCEPT_MANUAL 并仅放行目标集群的 serviceOwnedProjectNumber（注意不是 DEST_PROJECT_ID 本身！）
if ! gcloud compute network-attachments describe "${SRC_NETWORK_ATTACHMENT}" --region="${REGION}" --project="${SOURCE_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud compute network-attachments create "${SRC_NETWORK_ATTACHMENT}" \
    --project="${SOURCE_PROJECT_ID}" \
    --region="${REGION}" \
    --subnets="${SRC_PSC_NAT_SUBNET}" \
    --connection-preference=ACCEPT_MANUAL \
    --producer-accept-list="${SERVICE_OWNED_PROJECT_NUM}" \
    --description="Cross-project PSC Interface Network Attachment for AlloyDB DMS migration" \
    --quiet
fi

NA_URI="projects/${SOURCE_PROJECT_ID}/regions/${REGION}/networkAttachments/${SRC_NETWORK_ATTACHMENT}"

echo "[4/5] 在目标项目 (${DEST_PROJECT_ID}) 创建 AlloyDB 主实例并绑定跨项目 Network Attachment..."
if ! gcloud alloydb instances describe "${DST_INSTANCE_ID}" --cluster="${DST_CLUSTER_ID}" --region="${REGION}" --project="${DEST_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud alloydb instances create "${DST_INSTANCE_ID}" \
    --project="${DEST_PROJECT_ID}" \
    --cluster="${DST_CLUSTER_ID}" \
    --region="${REGION}" \
    --instance-type=PRIMARY \
    --availability-type=ZONAL \
    --cpu-count=2 \
    --allowed-psc-projects="${DEST_PROJECT_ID}" \
    --psc-network-attachment-uri="${NA_URI}" \
    --database-flags=alloydb.enable_pglogical=on,alloydb.logical_decoding=on \
    --quiet
fi

echo "[5/5] 校验源项目 Network Attachment 的跨项目 PSC Interface 连接状态..."
gcloud compute network-attachments describe "${SRC_NETWORK_ATTACHMENT}" \
  --project="${SOURCE_PROJECT_ID}" \
  --region="${REGION}" \
  --format="json(name,connectionPreference,producerAcceptLists,connectionEndpoints)" \
  --quiet
