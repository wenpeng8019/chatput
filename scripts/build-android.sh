#!/usr/bin/env bash
#
# build-android.sh — 构建 Android App 并通过 adb 部署到设备
#
# 流程：
#   1. 根据 variant/configuration 选择 Gradle 构建任务
#   2. 执行 assemble 生成 APK
#   3. 通过 adb install -r 覆盖安装到当前连接设备
#   4. （可选）安装后直接启动应用
#
# 用法：
#   ./scripts/build-android.sh                         # standard Debug 构建并部署
#   ./scripts/build-android.sh --variant english      # english Debug 构建并部署
#   ./scripts/build-android.sh --english              # english Debug 构建并部署
#   ./scripts/build-android.sh --release              # Release 构建
#   ./scripts/build-android.sh --no-deploy            # 只构建，不安装
#   ./scripts/build-android.sh --open                 # 安装后自动启动应用
#   ./scripts/build-android.sh --clean                # 先 clean 再构建
#
# 环境变量：
#   APP_ID=com.chatput.app   Android applicationId（默认 com.chatput.app）

set -euo pipefail

# ---- 路径 ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$PROJECT_ROOT/mobile-android"

# ---- 默认参数 ------------------------------------------------------------
VARIANT="standard"
CONFIG="Debug"
DO_DEPLOY=1
DO_OPEN=0
DO_CLEAN=0
APP_ID="${APP_ID:-com.chatput.app}"

log()  { printf '\033[1;34m[android]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[android]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[android]\033[0m %s\n' "$*" >&2; }

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令：$1"
    exit 1
  }
}

capitalize() {
  local value="$1"
  printf '%s%s' "$(printf '%s' "$value" | cut -c1 | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$value" | cut -c2-)"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# ---- 解析参数 ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      VARIANT="${2:-}"
      shift 2
      ;;
    --english)
      VARIANT="english"
      shift
      ;;
    --standard)
      VARIANT="standard"
      shift
      ;;
    --release)
      CONFIG="Release"
      shift
      ;;
    --debug)
      CONFIG="Debug"
      shift
      ;;
    --no-deploy)
      DO_DEPLOY=0
      shift
      ;;
    --open)
      DO_OPEN=1
      shift
      ;;
    --clean)
      DO_CLEAN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "未知参数：$1（用 --help 查看用法）"
      exit 1
      ;;
  esac
done

case "$VARIANT" in
  standard|english) ;;
  *)
    err "不支持的 variant：$VARIANT（可选 standard|english）"
    exit 1
    ;;
esac

[[ -d "$ANDROID_DIR" ]] || {
  err "未找到 Android 工程目录：$ANDROID_DIR"
  exit 1
}

need adb

cd "$ANDROID_DIR"

if [[ "$DO_CLEAN" == "1" ]]; then
  log "./gradlew clean…"
  ./gradlew clean
fi

VARIANT_CAP="$(capitalize "$VARIANT")"
CONFIG_LOWER="$(lowercase "$CONFIG")"
TASK="assemble${VARIANT_CAP}${CONFIG}"
APK_PATH="$ANDROID_DIR/app/build/outputs/apk/${VARIANT}/${CONFIG_LOWER}/app-${VARIANT}-${CONFIG_LOWER}.apk"

log "Gradle 任务：$TASK"
./gradlew ":app:${TASK}"

if [[ ! -f "$APK_PATH" ]]; then
  err "未找到构建产物：$APK_PATH"
  exit 1
fi
log "构建完成：$APK_PATH"

if [[ "$DO_DEPLOY" == "1" ]]; then
  if ! adb get-state >/dev/null 2>&1; then
    err "未检测到可用 adb 设备；如只需构建可使用 --no-deploy"
    exit 1
  fi

  log "adb install -r…"
  adb install -r "$APK_PATH"
  log "已安装到设备"

  if [[ "$DO_OPEN" == "1" ]]; then
    log "启动应用…"
    adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null
  fi
else
  log "跳过部署（--no-deploy）"
fi

log "完成。"