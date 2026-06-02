#!/usr/bin/env bash
#
# deploy-signaling.sh — 远程部署 Chatput signaling-server 到云主机
#
# 功能：
#   1. 通过 ssh 将 signaling-server/ 上传到远端目录（排除 node_modules）
#   2. 远端自动安装 Node.js（支持 dnf/yum/apt-get）
#   3. 执行 npm install --omit=dev
#   4. 生成并启动 systemd 服务
#   5. （可选）尝试打开云主机本机防火墙端口
#
# 用法：
#   ./scripts/deploy-signaling.sh --host 47.243.170.171
#   ./scripts/deploy-signaling.sh --host 47.243.170.171 --user root --port 8080
#   ./scripts/deploy-signaling.sh --host 47.243.170.171 --app-dir /opt/chatput-signaling
#   ./scripts/deploy-signaling.sh --host 47.243.170.171 --ssh-key ~/.ssh/id_rsa
#   ./scripts/deploy-signaling.sh --host 47.243.170.171 --no-install-node
#
# 说明：
#   - 默认部署到 /opt/chatput-signaling
#   - 默认 systemd 服务名：chatput-signaling
#   - 默认监听端口：8080
#   - 脚本不会帮你输入 SSH 密码；如需免交互，建议先配置密钥登录

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/signaling-server"

REMOTE_HOST=""
REMOTE_USER="root"
REMOTE_PORT="8080"
REMOTE_APP_DIR="/opt/chatput-signaling"
SERVICE_NAME="chatput-signaling"
SSH_KEY=""
SSH_PORT="22"
INSTALL_NODE=1
OPEN_FIREWALL=1

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; }

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令：$1"
    exit 1
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      REMOTE_HOST="${2:-}"
      shift 2
      ;;
    --user)
      REMOTE_USER="${2:-}"
      shift 2
      ;;
    --port)
      REMOTE_PORT="${2:-}"
      shift 2
      ;;
    --app-dir)
      REMOTE_APP_DIR="${2:-}"
      shift 2
      ;;
    --service-name)
      SERVICE_NAME="${2:-}"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="${2:-}"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="${2:-}"
      shift 2
      ;;
    --no-install-node)
      INSTALL_NODE=0
      shift
      ;;
    --no-open-firewall)
      OPEN_FIREWALL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "未知参数：$1"
      usage
      exit 1
      ;;
  esac
done

[[ -n "$REMOTE_HOST" ]] || {
  err "必须提供 --host"
  usage
  exit 1
}

[[ -d "$SOURCE_DIR" ]] || {
  err "未找到 signaling-server 源目录：$SOURCE_DIR"
  exit 1
}

need ssh
need tar

SSH_OPTS=(
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=accept-new
)

if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS+=( -i "$SSH_KEY" )
fi

REMOTE="$REMOTE_USER@$REMOTE_HOST"

log "部署目标：$REMOTE"
log "远端目录：$REMOTE_APP_DIR"
log "服务名：$SERVICE_NAME"
log "监听端口：$REMOTE_PORT"

log "上传 signaling-server 代码…"
tar \
  --exclude='node_modules' \
  --exclude='.DS_Store' \
  -C "$SOURCE_DIR" \
  -czf - . \
  | ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$REMOTE_APP_DIR' && tar -xzf - -C '$REMOTE_APP_DIR'"

log "在远端安装依赖并配置 systemd…"
ssh "${SSH_OPTS[@]}" "$REMOTE" \
  INSTALL_NODE="$INSTALL_NODE" \
  OPEN_FIREWALL="$OPEN_FIREWALL" \
  REMOTE_APP_DIR="$REMOTE_APP_DIR" \
  REMOTE_PORT="$REMOTE_PORT" \
  SERVICE_NAME="$SERVICE_NAME" \
  'bash -s' <<'EOF'
set -euo pipefail

if [[ "${INSTALL_NODE}" == "1" ]] && ! command -v node >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y nodejs npm
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nodejs npm
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y nodejs npm
  else
    echo "No supported package manager found for Node.js install" >&2
    exit 1
  fi
fi

command -v node >/dev/null 2>&1 || {
  echo "node not found on remote host" >&2
  exit 1
}
command -v npm >/dev/null 2>&1 || {
  echo "npm not found on remote host" >&2
  exit 1
}

cd "$REMOTE_APP_DIR"
npm install --omit=dev

cat >/etc/systemd/system/${SERVICE_NAME}.service <<SERVICE_EOF
[Unit]
Description=Chatput Signaling Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${REMOTE_APP_DIR}
Environment=PORT=${REMOTE_PORT}
ExecStart=$(command -v node) src/index.js
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

if [[ "${OPEN_FIREWALL}" == "1" ]]; then
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${REMOTE_PORT}/tcp" || true
    firewall-cmd --reload || true
  elif command -v ufw >/dev/null 2>&1; then
    ufw allow "${REMOTE_PORT}/tcp" || true
  fi
fi

ss -lntp | grep ":${REMOTE_PORT} " || true
systemctl --no-pager --full status "${SERVICE_NAME}.service" | sed -n "1,20p"
EOF

log "部署完成。建议验证："
log "  nc -vz ${REMOTE_HOST} ${REMOTE_PORT}"
log "  桌面端外部地址填：ws://${REMOTE_HOST}:${REMOTE_PORT}"