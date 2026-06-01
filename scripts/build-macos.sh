#!/usr/bin/env bash
#
# build-macos.sh — 构建 macOS 桌面应用并部署到 /Applications
#
# 流程：
#   1. （可选）xcodegen 重新生成 Xcode 工程
#   2. xcodebuild 编译 Debug/Release 产物（ad-hoc 签名，免开发者证书）
#   3. 将 .app 拷贝到 /Applications（覆盖旧版本）
#   4. （可选）拷贝后直接打开应用
#
# 用法：
#   ./scripts/build-macos.sh                 # Debug 构建并部署到 /Applications
#   ./scripts/build-macos.sh --release       # Release 构建
#   ./scripts/build-macos.sh --open          # 部署后自动打开
#   ./scripts/build-macos.sh --no-deploy     # 只构建，不拷贝到 /Applications
#   ./scripts/build-macos.sh --clean         # 删除 build/ 后再构建
#   ./scripts/build-macos.sh --no-generate   # 跳过 xcodegen generate
#
# 环境变量：
#   DEST_DIR=/Applications   部署目标目录（默认 /Applications）

set -euo pipefail

# ---- 路径 ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$PROJECT_ROOT/desktop-macos"

PROJECT="ChatputDesktop.xcodeproj"
SCHEME="ChatputDesktop"
# 产物名（PRODUCT_NAME=Chatput）与运行进程名
APP_NAME="Chatput.app"
PROC_NAME="Chatput"

# ---- 默认参数 ------------------------------------------------------------
CONFIG="Debug"
DO_GENERATE=1
DO_DEPLOY=1
DO_OPEN=0
DO_CLEAN=0
DEST_DIR="${DEST_DIR:-/Applications}"

# ---- 解析参数 ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)      CONFIG="Release" ;;
    --debug)        CONFIG="Debug" ;;
    --open)         DO_OPEN=1 ;;
    --no-deploy)    DO_DEPLOY=0 ;;
    --no-generate)  DO_GENERATE=0 ;;
    --clean)        DO_CLEAN=1 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "✗ 未知参数：$1（用 --help 查看用法）" >&2
      exit 1 ;;
  esac
  shift
done

# 让 xcodegen 等用户工具可用
export PATH="$HOME/.local/bin:$PATH"

cd "$MACOS_DIR"

# ---- 1. 生成工程 ---------------------------------------------------------
if [[ "$DO_GENERATE" == "1" ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    echo "• xcodegen generate…"
    xcodegen generate
  else
    echo "• 未找到 xcodegen，跳过工程生成（如有改动请先安装：brew install xcodegen）"
  fi
fi

# ---- 2. 清理 -------------------------------------------------------------
if [[ "$DO_CLEAN" == "1" ]]; then
  echo "• 清理 build/…"
  rm -rf build
fi

# ---- 3. 编译 -------------------------------------------------------------
# 优先使用持久自签名证书（让授权跨重建保留）；找不到则回退 ad-hoc 签名。
SIGN_CERT_NAME="${SIGN_CERT_NAME:-Chatput Code Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_CERT_NAME"; then
  echo "• xcodebuild（${CONFIG}，签名身份：「${SIGN_CERT_NAME}」）…"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="$SIGN_CERT_NAME" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    | (command -v xcpretty >/dev/null 2>&1 && xcpretty || cat)
else
  echo "• xcodebuild（${CONFIG}，ad-hoc 签名）…"
  echo "  提示：运行 ./scripts/setup-signing.sh 可创建持久签名，避免每次重建后辅助功能授权失效。"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | (command -v xcpretty >/dev/null 2>&1 && xcpretty || cat)
fi

APP_PATH="$MACOS_DIR/build/Build/Products/$CONFIG/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ 构建产物未找到：$APP_PATH" >&2
  exit 1
fi
echo "✓ 构建完成：$APP_PATH"

# ---- 4. 部署到 /Applications ---------------------------------------------
if [[ "$DO_DEPLOY" == "1" ]]; then
  DEST_APP="$DEST_DIR/$APP_NAME"
  echo "• 部署到 ${DEST_APP}…"

  # 若应用正在运行，先退出，避免拷贝失败
  if pgrep -x "$PROC_NAME" >/dev/null 2>&1; then
    echo "  → 检测到应用正在运行，先退出…"
    osascript -e "quit app \"$PROC_NAME\"" >/dev/null 2>&1 || true
    pkill -x "$PROC_NAME" 2>/dev/null || true
    sleep 1
  fi

  # 需要写权限：/Applications 通常可写；若不可写则用 sudo
  if [[ -w "$DEST_DIR" ]]; then
    rm -rf "$DEST_APP"
    cp -R "$APP_PATH" "$DEST_APP"
  else
    echo "  → $DEST_DIR 不可写，使用 sudo…"
    sudo rm -rf "$DEST_APP"
    sudo cp -R "$APP_PATH" "$DEST_APP"
  fi

  # 移除隔离属性，避免首次启动被 Gatekeeper 拦截
  xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

  echo "✓ 已部署到 $DEST_APP"

  if [[ "$DO_OPEN" == "1" ]]; then
    echo "• 启动应用…"
    open "$DEST_APP"
  fi
else
  echo "• 跳过部署（--no-deploy）"
fi

echo "✓ 完成。"
