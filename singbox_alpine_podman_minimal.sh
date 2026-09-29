#!/bin/bash
set -Eeuo pipefail
umask 077

# Minimal sing-box installer for Alpine Linux in Podman/LXC-like containers.
# - Does NOT run apk add/update.
# - Does NOT require openssl or jq.
# - Installs the official sing-box musl binary directly from SagerNet GitHub releases.
# - Deploys VLESS + Reality only (TCP), suitable for low-resource containers.

SCRIPT_VERSION="1.0.0"
DEFAULT_SINGBOX_VERSION="1.14.1"
INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_PATH="${CONFIG_DIR}/config.json"
CLIENT_INFO="${CONFIG_DIR}/client-info.txt"
ROOT_INFO="/root/singbox-node.txt"
SERVICE_PATH="/etc/init.d/sing-box"
MANAGER_PATH="/usr/local/bin/sb"
WORKDIR="/root/.singbox-install.$$"

C_RESET='\033[0m'
C_BLUE='\033[1;34m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'

info() { printf "%b[INFO]%b %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf "%b[ OK ]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf "%b[ERR ]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

cleanup() {
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

[ "$(id -u)" = "0" ] || die "请使用 root 用户运行。"
[ -f /etc/alpine-release ] || die "这个脚本仅用于 Alpine Linux。"

for cmd in bash tar sed awk grep chmod cp mkdir rm cat head tr date; do
  command -v "$cmd" >/dev/null 2>&1 || die "系统缺少命令: $cmd"
done

if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  die "系统缺少 curl/wget，无法下载 sing-box。"
fi

download_file() {
  local url="$1" out="$2"
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fL --retry 3 --connect-timeout 15 -o "$out" "$url"
  else
    wget -O "$out" "$url"
  fi
}

download_stdout() {
  local url="$1"
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL --retry 2 --connect-timeout 8 "$url"
  else
    wget -qO- "$url"
  fi
}

prompt_value() {
  local __var="$1" __text="$2" __default="$3" __input=""
  if [ -n "${!__var:-}" ]; then
    return 0
  fi
  if [ -r /dev/tty ]; then
    printf "%s [%s]: " "$__text" "$__default" > /dev/tty
    IFS= read -r __input < /dev/tty || true
  fi
  printf -v "$__var" '%s' "${__input:-$__default}"
}

url_encode() {
  local LC_ALL=C s="$1" i c out="" hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%02X' "'$c"; out+="%$hex" ;;
    esac
  done
  printf '%s' "$out"
}

get_public_ip() {
  local ip=""
  for url in \
    https://api4.ipify.org \
    https://ipv4.icanhazip.com \
    https://ifconfig.me/ip; do
    ip="$(download_stdout "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$ip" in
      *.*.*.*) printf '%s' "$ip"; return 0 ;;
    esac
  done
  return 1
}

check_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

arch_detect() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    i386|i486|i586|i686) echo "386" ;;
    *) return 1 ;;
  esac
}

verify_sha256_1141() {
  local file="$1" arch="$2" expected=""
  command -v sha256sum >/dev/null 2>&1 || { warn "系统没有 sha256sum，跳过校验。"; return 0; }
  case "$arch" in
    amd64) expected="b907365b154e4a7e3e40be15c2cd83433c0fa65c7dc736bdb1b5face2afe4501" ;;
    arm64) expected="d94fc9704372ca2fa2854e54c20b406e4b8779b5ccdd0c557da90ea9344e9631" ;;
    armv7) expected="4004839c33cd5fb4fcb0b771bd37b59661973c1635c674bd6c46a59a7415d4d5" ;;
    386) expected="5d56bb3c66b1a7e4d1e04710d660531de7c594bb61be2c142bf3ad4c5a238c2c" ;;
  esac
  [ -n "$expected" ] || return 0
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "sing-box 下载文件 SHA256 校验失败。"
  ok "SHA256 校验通过。"
}

install_singbox() {
  local arch="$1" version="$2"
  local asset="sing-box-${version}-linux-${arch}-musl.tar.gz"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"

  mkdir -p "$WORKDIR/unpack" "$INSTALL_DIR"
  info "下载官方 sing-box v${version} (${arch}, musl)..."
  download_file "$url" "$WORKDIR/$asset" || die "下载失败: $url"

  if [ "$version" = "1.14.1" ]; then
    verify_sha256_1141 "$WORKDIR/$asset" "$arch"
  else
    warn "自定义版本 ${version} 未内置 SHA256，跳过固定校验。"
  fi

  tar -xzf "$WORKDIR/$asset" -C "$WORKDIR/unpack"
  local src="$WORKDIR/unpack/sing-box-${version}-linux-${arch}-musl/sing-box"
  [ -f "$src" ] || die "解压后未找到 sing-box 二进制。"

  cp "$src" "$BIN_PATH"
  chmod 755 "$BIN_PATH"
  ok "已安装: $($BIN_PATH version | head -n1)"
}

