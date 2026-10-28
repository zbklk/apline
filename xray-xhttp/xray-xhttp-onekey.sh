#!/usr/bin/env bash
# Xray-core / VLESS + XHTTP + REALITY 一键安装与管理
# 独立实例：不会修改系统已有的 sing-box、xray 或 x-ui 服务。
# 仅从 XTLS/Xray-core 官方 GitHub Releases 下载，并按官方 SHA-256 摘要校验。
set -Eeuo pipefail
umask 077

APP="xray-xhttp"
DIR="/etc/$APP"
BIN_DIR="/usr/local/libexec/$APP"
BIN="$BIN_DIR/xray"
CONF="$DIR/config.json"
INFO="$DIR/node.json"
SERVICE_SYSTEMD="/etc/systemd/system/$APP.service"
SERVICE_OPENRC="/etc/init.d/$APP"
WORK=""
OS_NAME=""
INIT=""
ARCHIVE=""

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
die()  { red "错误：$*" >&2; exit 1; }
notice(){ printf '\n\033[36m==> %s\033[0m\n' "$*"; }
cleanup(){ [[ -z "$WORK" || ! -d "$WORK" ]] || rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'red "操作在第 $LINENO 行失败。旧节点若存在，通常未被改动；请检查上方报错。" >&2' ERR

need_root(){ [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行：sudo bash $0"; }
need_work(){ [[ -n "$WORK" ]] || WORK="$(mktemp -d -t xray-xhttp.XXXXXXXX)"; }
reset_work(){ cleanup; WORK="$(mktemp -d -t xray-xhttp.XXXXXXXX)"; }
replace_bin(){
  local src="$1" temp="$BIN_DIR/.xray-new.$$"
  mkdir -p "$BIN_DIR"
  install -m 755 "$src" "$temp"
  mv -f "$temp" "$BIN" # 原子替换，避免运行中的可执行文件出现 Text file busy
}
check_env(){
  [[ "$(uname -s)" == Linux ]] || die "仅支持 Linux。"
  [[ -r /etc/os-release ]] || die "无法识别 Linux 发行版。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_NAME="${ID:-unknown}"
  local family="${ID_LIKE:-}"
  case "$OS_NAME $family" in
    *alpine*) PKG="apk" ;;
    *debian*|*ubuntu*) PKG="apt" ;;
    *fedora*|*rhel*|*centos*|*rocky*|*almalinux*|*ol*)
      if command -v dnf >/dev/null 2>&1; then PKG="dnf"; else PKG="yum"; fi ;;
    *) die "暂不支持系统：$OS_NAME（支持 Debian / Ubuntu / Alpine / RHEL 系）。" ;;
  esac
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    INIT="systemd"
  elif command -v rc-service >/dev/null 2>&1 && [[ -x /sbin/openrc-run ]]; then
    INIT="openrc"
  else
    die "未检测到正在运行的 systemd 或 OpenRC，无法托管后台服务。"
  fi
  case "$(uname -m)" in
    x86_64|amd64) ARCHIVE="Xray-linux-64.zip" ;;
    aarch64|arm64) ARCHIVE="Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) ARCHIVE="Xray-linux-arm32-v7a.zip" ;;
    *) die "暂不支持 CPU 架构：$(uname -m)（支持 x86_64/ARM64/ARMv7）。" ;;
  esac
}

install_deps(){
  local missing=()
  local cmd
  for cmd in curl jq unzip openssl sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  notice "安装依赖：${missing[*]}"
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq ca-certificates curl jq unzip openssl coreutils ;;
    apk) apk add --no-cache ca-certificates curl jq unzip openssl coreutils ;;
    dnf) dnf install -y ca-certificates curl jq unzip openssl coreutils ;;
    yum) yum install -y ca-certificates curl jq unzip openssl coreutils ;;
  esac
  for cmd in curl jq unzip openssl sha256sum; do command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖：$cmd"; done
}

