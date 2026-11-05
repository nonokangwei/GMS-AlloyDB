#!/usr/bin/env bash
# ==============================================================================
# 跨项目 AlloyDB (PSA -> PSC) DMS 迁移配置模板与参数校验器
# 使用方式: source ./scripts/env.example.sh
# ==============================================================================

set -euo pipefail

prompt_if_unset() {
  local var_name="$1"
  local prompt_desc="$2"
  local default_val="${3:-}"
  local is_secret="${4:-false}"
  local current_val="${!var_name:-}"

  if [[ -z "${current_val}" || "${current_val}" == \<*\> ]]; then
    if [[ "${is_secret}" == "true" ]]; then
      read -r -s -p "请输入 ${prompt_desc}: " input_val
      echo ""
    elif [[ -n "${default_val}" ]]; then
      read -r -p "请输入 ${prompt_desc} [默认: ${default_val}]: " input_val
      input_val="${input_val:-${default_val}}"
    else
      read -r -p "请输入 ${prompt_desc}: " input_val
    fi

    if [[ -z "${input_val}" || "${input_val}" == \<*\> ]]; then
      echo "错误: 参数 ${var_name} 不能为空或保留占位符。" >&2
      return 1
    fi
    export "${var_name}=${input_val}"
  fi
}

# 1. 核心项目与区域参数（必须位于同一 Region）
export SOURCE_PROJECT_ID="${SOURCE_PROJECT_ID:-<SOURCE_PROJECT_ID>}"
export DEST_PROJECT_ID="${DEST_PROJECT_ID:-<DEST_PROJECT_ID>}"
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-${REGION}-a}"
export DB_VERSION="${DB_VERSION:-POSTGRES_16}"

# 2. 源端网络与 PSA AlloyDB 资源名称
export SRC_VPC_NAME="${SRC_VPC_NAME:-dms-mig-src-vpc}"
export SRC_WORKLOAD_SUBNET="${SRC_WORKLOAD_SUBNET:-dms-mig-src-subnet}"
export SRC_WORKLOAD_CIDR="${SRC_WORKLOAD_CIDR:-10.10.1.0/24}"
export SRC_PSC_NAT_SUBNET="${SRC_PSC_NAT_SUBNET:-dms-mig-psc-nat-subnet}"
export SRC_PSC_NAT_CIDR="${SRC_PSC_NAT_CIDR:-10.10.2.0/24}"
export SRC_PSA_RANGE_NAME="${SRC_PSA_RANGE_NAME:-dms-mig-psa-range}"
export SRC_PSA_BASE_IP="${SRC_PSA_BASE_IP:-10.11.0.0}"
export SRC_PSA_PREFIX_LEN="${SRC_PSA_PREFIX_LEN:-16}"
export SRC_NETWORK_ATTACHMENT="${SRC_NETWORK_ATTACHMENT:-dms-src-net-attachment}"
export SRC_CLUSTER_ID="${SRC_CLUSTER_ID:-src-alloydb-psa}"
export SRC_INSTANCE_ID="${SRC_INSTANCE_ID:-src-alloydb-psa-primary}"

# 3. 目标端 PSC AlloyDB 与 DMS 资源名称
export DST_VPC_NAME="${DST_VPC_NAME:-dms-mig-dst-vpc}"
export DST_SUBNET_NAME="${DST_SUBNET_NAME:-dms-mig-dst-subnet}"
export DST_SUBNET_CIDR="${DST_SUBNET_CIDR:-10.20.1.0/24}"
export DST_PSC_IP_NAME="${DST_PSC_IP_NAME:-dms-dst-psc-ip}"
export DST_PSC_ENDPOINT_NAME="${DST_PSC_ENDPOINT_NAME:-dms-dst-psc-ep}"
export DST_CLUSTER_ID="${DST_CLUSTER_ID:-dst-alloydb-psc}"
export DST_INSTANCE_ID="${DST_INSTANCE_ID:-dst-alloydb-psc-primary}"

export DMS_SRC_PROFILE_ID="${DMS_SRC_PROFILE_ID:-src-alloydb-cp}"
export DMS_DST_PROFILE_ID="${DMS_DST_PROFILE_ID:-dst-alloydb-cp}"
export DMS_MIGRATION_JOB_ID="${DMS_MIGRATION_JOB_ID:-alloydb-cross-proj-mj}"
export MIGRATOR_USER="${MIGRATOR_USER:-dms_migrator}"

# 交互式提示用户输入必填项与密码
prompt_if_unset SOURCE_PROJECT_ID "源端 AlloyDB 所在的 GCP 项目 ID (例如 project-source-a)"
prompt_if_unset DEST_PROJECT_ID "目标端 AlloyDB 与 DMS 所在的 GCP 项目 ID (例如 project-dest-b)"
prompt_if_unset REGION "部署与迁移所在的 GCP 区域 (源与目标须同区域)" "us-central1"
prompt_if_unset SRC_POSTGRES_PASSWORD "源端 AlloyDB postgres 管理员密码" "" "true"
prompt_if_unset DST_POSTGRES_PASSWORD "目标端 AlloyDB postgres 管理员密码" "" "true"
prompt_if_unset MIGRATOR_PASSWORD "源端专用迁移账号 (${MIGRATOR_USER}) 密码" "" "true"

echo "环境变量校验通过: SOURCE_PROJECT_ID=${SOURCE_PROJECT_ID}, DEST_PROJECT_ID=${DEST_PROJECT_ID}, REGION=${REGION}"
