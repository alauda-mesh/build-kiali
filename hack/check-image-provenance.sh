#!/usr/bin/env bash

set -euo pipefail

readonly REQUIRED_SOURCE_LABEL="org.opencontainers.image.source"
readonly REQUIRED_REVISION_LABEL="org.opencontainers.image.revision"
readonly REQUIRED_REF_NAME_LABEL="org.opencontainers.image.ref.name"

TARGET_PLATFORM="${OCI_CHECK_PLATFORM:-linux/amd64}"
INSPECT_TOOL="${OCI_CHECK_TOOL:-auto}"
IMAGE_REF=""

usage() {
  cat <<'EOF'
检查镜像是否包含以下三项非空 OCI 标签：
  org.opencontainers.image.source
  org.opencontainers.image.revision
  org.opencontainers.image.ref.name

用法：
  hack/check-image-provenance.sh [选项] <镜像>

选项：
  --platform <OS/ARCH[/VARIANT]>  指定检查平台，默认 linux/amd64
  --tool <auto|skopeo|crane|docker>
                                指定检查工具，默认自动选择
  -h, --help                    显示帮助

环境变量：
  OCI_CHECK_PLATFORM            等同于 --platform
  OCI_CHECK_TOOL                等同于 --tool

示例：
  hack/check-image-provenance.sh build-harbor.alauda.cn/asm/kiali:v2.27.1-r0
  hack/check-image-provenance.sh --platform linux/arm64 --tool crane <镜像>

说明：
  - auto 模式依次选择 skopeo、crane（同时需要 jq）、docker。
  - 使用 docker 时会先拉取指定平台的镜像。
  - 私有仓库请先使用所选工具完成登录。
EOF
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

select_inspect_tool() {
  case "$INSPECT_TOOL" in
    auto)
      if command_exists skopeo; then
        INSPECT_TOOL="skopeo"
      elif command_exists crane && command_exists jq; then
        INSPECT_TOOL="crane"
      elif command_exists docker; then
        INSPECT_TOOL="docker"
      else
        die "未找到可用工具，请安装 skopeo、crane+jq 或 docker"
      fi
      ;;
    skopeo)
      command_exists skopeo || die "未找到 skopeo"
      ;;
    crane)
      command_exists crane || die "未找到 crane"
      command_exists jq || die "使用 crane 时还需要安装 jq"
      ;;
    docker)
      command_exists docker || die "未找到 docker"
      ;;
    *)
      die "不支持的检查工具：${INSPECT_TOOL}"
      ;;
  esac
}

inspect_with_skopeo() {
  local target_os="$1"
  local target_arch="$2"
  local target_variant="$3"
  local registry_image_ref="$4"
  local skopeo_args

  skopeo_args=(
    inspect
    --override-os "$target_os"
    --override-arch "$target_arch"
  )
  if [[ -n "$target_variant" ]]; then
    skopeo_args+=(--override-variant "$target_variant")
  fi

  skopeo "${skopeo_args[@]}" \
    --format '{{ index .Labels "org.opencontainers.image.source" }}|{{ index .Labels "org.opencontainers.image.revision" }}|{{ index .Labels "org.opencontainers.image.ref.name" }}' \
    "docker://${registry_image_ref}"
}