install_qrencode(){
  # 可选依赖：安装失败时只提示，不阻断 Xray 节点的安装/查看。
  command -v qrencode >/dev/null 2>&1 && return 0
  notice "自动安装 qrencode 二维码工具（可选）"
  local installed=0
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      if apt-get update -qq && apt-get install -y -qq qrencode; then installed=1; fi ;;
    apk) if apk add --no-cache qrencode; then installed=1; fi ;;
    dnf) if dnf install -y qrencode; then installed=1; fi ;;
    yum) if yum install -y qrencode; then installed=1; fi ;;
  esac
  if [[ "$installed" == 1 ]] && command -v qrencode >/dev/null 2>&1; then
    green "qrencode 已安装，准备显示二维码。"
    return 0
  fi
  yellow "qrencode 自动安装未成功（可能是软件源缺包或网络问题），不影响 Xray 节点。"
  return 1
}

managed_check(){
  local file
  if [[ "$INIT" == systemd ]]; then file="$SERVICE_SYSTEMD"; else file="$SERVICE_OPENRC"; fi
  if [[ -e "$file" ]] && ! grep -q 'Managed by xray-xhttp-onekey' "$file"; then
    die "已有同名但非本脚本管理的服务：$file；为安全起见拒绝覆盖。"
  fi
}

service_action(){
  local action="$1"
  if [[ "$INIT" == systemd ]]; then
    systemctl "$action" "$APP"
  else
    case "$action" in
      enable) rc-update add "$APP" default ;;
      disable) rc-update del "$APP" default ;;
      *) rc-service "$APP" "$action" ;;
    esac
  fi
}
is_active(){
  if [[ "$INIT" == systemd ]]; then
    systemctl is-active --quiet "$APP"
  else
    rc-service "$APP" status >/dev/null 2>&1
  fi
}
service_file(){
  if [[ "$INIT" == systemd ]]; then
    if [[ ! -e "$SERVICE_SYSTEMD" ]]; then
      cat > "$SERVICE_SYSTEMD" <<EOF
# Managed by xray-xhttp-onekey
[Unit]
Description=Xray VLESS XHTTP REALITY (independent instance)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
      chmod 644 "$SERVICE_SYSTEMD"
      systemctl daemon-reload
    fi
  else
    if [[ ! -e "$SERVICE_OPENRC" ]]; then
      cat > "$SERVICE_OPENRC" <<EOF
#!/sbin/openrc-run
# Managed by xray-xhttp-onekey
name="$APP"
command="$BIN"
command_args="run -c $CONF"
command_background="yes"
pidfile="/run/$APP.pid"
output_log="/var/log/$APP.log"
error_log="/var/log/$APP.err"
depend() { need net; }
EOF
      chmod 755 "$SERVICE_OPENRC"
    fi
  fi
}

