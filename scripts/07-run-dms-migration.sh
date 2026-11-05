#!/usr/bin/env bash
# ==============================================================================
# Step 7: 创建 DMS 连接配置、创建持续迁移作业、执行降级与预检并启动迁移
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.example.sh
source "${SCRIPT_DIR}/env.example.sh"

wait_dms_lro() {
  local op_name="$1"
  local op_label="$2"
  echo "等待 DMS 异步操作 [${op_label}] (${op_name}) 完成..."
  while true; do
    local done_flag
    done_flag="$(gcloud database-migration operations describe "${op_name}" \
      --project="${DEST_PROJECT_ID}" \
      --region="${REGION}" \
      --format='value(done)' \
      --quiet)"
    if [[ "${done_flag}" == "True" || "${done_flag}" == "true" ]]; then
      local err_msg
      err_msg="$(gcloud database-migration operations describe "${op_name}" \
        --project="${DEST_PROJECT_ID}" \
        --region="${REGION}" \
        --format='value(error.message)' \
        --quiet)"
      if [[ -n "${err_msg}" ]]; then
        echo "错误: DMS 操作 [${op_label}] 失败: ${err_msg}" >&2
        gcloud database-migration operations describe "${op_name}" \
          --project="${DEST_PROJECT_ID}" \
          --region="${REGION}" \
          --format=json \
          --quiet >&2
        return 1
      fi
      echo "DMS 操作 [${op_label}] 已成功完成。"
      break
    fi
    sleep 5
  done
}

SRC_PRIVATE_IP="$(gcloud alloydb instances describe "${SRC_INSTANCE_ID}" \
  --cluster="${SRC_CLUSTER_ID}" \
  --region="${REGION}" \
  --project="${SOURCE_PROJECT_ID}" \
  --format='value(ipAddress)' \
  --quiet)"

if [[ -z "${SRC_PRIVATE_IP}" ]]; then
  echo "错误: 未能查询到源端 AlloyDB 实例的 PSA 私网 IP。" >&2
  exit 1
fi

echo "[1/5] 在目标项目 (${DEST_PROJECT_ID}) 创建源端连接配置 (${DMS_SRC_PROFILE_ID} -> ${SRC_PRIVATE_IP}:5432)..."
if ! gcloud database-migration connection-profiles describe "${DMS_SRC_PROFILE_ID}" --region="${REGION}" --project="${DEST_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud database-migration connection-profiles create postgresql "${DMS_SRC_PROFILE_ID}" \
    --project="${DEST_PROJECT_ID}" \
    --region="${REGION}" \
    --role=SOURCE \
    --host="${SRC_PRIVATE_IP}" \
    --port=5432 \
    --username="${MIGRATOR_USER}" \
    --password="${MIGRATOR_PASSWORD}" \
    --display-name="Source AlloyDB PSA Connection Profile" \
    --no-async \
    --quiet
fi

echo "[2/5] 在目标项目 (${DEST_PROJECT_ID}) 创建指向已有 PSC AlloyDB 集群的目标端连接配置 (${DMS_DST_PROFILE_ID})..."
if ! gcloud database-migration connection-profiles describe "${DMS_DST_PROFILE_ID}" --region="${REGION}" --project="${DEST_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud database-migration connection-profiles create postgresql "${DMS_DST_PROFILE_ID}" \
    --project="${DEST_PROJECT_ID}" \
    --region="${REGION}" \
    --role=DESTINATION \
    --alloydb-cluster="${DST_CLUSTER_ID}" \
    --username=postgres \
    --password="${DST_POSTGRES_PASSWORD}" \
    --display-name="Destination AlloyDB PSC Connection Profile" \
    --no-async \
    --quiet
fi

echo "[3/5] 创建 DMS 持续迁移作业 (${DMS_MIGRATION_JOB_ID})..."
# 注意: 使用 PSC Interface 出站连接已有 PSC AlloyDB 集群时，无需传入 --peer-vpc 或 --static-ip
if ! gcloud database-migration migration-jobs describe "${DMS_MIGRATION_JOB_ID}" --region="${REGION}" --project="${DEST_PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud database-migration migration-jobs create "${DMS_MIGRATION_JOB_ID}" \
    --project="${DEST_PROJECT_ID}" \
    --region="${REGION}" \
    --display-name="Cross-Project AlloyDB PSA to PSC Migration" \
    --source="${DMS_SRC_PROFILE_ID}" \
    --destination="${DMS_DST_PROFILE_ID}" \
    --type=CONTINUOUS \
    --no-async \
    --quiet
fi

echo "[4/5] 将目标端已有 AlloyDB 集群切换为外部副本模式 (demote-destination) 并执行端到端预检 (verify)..."
DEMOTE_OP="$(gcloud database-migration migration-jobs demote-destination "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(name)' \
  --quiet)"
wait_dms_lro "${DEMOTE_OP}" "demote-destination"

VERIFY_OP="$(gcloud database-migration migration-jobs verify "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(name)' \
  --quiet)"
wait_dms_lro "${VERIFY_OP}" "verify"

echo "[5/5] 启动 DMS 持续迁移作业 (${DMS_MIGRATION_JOB_ID})..."
gcloud database-migration migration-jobs start "${DMS_MIGRATION_JOB_ID}" \
  --project="${DEST_PROJECT_ID}" \
  --region="${REGION}" \
  --quiet

echo "持续监控迁移作业阶段，等待全量快照 (FULL_DUMP) 进入实时增量复制 (CDC)..."
while true; do
  STATUS_LINE="$(gcloud database-migration migration-jobs describe "${DMS_MIGRATION_JOB_ID}" \
    --project="${DEST_PROJECT_ID}" \
    --region="${REGION}" \
    --format='value(state,phase)' \
    --quiet)"
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] 当前状态与阶段: ${STATUS_LINE}"
  if [[ "${STATUS_LINE}" == *"RUNNING"* && "${STATUS_LINE}" == *"CDC"* ]]; then
    echo "迁移作业已成功进入实时 CDC 增量同步阶段！择机停写追平后可执行:"
    echo "  gcloud database-migration migration-jobs promote ${DMS_MIGRATION_JOB_ID} --project=${DEST_PROJECT_ID} --region=${REGION}"
    break
  fi
  if [[ "${STATUS_LINE}" == *"FAILED"* ]]; then
    echo "错误: 迁移作业进入 FAILED 状态，请检查详情:" >&2
    gcloud database-migration migration-jobs describe "${DMS_MIGRATION_JOB_ID}" \
      --project="${DEST_PROJECT_ID}" \
      --region="${REGION}" \
      --format=json >&2
    exit 1
  fi
  sleep 10
done
