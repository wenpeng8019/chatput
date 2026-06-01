#!/usr/bin/env bash
#
# setup-signing.sh — 创建一个本地持久的自签名代码签名证书。
#
# 目的：用固定的签名身份给 app 签名，使其代码签名标识跨重建保持不变，
#       这样 macOS 的「辅助功能 / 隐私」授权（TCC）只需授权一次，
#       之后每次重新构建都不会失效。无需 Apple 开发者账号。
#
# 幂等：证书已存在则跳过；用 FORCE=1 强制重建。
#
# 用法：
#   ./scripts/setup-signing.sh
#
# 完成后用 build-macos.sh 构建即可自动使用该身份签名。

set -euo pipefail

CERT_NAME="${CERT_NAME:-Chatput Code Signing}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

# 已存在则跳过（除非 FORCE=1）
if [[ "${FORCE:-0}" != "1" ]] && security find-identity -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
  echo "✓ 签名身份已存在：「${CERT_NAME}」（用 FORCE=1 可强制重建）"
  exit 0
fi

echo "• 生成自签名代码签名证书：「${CERT_NAME}」…"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) 生成带 codeSigning 扩展用途的自签名证书与私钥（10 年有效）
openssl req -x509 -newkey rsa:2048 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes \
  -subj "/CN=$CERT_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

# 2) 打包成 PKCS#12（用临时口令 + legacy 算法，确保 macOS security 可导入）
#    该口令只保护随后立即删除的临时 .p12 文件，不是长期机密。
P12_PASS="chatput-temp"
openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12_PASS" \
  -name "$CERT_NAME"

# 3) 导入登录钥匙串，并授权 codesign 使用该私钥
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -A

# 3.5) 信任该证书用于代码签名（用户域，无需 sudo；可能弹一次登录验证）
security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$TMP/leaf.pem" 2>/dev/null || true
if [[ -s "$TMP/leaf.pem" ]]; then
  echo "• 信任证书用于代码签名（如弹窗请用密码 / Touch ID 确认）…"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/leaf.pem" >/dev/null 2>&1 \
    || echo "  → 信任设置未完成（不影响用该证书签名，仅影响 Gatekeeper 验证）。"
fi

# 4) 设置分区列表，避免 codesign 访问私钥时弹窗
#    需要登录钥匙串密码——请在终端直接输入（不会被记录）。
echo "• 设置钥匙串访问权限（如提示请输入登录钥匙串密码）…"
if ! security set-key-partition-list \
      -S apple-tool:,apple:,codesign: -s \
      -k "" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "  → 自动设置失败，首次签名时系统可能弹窗，点「始终允许」即可。"
fi

echo "✓ 完成。签名身份：「${CERT_NAME}」"
security find-identity -v -p codesigning | grep -F "$CERT_NAME" || true