fetch_core(){
  need_work
  notice "从 XTLS 官方 GitHub 查询最新 Xray-core Release..."
  local release tag digest url zip
  release="$(curl -fLsS --connect-timeout 10 --max-time 40 --retry 3 \
      -H 'Accept: application/vnd.github+json' \
      'https://api.github.com/repos/XTLS/Xray-core/releases/latest')" || die "无法获取 GitHub 最新版本，请检查网络或 API 限额。"
  tag="$(jq -r '.tag_name // empty' <<< "$release")"
  [[ "$tag" =~ ^v[0-9][a-zA-Z0-9._-]*$ ]] || die "官方版本号无效。"
  digest="$(jq -r --arg name "$ARCHIVE" '.assets[] | select(.name == $name) | .digest // empty' <<< "$release")"
  [[ "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || die "官方 Release 缺少此架构的 SHA-256 摘要，已拒绝安装。"
  url="$(jq -r --arg name "$ARCHIVE" '.assets[] | select(.name == $name) | .browser_download_url // empty' <<< "$release")"
  [[ "$url" == "https://github.com/XTLS/Xray-core/releases/download/$tag/$ARCHIVE" ]] || die "下载链接不是预期的官方地址。"
  zip="$WORK/$ARCHIVE"
  notice "下载 $tag / $ARCHIVE"
  curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 -o "$zip" "$url" || die "Xray 压缩包下载失败。"
  printf '%s  %s\n' "${digest#sha256:}" "$zip" | sha256sum --check --status || die "SHA-256 校验失败，已拒绝安装。"
  unzip -p "$zip" xray > "$WORK/xray.new" || die "未能从压缩包提取 Xray。"
  chmod 755 "$WORK/xray.new"
  "$WORK/xray.new" version >/dev/null || die "下载的内核无法运行（检查系统架构或 libc）。"
  CORE_TAG="$tag"
  green "官方文件校验通过：$tag"
}

ask(){
  local message="$1" def="$2" reply
  read -r -p "$message [$def]: " reply || die "输入被中断。"
  printf '%s' "${reply:-$def}"
}
port_valid(){ [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
sni_valid(){
  [[ ${#1} -le 253 ]] && [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$1" == *.* ]] && [[ "$1" != *..* ]]
}
path_valid(){ [[ "$1" =~ ^/[A-Za-z0-9._~/-]{1,120}$ ]] && [[ "$1" != *'//'* ]]; }
addr_valid(){
  [[ -n "$1" && ${#1} -le 253 && "$1" =~ ^[a-zA-Z0-9.:-]+$ ]] && [[ "$1" != *'..'* ]]
}
port_busy(){
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq ":${1}$"
}
get_address(){
  local a
  a="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if ! addr_valid "$a"; then
    a="$(curl -6fsS --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "$a"
}
urlencode_path(){
  # 用户路径字符受到限制；只需对 / 做百分号编码，其余为 RFC3986 非保留字符。
  local x="${1//\//%2F}"
  printf '%s' "$x"
}

build_config(){
  local outfile="$1" uuid="$2" port="$3" sni="$4" key="$5" sid="$6" path="$7" listen="$8"
  jq -n --arg uuid "$uuid" --arg sni "$sni" --arg private "$key" \
    --arg sid "$sid" --arg path "$path" --arg listen "$listen" --argjson port "$port" \
    '{log:{loglevel:"warning"},inbounds:[{tag:"vless-xhttp-reality",listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid}],decryption:"none"},streamSettings:{network:"xhttp",security:"reality",realitySettings:{target:($sni+":443"),serverNames:[$sni],privateKey:$private,shortIds:[$sid]},xhttpSettings:{path:$path,mode:"auto"}},sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}],outbounds:[{tag:"direct",protocol:"freedom"}]}' > "$outfile"
  chmod 600 "$outfile"
}
build_info(){
  local outfile="$1" uuid="$2" port="$3" sni="$4" pub="$5" sid="$6" path="$7" address="$8" tag="$9"
  jq -n --arg uuid "$uuid" --arg sni "$sni" --arg pub "$pub" \
    --arg sid "$sid" --arg path "$path" --arg addr "$address" --arg tag "$tag" --argjson port "$port" \
    '{uuid:$uuid,port:$port,sni:$sni,publicKey:$pub,shortId:$sid,path:$path,address:$addr,core:$tag,mode:"auto"}' > "$outfile"
  chmod 600 "$outfile"
}

open_firewall(){
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$port/tcp" comment "$APP" >/dev/null && green "UFW 已放行 TCP/$port" || yellow "UFW 放行失败，请手动配置。"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if firewall-cmd --permanent --add-port="$port/tcp" >/dev/null && firewall-cmd --reload >/dev/null; then
      green "firewalld 已放行 TCP/$port"
    else
      yellow "firewalld 放行失败，请手动配置。"
    fi
  else
    yellow "未检测到运行中的 UFW/firewalld；不会更改 iptables/nftables。"
  fi
  yellow "请确认 VPS 服务商的安全组也允许 TCP/$port。不会自动启用或清空防火墙。"
}

cleanup_first_failure(){
  service_action stop >/dev/null 2>&1 || true
  service_action disable >/dev/null 2>&1 || true
  if [[ "$INIT" == systemd ]]; then
    if [[ -f "$SERVICE_SYSTEMD" ]] && grep -q 'Managed by xray-xhttp-onekey' "$SERVICE_SYSTEMD"; then
      rm -f "$SERVICE_SYSTEMD"
      systemctl daemon-reload
    fi
  else
    if [[ -f "$SERVICE_OPENRC" ]] && grep -q 'Managed by xray-xhttp-onekey' "$SERVICE_OPENRC"; then
      rm -f "$SERVICE_OPENRC"
    fi
  fi
}

commit_config(){
  local new_cfg="$1" new_info="$2" new_bin="$3"
  local had_config=0 had_bin=0 was_active=0
  [[ -e "$CONF" ]] && { cp -p "$CONF" "$WORK/old-config"; had_config=1; }
  [[ -e "$INFO" ]] && cp -p "$INFO" "$WORK/old-info"
  [[ -e "$BIN" ]] && { cp -p "$BIN" "$WORK/old-bin"; had_bin=1; }
  is_active && was_active=1 || true

  # 在写入磁盘前先使用准备安装的内核验证候选配置。
  "$new_bin" run -test -c "$new_cfg" || die "Xray 配置测试失败，旧服务未改动。"
  mkdir -p "$DIR" "$BIN_DIR"
  chmod 700 "$DIR" "$BIN_DIR"
  if [[ "$new_bin" != "$BIN" ]]; then replace_bin "$new_bin"; fi
  install -m 600 "$new_cfg" "$CONF"
  install -m 600 "$new_info" "$INFO"
  service_file
  service_action enable >/dev/null
  if ! service_action restart >/dev/null 2>&1; then
    yellow "新服务启动失败，正在恢复之前的配置与内核..."
    if [[ "$had_bin" == 1 ]]; then replace_bin "$WORK/old-bin"; else rm -f "$BIN"; fi
    if [[ "$had_config" == 1 ]]; then cp -p "$WORK/old-config" "$CONF"; else rm -f "$CONF"; fi
    if [[ -f "$WORK/old-info" ]]; then cp -p "$WORK/old-info" "$INFO"; else rm -f "$INFO"; fi
    if [[ "$had_config" == 0 ]]; then cleanup_first_failure; elif [[ "$was_active" == 1 && "$had_bin" == 1 ]]; then service_action restart >/dev/null 2>&1 || true; fi
    die "已执行回滚。请检查端口冲突、SNI 或系统日志。"
  fi
  sleep 1
  if ! is_active; then
    yellow "服务启动后退出，正在恢复之前的配置与内核..."
    if [[ "$had_bin" == 1 ]]; then replace_bin "$WORK/old-bin"; else rm -f "$BIN"; fi
    if [[ "$had_config" == 1 ]]; then cp -p "$WORK/old-config" "$CONF"; else rm -f "$CONF"; fi
    if [[ -f "$WORK/old-info" ]]; then cp -p "$WORK/old-info" "$INFO"; else rm -f "$INFO"; fi
    if [[ "$had_config" == 0 ]]; then cleanup_first_failure; elif [[ "$was_active" == 1 && "$had_bin" == 1 ]]; then service_action restart >/dev/null 2>&1 || true; fi
    die "已回滚。查看日志并排查端口占用。"
  fi
  green "服务已安装并正常运行。"
}

install_node(){
  managed_check
  if [[ -e "$CONF" ]]; then
    yellow "已存在本脚本安装的节点，重新安装会生成新的 UUID、密钥及路径，旧客户端将失效！"
    local confirm
    read -r -p '输入 REBUILD 确认重建（其他任意内容取消）：' confirm
    [[ "$confirm" == REBUILD ]] || { yellow '已取消。'; return; }
  fi
  notice "系统：$OS_NAME / $(uname -m) / $INIT"
  install_deps
  reset_work
  fetch_core
  local default_addr address port sni path listen uuid keys priv pub sid
  default_addr="$(get_address)"
  [[ -n "$default_addr" ]] || default_addr="请填写你的公网IP或域名"
  address="$(ask '节点公网 IPv4 / IPv6 / 域名' "$default_addr")"
  addr_valid "$address" || die "公网地址格式不合法：$address"
  port="$(ask '节点 TCP 端口' '443')"
  port_valid "$port" || die "端口必须是 1～65535。"
  if port_busy "$port" && [[ ! -e "$CONF" || "$(jq -r '.inbounds[0].port' "$CONF")" != "$port" ]]; then
    die "TCP/$port 已被其他程序占用，请换一个端口。"
  fi
  sni="$(ask 'REALITY 目标站点 SNI（支持 TLS1.3/H2，不要填自己的 IP）' 'www.microsoft.com')"
  sni_valid "$sni" || die "SNI 格式不合法，请填写网站域名。"
  path="$(ask 'XHTTP 路径（留默认即可）' "/$(openssl rand -hex 8)")"
  path_valid "$path" || die "路径必须以 / 开头且仅使用英文、数字、/、-、_、.、~。"
  listen="0.0.0.0"
  if [[ "$address" == *:* ]]; then
    listen="::"
    yellow "检测到 IPv6 节点地址，使用 :: 监听；双栈行为取决于系统 IPv6 配置。"
  fi
  notice "生成 UUID / REALITY 密钥 / Short ID"
  uuid="$("$WORK/xray.new" uuid | tr -d '\r\n')"
  [[ "$uuid" =~ ^[a-fA-F0-9-]{36}$ ]] || die "UUID 生成失败。"
  keys="$("$WORK/xray.new" x25519)"
  priv="$(awk -F: 'tolower($1) ~ /^private ?key/ {gsub(/[[:space:]]/,"",$2);print $2;exit}' <<< "$keys")"
  pub="$(awk -F: 'tolower($1) ~ /(password|public ?key)/ && tolower($1) !~ /private/ {gsub(/[[:space:]]/,"",$2);print $2;exit}' <<< "$keys")"
  [[ "$priv" =~ ^[A-Za-z0-9_-]{43}$ && "$pub" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "REALITY 密钥解析失败，可能是内核输出格式变化。"
  sid="$(openssl rand -hex 8)"
  build_config "$WORK/new-config.json" "$uuid" "$port" "$sni" "$priv" "$sid" "$path" "$listen"
  build_info "$WORK/new-node.json" "$uuid" "$port" "$sni" "$pub" "$sid" "$path" "$address" "$CORE_TAG"
  commit_config "$WORK/new-config.json" "$WORK/new-node.json" "$WORK/xray.new"
  open_firewall "$port"
  show_node
}

make_uri(){
  local uuid port sni pub sid path address core mode host
  uuid="$(jq -r '.uuid' "$INFO")"
  port="$(jq -r '.port' "$INFO")"
  sni="$(jq -r '.sni' "$INFO")"
  pub="$(jq -r '.publicKey' "$INFO")"
  sid="$(jq -r '.shortId' "$INFO")"
  path="$(jq -r '.path' "$INFO")"
  address="$(jq -r '.address' "$INFO")"
  mode="$(jq -r '.mode' "$INFO")"
  host="$address"
  if [[ "$host" == *:* ]]; then host="[$host]"; fi
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&mode=%s#Xray-XHTTP-Reality' \
     "$uuid" "$host" "$port" "$sni" "$pub" "$sid" "$(urlencode_path "$path")" "$mode"
}
show_node(){
  [[ -f "$INFO" && -f "$CONF" ]] || { yellow '尚未安装节点，请先选 1。'; return; }
  notice "节点信息（仅在可信终端查看，链接含凭据）"
  jq -r '"公网地址：\(.address)\nTCP 端口：\(.port)\nUUID：\(.uuid)\nSNI：\(.sni)\nREALITY PublicKey：\(.publicKey)\nShort ID：\(.shortId)\nXHTTP 路径：\(.path)\nXHTTP 模式：\(.mode)\n安装时内核：\(.core)"' "$INFO"
  printf '\n服务状态：'
  if is_active; then green '运行中'; else red '未运行'; fi
  printf '\n导入链接：\n%s\n' "$(make_uri)"
  # 首次安装完成或重新查看已有节点时，缺少工具就自动尝试安装。
  if command -v qrencode >/dev/null 2>&1 || install_qrencode; then
    printf '\n二维码（请勿公开分享）：\n'
    if ! make_uri | qrencode -t ANSIUTF8; then
      yellow "二维码生成失败，请复制上方 VLESS 导入链接。"
    fi
  else
    yellow "终端二维码暂不可用，请复制上方 VLESS 导入链接。"
  fi
}

update_core(){
  [[ -f "$CONF" && -x "$BIN" ]] || die "尚未安装，不能更新。"
  managed_check
  install_deps
  reset_work
  fetch_core
  local current old_active=0
  current="$("$BIN" version | head -n 1)"
  if grep -Fq "$CORE_TAG" <<< "$current"; then green "当前已是官方最新：$CORE_TAG"; return; fi
  is_active && old_active=1 || true
  "$WORK/xray.new" run -test -c "$CONF" || die "新内核不兼容现有配置，已取消升级。"
  cp -p "$BIN" "$WORK/old-bin"
  cp -p "$INFO" "$WORK/old-info"
  replace_bin "$WORK/xray.new"
  jq --arg core "$CORE_TAG" '.core=$core' "$INFO" > "$WORK/update-node.json"
  install -m 600 "$WORK/update-node.json" "$INFO"
  if [[ "$old_active" == 1 ]]; then
    if ! service_action restart >/dev/null 2>&1; then
      replace_bin "$WORK/old-bin"
      cp -p "$WORK/old-info" "$INFO"
      service_action restart >/dev/null 2>&1 || true
      die "升级后重启失败，已回滚。"
    fi
    sleep 1
    if ! is_active; then
      replace_bin "$WORK/old-bin"
      cp -p "$WORK/old-info" "$INFO"
      service_action restart >/dev/null 2>&1 || true
      die "升级后服务异常，已回滚。"
    fi
  fi
  green "更新成功：$CORE_TAG（更新前停止的服务仍保持停止）。"
}
change_port(){
  [[ -f "$CONF" && -f "$INFO" ]] || die '尚未安装。'
  managed_check
  local old new
  old="$(jq -r '.port' "$INFO")"
  new="$(ask '新 TCP 端口' "$old")"
  port_valid "$new" || die '端口无效。'
  [[ "$new" != "$old" ]] || { green '端口没有变化。'; return; }
  if port_busy "$new"; then die "TCP/$new 已被占用。"; fi
  reset_work
  jq --argjson port "$new" '.inbounds[0].port=$port' "$CONF" > "$WORK/change-config.json"
  jq --argjson port "$new" '.port=$port' "$INFO" > "$WORK/change-node.json"
  commit_config "$WORK/change-config.json" "$WORK/change-node.json" "$BIN"
  open_firewall "$new"
  yellow "旧端口 TCP/$old 的防火墙规则没有自动删除，以免影响其他业务；如不再使用请自行清理。"
  show_node
}

show_logs(){
  if [[ "$INIT" == systemd ]]; then
    journalctl -u "$APP" -n 70 --no-pager
  else
    if [[ -f "/var/log/$APP.err" || -f "/var/log/$APP.log" ]]; then
      [[ -f "/var/log/$APP.err" ]] && tail -n 50 "/var/log/$APP.err" || true
      [[ -f "/var/log/$APP.log" ]] && tail -n 50 "/var/log/$APP.log" || true
    else
      yellow "暂无 OpenRC 服务日志，可检查 /var/log/messages（若存在）。"
      [[ -f /var/log/messages ]] && tail -n 70 /var/log/messages || true
    fi
  fi
}
remove_node(){
  [[ -f "$CONF" ]] || { yellow '无已安装节点。'; return; }
  managed_check
  yellow "只删除 $APP 独立服务和配置，不触碰系统其他 Xray/sing-box 服务。"
  local ans
  read -r -p '输入 REMOVE 确认删除：' ans
  [[ "$ans" == REMOVE ]] || { yellow '已取消。'; return; }
  service_action stop >/dev/null 2>&1 || true
  service_action disable >/dev/null 2>&1 || true
  if [[ "$INIT" == systemd ]]; then
    rm -f "$SERVICE_SYSTEMD"
    systemctl daemon-reload
  else
    rm -f "$SERVICE_OPENRC"
  fi
  rm -rf -- "$DIR" "$BIN_DIR"
  green "已卸载 $APP；没有删除防火墙规则，请按需手动处理。"
}

main(){
  need_root
  check_env
  while true; do
    printf '\n'
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf '  Xray-core / VLESS + XHTTP + REALITY\n'
    printf '  系统：%s | 架构：%s | 服务：%s\n' "$OS_NAME" "$(uname -m)" "$INIT"
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf '  1. 一键安装 / 重新生成节点\n'
    printf '  2. 查看配置、链接和二维码\n'
    printf '  3. 启动服务\n'
    printf '  4. 停止服务\n'
    printf '  5. 重启服务\n'
    printf '  6. 升级到最新官方 Xray-core\n'
    printf '  7. 查看服务日志\n'
    printf '  8. 修改端口（保留原 UUID/密钥）\n'
    printf '  9. 卸载本脚本安装的节点\n'
    printf '  0. 退出\n'
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    local choice
    read -r -p '请输入选项 [0-9]：' choice || break
    case "$choice" in
      1) install_node ;;
      2) show_node ;;
      3) managed_check; service_action start; green '启动指令已执行。' ;;
      4) managed_check; service_action stop; green '停止指令已执行。' ;;
      5) managed_check; service_action restart; green '重启指令已执行。' ;;
      6) update_core ;;
      7) show_logs ;;
      8) change_port ;;
      9) remove_node ;;
      0) exit 0 ;;
      *) yellow '无效选项。' ;;
    esac
  done
}
main "$@"