backup_old_config() {
  if [ -e "$CONFIG_PATH" ]; then
    local backup="/root/sing-box-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup"
    cp -a "$CONFIG_DIR" "$backup/" 2>/dev/null || true
    warn "检测到旧配置，已备份到: $backup"
  fi
}

write_config() {
  mkdir -p "$CONFIG_DIR"

  UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
  [ -n "$UUID" ] || die "无法从 /proc/sys/kernel/random/uuid 生成 UUID。"

  local keys
  keys="$($BIN_PATH generate reality-keypair 2>/dev/null || true)"
  PRIVATE_KEY="$(printf '%s\n' "$keys" | awk '/PrivateKey/{print $NF}')"
  PUBLIC_KEY="$(printf '%s\n' "$keys" | awk '/PublicKey/{print $NF}')"
  [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || die "Reality 密钥生成失败。"

  SHORT_ID="$($BIN_PATH generate rand 8 --hex 2>/dev/null || true)"
  [ -n "$SHORT_ID" ] || die "Reality Short ID 生成失败。"

  cat > "$CONFIG_PATH" <<EOF_CONFIG
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "user1",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ],
  "route": {
    "final": "direct-out"
  }
}
EOF_CONFIG

  chmod 600 "$CONFIG_PATH"
  "$BIN_PATH" check -c "$CONFIG_PATH" || die "sing-box 配置校验失败。"
  ok "配置校验通过。"
}

write_client_info() {
  local uri_host="$SERVER_HOST"
  case "$uri_host" in
    *:*) uri_host="[$uri_host]" ;;
  esac

  local tag uri
  tag="$(url_encode "$NODE_NAME")"
  uri="vless://${UUID}@${uri_host}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${tag}"

  cat > "$CLIENT_INFO" <<EOF_INFO
Sing-box Alpine/Podman VLESS Reality
====================================
Server: ${SERVER_HOST}
Port: ${PORT}
UUID: ${UUID}
Flow: xtls-rprx-vision
Security: reality
SNI: ${REALITY_SNI}
Public Key: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
Fingerprint: chrome
Network: tcp

Import URI:
${uri}
EOF_INFO
  cp "$CLIENT_INFO" "$ROOT_INFO"
  chmod 600 "$CLIENT_INFO" "$ROOT_INFO"
}

setup_openrc_service() {
  if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 && [ -x /sbin/openrc-run ]; then
    cat > "$SERVICE_PATH" <<'EOF_SERVICE'
#!/sbin/openrc-run
name="sing-box"
description="sing-box VLESS Reality server"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-delay 5 --respawn-max 0"

depend() {
  need net
  after firewall
}
EOF_SERVICE
    chmod +x "$SERVICE_PATH"
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-service sing-box restart
    sleep 1
    rc-service sing-box status || die "sing-box 服务没有正常启动。可执行: sing-box run -c $CONFIG_PATH"
    SERVICE_MODE="openrc"
    ok "OpenRC 服务已启动，并设置为开机自动启动。"
  else
    warn "没有检测到完整 OpenRC，改用后台进程启动；容器重启后可能需要手动 sb start。"
    if [ -f /run/sing-box.pid ] && kill -0 "$(cat /run/sing-box.pid)" 2>/dev/null; then
      kill "$(cat /run/sing-box.pid)" 2>/dev/null || true
      rm -f /run/sing-box.pid
    fi
    nohup "$BIN_PATH" run -c "$CONFIG_PATH" >/var/log/sing-box.log 2>&1 &
    echo $! > /run/sing-box.pid
    sleep 1
    kill -0 "$(cat /run/sing-box.pid)" 2>/dev/null || die "sing-box 后台启动失败，请查看 /var/log/sing-box.log"
    SERVICE_MODE="background"
    ok "sing-box 已在后台运行。"
  fi
}

create_manager() {
  cat > "$MANAGER_PATH" <<'EOF_SB'
#!/bin/bash
set -u
BIN="/usr/local/bin/sing-box"
CFG="/etc/sing-box/config.json"
INFO="/etc/sing-box/client-info.txt"
PIDFILE="/run/sing-box.pid"

has_openrc() {
  command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/sing-box ]
}

bg_start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "sing-box 已经在运行。"
    return 0
  fi
  nohup "$BIN" run -c "$CFG" >/var/log/sing-box.log 2>&1 &
  echo $! > "$PIDFILE"
  sleep 1
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null && echo "sing-box 已启动。" || { echo "启动失败，查看 /var/log/sing-box.log"; return 1; }
}

bg_stop() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