inspect_with_crane() {
  local registry_image_ref="$1"

  crane config --platform "$TARGET_PLATFORM" "$registry_image_ref" | jq -r '
    [
      (.config.Labels["org.opencontainers.image.source"] // ""),
      (.config.Labels["org.opencontainers.image.revision"] // ""),
      (.config.Labels["org.opencontainers.image.ref.name"] // "")
    ] | join("|")
  '
}

inspect_with_docker() {
  local registry_image_ref="$1"

  docker pull --platform "$TARGET_PLATFORM" "$registry_image_ref" >/dev/null
  docker image inspect \
    --format '{{ index .Config.Labels "org.opencontainers.image.source" }}|{{ index .Config.Labels "org.opencontainers.image.revision" }}|{{ index .Config.Labels "org.opencontainers.image.ref.name" }}' \
    "$registry_image_ref"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || die "--platform 缺少参数"
      TARGET_PLATFORM="$2"
      shift 2
      ;;
    --tool)
      [[ $# -ge 2 ]] || die "--tool 缺少参数"
      INSPECT_TOOL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "未知选项：$1"
      ;;
    *)
      [[ -z "$IMAGE_REF" ]] || die "只能检查一个镜像"
      IMAGE_REF="$1"
      shift
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  [[ -z "$IMAGE_REF" && $# -eq 1 ]] || die "只能检查一个镜像"
  IMAGE_REF="$1"
fi

[[ -n "$IMAGE_REF" ]] || {
  usage >&2
  exit 2
}

REGISTRY_IMAGE_REF="${IMAGE_REF#docker://}"

IFS='/' read -r TARGET_OS TARGET_ARCH TARGET_VARIANT EXTRA_PLATFORM_PART <<< "$TARGET_PLATFORM"
if [[ -z "$TARGET_OS" || -z "$TARGET_ARCH" || -n "${EXTRA_PLATFORM_PART:-}" ]]; then
  die "平台格式无效：${TARGET_PLATFORM}，应为 OS/ARCH[/VARIANT]"
fi

select_inspect_tool

printf '镜像：%s\n' "$REGISTRY_IMAGE_REF"
printf '平台：%s\n' "$TARGET_PLATFORM"
printf '工具：%s\n' "$INSPECT_TOOL"

case "$INSPECT_TOOL" in
  skopeo)
    if ! RAW_LABEL_VALUES=$(inspect_with_skopeo "$TARGET_OS" "$TARGET_ARCH" "${TARGET_VARIANT:-}" "$REGISTRY_IMAGE_REF"); then
      die "skopeo 无法检查镜像，请确认镜像地址、网络和登录状态"
    fi
    ;;
  crane)
    if ! RAW_LABEL_VALUES=$(inspect_with_crane "$REGISTRY_IMAGE_REF"); then
      die "crane 无法检查镜像，请确认镜像地址、网络和登录状态"
    fi
    ;;
  docker)
    if ! RAW_LABEL_VALUES=$(inspect_with_docker "$REGISTRY_IMAGE_REF"); then
      die "docker 无法检查镜像，请确认 Docker 服务、镜像地址、网络和登录状态"
    fi
    ;;
esac

IFS='|' read -r SOURCE_LABEL_VALUE REVISION_LABEL_VALUE REF_NAME_LABEL_VALUE <<< "$RAW_LABEL_VALUES"

LABEL_KEYS=(
  "$REQUIRED_SOURCE_LABEL"
  "$REQUIRED_REVISION_LABEL"
  "$REQUIRED_REF_NAME_LABEL"
)
LABEL_VALUES=(
  "${SOURCE_LABEL_VALUE:-}"
  "${REVISION_LABEL_VALUE:-}"
  "${REF_NAME_LABEL_VALUE:-}"
)

MISSING_COUNT=0
for LABEL_INDEX in 0 1 2; do
  LABEL_KEY="${LABEL_KEYS[$LABEL_INDEX]}"
  LABEL_VALUE="${LABEL_VALUES[$LABEL_INDEX]}"
  if [[ -z "$LABEL_VALUE" || "$LABEL_VALUE" == "<no value>" ]]; then
    printf '[缺失] %s\n' "$LABEL_KEY"
    MISSING_COUNT=$((MISSING_COUNT + 1))
  else
    printf '[存在] %s=%s\n' "$LABEL_KEY" "$LABEL_VALUE"
  fi
done

if [[ "$MISSING_COUNT" -gt 0 ]]; then
  printf '检查失败：镜像缺少 %d 项必需 OCI 标签。\n' "$MISSING_COUNT" >&2
  exit 1
fi

printf '检查通过：镜像包含全部三项 OCI 标签。\n'
