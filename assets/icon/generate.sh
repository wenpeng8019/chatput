#!/usr/bin/env bash
# Chatput 图标生成脚本
# 从 src/ 下的 SVG 生成 macOS (.icns / AppIcon.appiconset) 与 Android (mipmap / 自适应图标) 资源。
#
# 依赖：一个 SVG 渲染器（任选其一）
#   - rsvg-convert   →  brew install librsvg   （推荐）
#   - inkscape       →  brew install --cask inkscape
#   - cairosvg       →  pipx install cairosvg
# macOS 端打包 .icns 需要 iconutil（系统自带）。

set -euo pipefail

cd "$(dirname "$0")"
SRC="src"
OUT="build"
DESKTOP_SVG="$SRC/chatput-desktop.svg"
# macOS App 图标使用带透明边距的版本（苹果图标网格，圆角不顶到画布边缘）
DESKTOP_MACOS_SVG="$SRC/chatput-desktop-macos.svg"
MOBILE_SVG="$SRC/chatput-mobile.svg"
MOBILE_FG_SVG="$SRC/chatput-mobile-foreground.svg"

# 浅灰白（Android 自适应图标背景色，与桌面端背景一致）
BG_COLOR="#EEF1F5"

# ---- 选择渲染器 ----------------------------------------------------------
# 优先用自带的 Swift/AppKit 渲染器（保留透明通道，圆角四角真正透明）。
# qlmanage 会把透明区域填成白色，导致图标看起来是白方块，故不再优先使用。
SWIFT_RENDERER="$(cd "$(dirname "$0")" && pwd)/svg2png.swift"
RENDERER=""
if command -v rsvg-convert >/dev/null 2>&1; then
  RENDERER="rsvg"
elif command -v swift >/dev/null 2>&1 && [ -f "$SWIFT_RENDERER" ]; then
  RENDERER="swift"      # macOS 自带，保留透明
elif command -v inkscape >/dev/null 2>&1; then
  RENDERER="inkscape"
elif command -v cairosvg >/dev/null 2>&1; then
  RENDERER="cairosvg"
elif command -v qlmanage >/dev/null 2>&1; then
  RENDERER="qlmanage"   # 退路：注意会丢失透明通道（透明 → 白底）
else
  echo "✗ 未找到 SVG 渲染器。请安装其一：" >&2
  echo "    brew install librsvg            # rsvg-convert（推荐）" >&2
  echo "    brew install --cask inkscape    # inkscape" >&2
  echo "    pipx install cairosvg           # cairosvg" >&2
  exit 1
fi
echo "• 使用渲染器：$RENDERER"

# render <svg> <size> <out.png>
render() {
  local svg="$1" size="$2" out="$3"
  mkdir -p "$(dirname "$out")"
  case "$RENDERER" in
    rsvg)     rsvg-convert -w "$size" -h "$size" "$svg" -o "$out" ;;
    swift)    swift "$SWIFT_RENDERER" "$svg" "$size" "$out" ;;
    inkscape) inkscape "$svg" --export-type=png -w "$size" -h "$size" -o "$out" >/dev/null 2>&1 ;;
    cairosvg) cairosvg "$svg" -W "$size" -H "$size" -o "$out" ;;
    qlmanage)
      # qlmanage 输出 <basename>.png 到目录，渲染后重命名；仅适用于方形 SVG
      local tmp; tmp="$(mktemp -d)"
      qlmanage -t -s "$size" -o "$tmp" "$svg" >/dev/null 2>&1
      mv "$tmp/$(basename "$svg").png" "$out"
      rm -rf "$tmp"
      ;;
  esac
}

# ---- macOS ---------------------------------------------------------------
build_macos() {
  echo "• 生成 macOS 图标…"
  local set="$OUT/macos/AppIcon.appiconset"
  rm -rf "$set"; mkdir -p "$set"

  # (size, scale, filename)
  local specs=(
    "16 1 icon_16x16.png"      "16 2 icon_16x16@2x.png"
    "32 1 icon_32x32.png"      "32 2 icon_32x32@2x.png"
    "128 1 icon_128x128.png"   "128 2 icon_128x128@2x.png"
    "256 1 icon_256x256.png"   "256 2 icon_256x256@2x.png"
    "512 1 icon_512x512.png"   "512 2 icon_512x512@2x.png"
  )
  local entries=()
  local i=0
  while [ $i -lt ${#specs[@]} ]; do
    read -r base scale name <<<"${specs[$i]}"
    local px=$(( base * scale ))
    render "$DESKTOP_MACOS_SVG" "$px" "$set/$name"
    entries+=("    {\"size\":\"${base}x${base}\",\"idiom\":\"mac\",\"filename\":\"${name}\",\"scale\":\"${scale}x\"}")
    i=$(( i + 1 ))
  done

  { echo '{'; echo '  "images": ['
    local n=${#entries[@]} j=0
    for e in "${entries[@]}"; do
      if [ $j -lt $(( n - 1 )) ]; then echo "$e,"; else echo "$e"; fi
      j=$(( j + 1 ))
    done
    echo '  ],'
    echo '  "info": { "version": 1, "author": "xcode" }'
    echo '}'
  } > "$set/Contents.json"

  # 打包 .icns（需要 iconutil）
  if command -v iconutil >/dev/null 2>&1; then
    local iconset="$OUT/macos/ChatputDesktop.iconset"
    rm -rf "$iconset"; mkdir -p "$iconset"
    cp "$set/"icon_*.png "$iconset/"
    iconutil -c icns "$iconset" -o "$OUT/macos/ChatputDesktop.icns"
    rm -rf "$iconset"
    echo "  → $OUT/macos/ChatputDesktop.icns"
  fi
  echo "  → $set"
}

# ---- Android -------------------------------------------------------------
build_android() {
  echo "• 生成 Android 图标…"
  local root="$OUT/android"
  rm -rf "$root"

  # 传统启动图标（方形 + 圆形用同一张方图，系统按主题裁切）
  local densities=("mdpi 48" "hdpi 72" "xhdpi 96" "xxhdpi 144" "xxxhdpi 192")
  for d in "${densities[@]}"; do
    read -r name px <<<"$d"
    local dir="$root/mipmap-$name"
    render "$MOBILE_SVG" "$px" "$dir/ic_launcher.png"
    render "$MOBILE_SVG" "$px" "$dir/ic_launcher_round.png"
    # 自适应图标前景（108dp 画布）
    local fpx=$(( px * 108 / 48 ))
    render "$MOBILE_FG_SVG" "$fpx" "$dir/ic_launcher_foreground.png"
  done

  # 自适应图标 XML + 背景色
  mkdir -p "$root/mipmap-anydpi-v26" "$root/values"
  cat > "$root/mipmap-anydpi-v26/ic_launcher.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
XML
  cp "$root/mipmap-anydpi-v26/ic_launcher.xml" "$root/mipmap-anydpi-v26/ic_launcher_round.xml"
  cat > "$root/values/ic_launcher_background.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">$BG_COLOR</color>
</resources>
XML
  echo "  → $root  （把 mipmap-* 与 values/ 拷入 app/src/main/res/）"
}

build_macos
build_android
echo "✓ 完成。资源在 $OUT/ 下。"