case "${1:-help}" in
  start)
    if has_openrc; then rc-service sing-box start; else bg_start; fi
    ;;
  stop)
    if has_openrc; then rc-service sing-box stop; else bg_stop; fi
    ;;
  restart)
    if has_openrc; then rc-service sing-box restart; else bg_stop; bg_start; fi
    ;;
  status)
    if has_openrc; then
      rc-service sing-box status
    elif [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "sing-box 正在运行，PID=$(cat "$PIDFILE")"
    else
      echo "sing-box 未运行"
      exit 1
    fi
    ;;
  uri|info)
    cat "$INFO"
    ;;
  config)
    cat "$CFG"
    ;;
  check)
    "$BIN" check -c "$CFG"
    ;;
  version)
    "$BIN" version
    ;;
  log|logs)
    if [ -f /var/log/sing-box.log ]; then tail -n 100 /var/log/sing-box.log; else echo "当前没有独立日志文件。"; fi
    ;;
  uninstall)
    echo "将停止并删除 sing-box 程序、服务和配置。"
    printf "确认卸载？输入 YES: "
    read -r ans
    [ "$ans" = "YES" ] || exit 0
    if has_openrc; then
      rc-service sing-box stop 2>/dev/null || true
      rc-update del sing-box default 2>/dev/null || true
    else
      bg_stop
    fi
    rm -f /etc/init.d/sing-box /usr/local/bin/sing-box /usr/local/bin/sb /root/singbox-node.txt
    rm -rf /etc/sing-box
    echo "已卸载。"
    ;;
  *)
    echo "用法: sb {status|start|stop|restart|uri|config|check|version|logs|uninstall}"
    ;;
esac
EOF_SB
  chmod +x "$MANAGER_PATH"
}

show_environment() {
  info "脚本版本: ${SCRIPT_VERSION}"
  info "系统: Alpine $(cat /etc/alpine-release 2>/dev/null || true) / PID1=$(cat /proc/1/comm 2>/dev/null || echo unknown)"
  info "根分区: $(df -h / 2>/dev/null | awk 'NR==2{print $2" total, "$4" free"}' || true)"

  if [ -r /sys/fs/cgroup/memory.max ]; then
    local max
    max="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
    [ "$max" = "max" ] || [ -z "$max" ] || info "cgroup memory.max: $max bytes"
  fi
}

main() {
  show_environment

  ARCH="$(arch_detect)" || die "不支持的 CPU 架构: $(uname -m)"
  SINGBOX_VERSION="${SINGBOX_VERSION:-$DEFAULT_SINGBOX_VERSION}"

  local detected_ip
  detected_ip="$(get_public_ip || true)"
  [ -n "$detected_ip" ] || detected_ip="YOUR_SERVER_IP"

  prompt_value SERVER_HOST "请输入公网 IP 或域名" "$detected_ip"
  prompt_value PORT "请输入 VLESS Reality TCP 端口" "443"
  prompt_value REALITY_SNI "请输入 Reality SNI" "addons.mozilla.org"
  prompt_value NODE_NAME "请输入节点名称" "Alpine-Reality"

  SERVER_HOST="$(printf '%s' "$SERVER_HOST" | tr -d '[:space:]')"
  PORT="$(printf '%s' "$PORT" | tr -d '[:space:]')"
  REALITY_SNI="$(printf '%s' "$REALITY_SNI" | tr -d '[:space:]')"

  [ -n "$SERVER_HOST" ] && [ "$SERVER_HOST" != "YOUR_SERVER_IP" ] || die "未能自动获取公网 IP，请重新运行并手动输入公网 IP/域名。"
  check_port "$PORT" || die "端口必须是 1-65535 的数字。"
  [ -n "$REALITY_SNI" ] || die "Reality SNI 不能为空。"

  echo
  info "将安装 VLESS + Reality：${SERVER_HOST}:${PORT}，SNI=${REALITY_SNI}"
  info "本脚本不会执行 apk add / apk update，不需要 openssl 或 jq。"
  echo

  backup_old_config
  install_singbox "$ARCH" "$SINGBOX_VERSION"
  write_config
  write_client_info
  setup_openrc_service
  create_manager

  echo
  printf "%b============================================%b\n" "$C_GREEN" "$C_RESET"
  ok "部署完成"
  echo "sing-box: $($BIN_PATH version | head -n1)"
  echo "服务器: ${SERVER_HOST}:${PORT}"
  echo "Reality SNI: ${REALITY_SNI}"
  echo "节点信息: ${ROOT_INFO}"
  echo "管理命令: sb status | sb uri | sb restart | sb check"
  echo
  cat "$CLIENT_INFO"
  printf "%b============================================%b\n" "$C_GREEN" "$C_RESET"
  echo
  warn "如果这是 NAT/Podman 实例，请在服务商面板确认公网 TCP ${PORT} 已映射/放行到容器 TCP ${PORT}。"
}

main "$@"
