#!/usr/bin/env bash
#
# build-ios.sh — 构建 iOS App 并通过 simctl 部署到模拟器
#
# 流程：
#   1. （可选）xcodegen 重新生成 Xcode 工程
#   2. xcodebuild 构建指定 scheme/configuration
#   3. simctl 安装到目标模拟器
#   4. （可选）安装后直接启动应用
#
# 用法：
#   ./scripts/build-ios.sh                          # Debug 构建并部署到模拟器
#   ./scripts/build-ios.sh --release                # Release 构建
#   ./scripts/build-ios.sh --no-deploy              # 只构建，不安装
#   ./scripts/build-ios.sh --open                   # 安装后自动启动应用
#   ./scripts/build-ios.sh --clean                  # 先 clean 再构建
#   ./scripts/build-ios.sh --generate               # 构建前先 xcodegen generate
#   ./scripts/build-ios.sh --simulator <UDID>       # 指定目标模拟器
#
# 环境变量：
#   SIM_UDID    目标模拟器 UDID（默认见下方 DEFAULT_SIM_UDID）
#   BUNDLE_ID   iOS bundle identifier（默认 com.chatput.ChatputPhone）
#   SCHEME      Xcode scheme（默认 ChatputPhone）

set -euo pipefail

# ---- 路径 ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IOS_DIR="$PROJECT_ROOT/mobile-iphone"

# ---- 默认参数 ------------------------------------------------------------
CONFIG="Debug"
DO_DEPLOY=1
DO_OPEN=0
DO_CLEAN=0
DO_GENERATE=0
SCHEME="${SCHEME:-ChatputPhone}"
BUNDLE_ID="${BUNDLE_ID:-com.chatput.ChatputPhone}"
DEFAULT_SIM_UDID="F75EA073-108A-49D5-8943-15431CCD97B1"
SIM_UDID="${SIM_UDID:-$DEFAULT_SIM_UDID}"

log()  { printf '\033[1;34m[ios]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ios]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ios]\033[0m %s\n' "$*" >&2; }

usage() {
  sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令：$1"
    exit 1
  }
}

# ---- 解析参数 ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --generate)
      DO_GENERATE=1
      shift
      ;;
    --simulator)
      SIM_UDID="${2:-}"
      shift 2
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

[[ -d "$IOS_DIR" ]] || {
  err "未找到 iOS 工程目录：$IOS_DIR"
  exit 1
}

need xcodebuild
need xcrun

cd "$IOS_DIR"

# ---- 生成工程（XcodeGen）-------------------------------------------------
PROJECT="$IOS_DIR/${SCHEME}.xcodeproj"
if [[ "$DO_GENERATE" == "1" || ! -d "$PROJECT" ]]; then
  need xcodegen
  log "xcodegen generate…"
  xcodegen generate
fi

[[ -d "$PROJECT" ]] || {
  err "未找到 Xcode 工程：${PROJECT}（可用 --generate 生成）"
  exit 1
}

# ---- 构建 ----------------------------------------------------------------
if [[ "$DO_CLEAN" == "1" ]]; then
  log "xcodebuild clean…"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" clean >/dev/null
fi

DESTINATION="platform=iOS Simulator,id=${SIM_UDID}"
log "xcodebuild（scheme=${SCHEME}，configuration=${CONFIG}）…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination "$DESTINATION" build

# 定位构建产物
APP_PATH="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination "$DESTINATION" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR /{tbd=$2} / FULL_PRODUCT_NAME /{fpn=$2} END{print tbd"/"fpn}')"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  err "未找到构建产物：$APP_PATH"
  exit 1
fi
log "构建完成：$APP_PATH"

# ---- 部署 ----------------------------------------------------------------
if [[ "$DO_DEPLOY" == "1" ]]; then
  log "启动模拟器 ${SIM_UDID}…"
  xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
  open -a Simulator 2>/dev/null || true

  log "simctl install…"
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$SIM_UDID" "$APP_PATH"
  log "已安装到模拟器"

  if [[ "$DO_OPEN" == "1" ]]; then
    log "启动应用…"
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null
  fi
else
  log "跳过部署（--no-deploy）"
fi

log "完成。"
