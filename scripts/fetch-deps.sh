#!/usr/bin/env bash
#
# fetch-deps.sh — 下载被 .gitignore 排除的大体积依赖
#
# 涵盖三项二进制依赖（克隆仓库后构建前需先运行本脚本）：
#   1. sherpa-onnx Android AAR      -> mobile-android/app/libs/sherpa-onnx.aar
#   2. SenseVoice 离线语音模型       -> mobile-android/app/src/main/assets/<model-dir>/model.int8.onnx
#   3. WebRTC 预编译 xcframework(M125) -> desktop-macos/Frameworks/WebRTC.xcframework
#
# 用法：
#   ./scripts/fetch-deps.sh            # 下载全部缺失依赖
#   ./scripts/fetch-deps.sh android    # 仅 Android 依赖（AAR + 模型）
#   ./scripts/fetch-deps.sh macos      # 仅 macOS 依赖（WebRTC）
#   USE_MIRROR=1 ./scripts/fetch-deps.sh   # 通过 ghfast.top 代理加速（中国大陆推荐）
#
# 幂等：已存在的文件会跳过；用 FORCE=1 强制重新下载。

set -euo pipefail

# ---- 可配置版本 ----
SHERPA_VERSION="${SHERPA_VERSION:-1.13.2}"
MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
WEBRTC_VERSION="${WEBRTC_VERSION:-125.0.0}"
WEBRTC_TAG="M125"

# ---- 路径 ----
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_LIBS="$ROOT/mobile-android/app/libs"
ANDROID_ASSETS="$ROOT/mobile-android/app/src/main/assets"
MACOS_FRAMEWORKS="$ROOT/desktop-macos/Frameworks"

# ---- 镜像代理 ----
MIRROR_PREFIX=""
if [[ "${USE_MIRROR:-0}" == "1" ]]; then
  MIRROR_PREFIX="https://ghfast.top/"
fi

mirror() { echo "${MIRROR_PREFIX}$1"; }

log()  { printf '\033[1;34m[deps]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deps]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[deps]\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { err "缺少命令：$1"; exit 1; }; }
need curl

# 下载到目标路径（含临时文件 + 原子移动）
download() {
  local url="$1" dest="$2"
  if [[ -e "$dest" && "${FORCE:-0}" != "1" ]]; then
    log "已存在，跳过：${dest#$ROOT/}"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  local tmp="$dest.part"
  log "下载 $(basename "$dest") ..."
  log "  <- $url"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
  mv "$tmp" "$dest"
  log "完成：${dest#$ROOT/}"
}

fetch_sherpa_aar() {
  local url
  url="$(mirror "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/sherpa-onnx-${SHERPA_VERSION}.aar")"
  download "$url" "$ANDROID_LIBS/sherpa-onnx.aar"
}

fetch_model() {
  local dest_dir="$ANDROID_ASSETS/$MODEL_NAME"
  local model="$dest_dir/model.int8.onnx"
  local tokens="$dest_dir/tokens.txt"
  if [[ -e "$model" && "${FORCE:-0}" != "1" ]]; then
    log "已存在，跳过：${model#$ROOT/}"
    return 0
  fi
  # SenseVoice 模型打包在 asr-models 的 tar.bz2 中，解包后取 int8 + tokens
  local archive_url
  archive_url="$(mirror "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2")"
  local tmp_tar
  tmp_tar="$(mktemp -t sherpa-model.XXXXXX.tar.bz2)"
  log "下载语音模型压缩包（~1GB，含 int8/fp32）..."
  log "  <- $archive_url"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp_tar" "$archive_url"
  mkdir -p "$dest_dir"
  log "解包并仅提取 model.int8.onnx + tokens.txt ..."
  # 只解出需要的两个文件，保持 APK 体积最小
  tar -xjf "$tmp_tar" -C "$ANDROID_ASSETS" \
      "$MODEL_NAME/model.int8.onnx" \
      "$MODEL_NAME/tokens.txt"
  rm -f "$tmp_tar"
  [[ -e "$model" ]] || { err "解包后未找到 $model"; exit 1; }
  log "完成：${model#$ROOT/}"
  log "完成：${tokens#$ROOT/}"
}

fetch_webrtc() {
  local dest="$MACOS_FRAMEWORKS/WebRTC.xcframework"
  if [[ -e "$dest" && "${FORCE:-0}" != "1" ]]; then
    log "已存在，跳过：${dest#$ROOT/}"
    return 0
  fi
  # 注意：必须用 M125（M147 的 release 缺子头文件，无法编译 ObjC module）
  local url
  url="$(mirror "https://github.com/stasel/WebRTC/releases/download/${WEBRTC_VERSION}/WebRTC-${WEBRTC_TAG}.xcframework.zip")"
  local tmp_zip
  tmp_zip="$(mktemp -t webrtc.XXXXXX.zip)"
  log "下载 WebRTC ${WEBRTC_TAG} xcframework ..."
  log "  <- $url"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp_zip" "$url"
  mkdir -p "$MACOS_FRAMEWORKS"
  log "解压 WebRTC.xcframework ..."
  rm -rf "$dest"
  unzip -q "$tmp_zip" -d "$MACOS_FRAMEWORKS"
  rm -f "$tmp_zip"
  [[ -e "$dest" ]] || { err "解压后未找到 $dest"; exit 1; }
  log "完成：${dest#$ROOT/}"
}

target="${1:-all}"
case "$target" in
  android) fetch_sherpa_aar; fetch_model ;;
  macos)   need unzip; fetch_webrtc ;;
  all)     fetch_sherpa_aar; fetch_model; need unzip; fetch_webrtc ;;
  *) err "未知目标：$target（可选 all|android|macos）"; exit 1 ;;
esac

log "全部依赖就绪。"
