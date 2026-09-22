#!/bin/sh
# ============================================================
# vless-l2tp 一键安装脚本
# 功能：在 VPS 上用 xl2tpd 拨号 L2TP，并在本机搭建 VLESS 节点，
#       VLESS 的出站流量经 L2TP 隧道出去（出口 IP = L2TP 分配的 IP）
# 支持：Debian / Ubuntu / Alpine（需 root）
#
# 无终端时可用环境变量传入（否则会中文提示输入）：
#   必填：L2TP_SERVER / L2TP_USER / L2TP_PASS
#   可选：VLESS_PORT / VLESS_UUID / TRANSPORT=reality|ws /
#         REALITY_DEST / WS_PATH
# ============================================================
set -u

FW_MARK=100
RT_TABLE=100
LAC_NAME="uk"

info()  { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*"; }
die()   { error "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行此脚本"

# ---------- 输入（环境变量优先，无终端时必填项必须给环境变量） ----------
L2TP_SERVER="${L2TP_SERVER:-}"
L2TP_USER="${L2TP_USER:-}"
L2TP_PASS="${L2TP_PASS:-}"
VLESS_PORT="${VLESS_PORT:-}"
VLESS_UUID="${VLESS_UUID:-}"
TRANS_CHOICE="${TRANS_CHOICE:-}"
TRANSPORT="${TRANSPORT:-}"
REALITY_DEST="${REALITY_DEST:-}"
WS_PATH="${WS_PATH:-}"

if [ -t 0 ]; then TTY=1; else TTY=0; fi

get_var() {
  case "$1" in
    L2TP_SERVER)  printf '%s' "$L2TP_SERVER" ;;
    L2TP_USER)    printf '%s' "$L2TP_USER" ;;
    L2TP_PASS)    printf '%s' "$L2TP_PASS" ;;
    VLESS_PORT)   printf '%s' "$VLESS_PORT" ;;
    VLESS_UUID)   printf '%s' "$VLESS_UUID" ;;
    TRANS_CHOICE) printf '%s' "$TRANS_CHOICE" ;;
    TRANSPORT)    printf '%s' "$TRANSPORT" ;;
    REALITY_DEST) printf '%s' "$REALITY_DEST" ;;
    WS_PATH)      printf '%s' "$WS_PATH" ;;
  esac
}

set_var() {
  case "$1" in
    L2TP_SERVER)  L2TP_SERVER="$2" ;;
    L2TP_USER)    L2TP_USER="$2" ;;
    L2TP_PASS)    L2TP_PASS="$2" ;;
    VLESS_PORT)   VLESS_PORT="$2" ;;
    VLESS_UUID)   VLESS_UUID="$2" ;;
    TRANS_CHOICE) TRANS_CHOICE="$2" ;;
    TRANSPORT)    TRANSPORT="$2" ;;
    REALITY_DEST) REALITY_DEST="$2" ;;
    WS_PATH)      WS_PATH="$2" ;;
    *) die "内部错误：未知变量 $1" ;;
  esac
}

ask_req() { # $1=变量名 $2=提示（必填）
  while :; do
    _cur="$(get_var "$1")"
    if [ "$TTY" = "1" ]; then
      printf '%s: ' "$2"
      IFS= read -r _ans || _ans=""
      [ -z "$_ans" ] && _ans="$_cur"
      if [ -n "$_ans" ]; then set_var "$1" "$_ans"; break; fi
      echo "不能为空，请重新输入"
    else
      [ -n "$_cur" ] || die "$2 不能为空（无终端时请用环境变量 $1 传入）"
      break
    fi
  done
}

ask_def() { # $1=变量名 $2=提示 $3=默认值
  _cur="$(get_var "$1")"
  if [ "$TTY" = "1" ]; then
    printf '%s [默认 %s]: ' "$2" "$3"
    IFS= read -r _ans || _ans=""
    [ -z "$_ans" ] && _ans="${_cur:-$3}"
    set_var "$1" "$_ans"
  else
    set_var "$1" "${_cur:-$3}"
  fi
}

ask_secret() { # $1=变量名 $2=提示（密码，输入不回显）
  while :; do
    _cur="$(get_var "$1")"
    if [ "$TTY" = "1" ]; then
      printf '%s: ' "$2"
      stty -echo 2>/dev/null || true
      IFS= read -r _ans || _ans=""
      stty echo 2>/dev/null || true
      printf '\n'
      [ -z "$_ans" ] && _ans="$_cur"
      if [ -n "$_ans" ]; then set_var "$1" "$_ans"; break; fi
      echo "不能为空，请重新输入"
    else
      [ -n "$_cur" ] || die "$2 不能为空（无终端时请用环境变量 $1 传入）"
      break
    fi
  done
}

echo "=============================================="
echo " vless-l2tp 一键脚本"
echo " L2TP 拨号 + VLESS 节点，出口走 L2TP 隧道"
echo "=============================================="
echo ""

ask_req    L2TP_SERVER "L2TP 服务器地址（IP 或域名）"
ask_req    L2TP_USER   "L2TP 用户名"
ask_secret L2TP_PASS   "L2TP 密码"
ask_def    VLESS_PORT  "VLESS 端口" "443"
case "$VLESS_PORT" in ''|*[!0-9]*) die "端口必须是数字" ;; esac
[ "$VLESS_PORT" -ge 1 ] && [ "$VLESS_PORT" -le 65535 ] || die "端口范围 1-65535"

_auto_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "")"
ask_def VLESS_UUID "VLESS UUID（回车自动生成）" "$_auto_uuid"
[ -n "$VLESS_UUID" ] || die "UUID 生成失败，请手动输入一个"

case "$TRANSPORT" in reality|ws) ;; *) TRANSPORT="" ;; esac
if [ -z "$TRANSPORT" ]; then
  if [ "$TTY" = "1" ]; then
    echo ""
    echo "传输方式："
    echo "  1) TCP + REALITY（默认，推荐）"
    echo "  2) WebSocket（明文，简单）"
  fi
  ask_def TRANS_CHOICE "请选择 [1/2]" "1"
  case "$TRANS_CHOICE" in
    2|ws|WS) TRANSPORT="ws" ;;
    *)       TRANSPORT="reality" ;;
  esac
fi

if [ "$TRANSPORT" = "reality" ]; then
  ask_def REALITY_DEST "REALITY 目标网站" "www.microsoft.com:443"
else
  ask_def WS_PATH "WebSocket 路径" "/ws"
  case "$WS_PATH" in /*) ;; *) WS_PATH="/$WS_PATH" ;; esac
fi
echo ""

# ---------- 系统识别与依赖 ----------
if [ -f /etc/alpine-release ]; then
  OS="alpine"
elif [ -f /etc/debian_version ]; then
  OS="debian"
else
  die "仅支持 Debian / Ubuntu / Alpine"
fi
info "系统：$OS"

if [ "$OS" = "alpine" ]; then
  apk add --no-cache xl2tpd curl unzip iproute2 iptables 2>&1 | tail -1
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>&1 | tail -1
  apt-get install -y -qq xl2tpd curl unzip iproute2 iptables 2>&1 | tail -1
fi

# ---------- 记录原始默认路由（L2TP 服务器必须走这条，否则隧道自环） ----------
DEF_GW="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
DEF_IF="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
[ -n "$DEF_GW" ] && [ -n "$DEF_IF" ] || die "获取默认路由失败"
info "原始网关：$DEF_GW，经由 $DEF_IF"
mkdir -p /etc/l2tp-vless
printf 'GW=%s\nIF=%s\nSERVER=%s\n' "$DEF_GW" "$DEF_IF" "$L2TP_SERVER" > /etc/l2tp-vless/net.env

# ---------- 保路由脚本（开机 / 拨号前执行） ----------
cat > /usr/local/sbin/l2tp-vless-route.sh <<'EOF'
#!/bin/sh
# 保证 L2TP 服务器 IP 始终走原始网关，防止隧道流量被策略路由吸走导致自环
[ -f /etc/l2tp-vless/net.env ] || exit 0
. /etc/l2tp-vless/net.env
[ -n "$GW" ] && [ -n "$IF" ] && [ -n "$SERVER" ] || exit 0
SIP="$(getent hosts "$SERVER" 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')"
[ -n "$SIP" ] || exit 0
ip route replace "$SIP" via "$GW" dev "$IF" 2>/dev/null || true
EOF
chmod +x /usr/local/sbin/l2tp-vless-route.sh

# ---------- xl2tpd 配置 ----------
mkdir -p /etc/xl2tpd /etc/ppp
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]

[lac ${LAC_NAME}]
lns = ${L2TP_SERVER}
redial = yes
redial timeout = 10
ppp debug = no
pppoptfile = /etc/ppp/options.l2tp-vless
require chap = yes
refuse pap = yes
length bit = yes
EOF

cat > /etc/ppp/options.l2tp-vless <<EOF
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-chap
noccp
noauth
nodefaultroute
nobsdcomp
nodeflate
novj
novjccomp
mtu 1400
mru 1400
name ${L2TP_USER}
EOF

printf '"%s" * "%s" *\n' "$L2TP_USER" "$L2TP_PASS" > /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets /etc/ppp/options.l2tp-vless

# ---------- ppp 拨号成功 / 断开钩子：维护策略路由表 ----------
mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d
cat > /etc/ppp/ip-up.d/10-vless-egress <<EOF
#!/bin/sh
# \$1=ppp 接口名。把打了标记 ${FW_MARK} 的流量经本接口默认路由出去。
IF="\$1"
[ -n "\$IF" ] || exit 0
ip route replace default dev "\$IF" table ${RT_TABLE}
ip rule add fwmark ${FW_MARK} table ${RT_TABLE} 2>/dev/null || true
if command -v iptables >/dev/null 2>&1; then
  iptables -t mangle -C OUTPUT -o "\$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  iptables -t mangle -A OUTPUT -o "\$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
EOF
chmod +x /etc/ppp/ip-up.d/10-vless-egress

cat > /etc/ppp/ip-down.d/10-vless-egress <<EOF
#!/bin/sh
IF="\$1"
[ -n "\$IF" ] || exit 0
ip route del default dev "\$IF" table ${RT_TABLE} 2>/dev/null || true
EOF
chmod +x /etc/ppp/ip-down.d/10-vless-egress

# ---------- 开机自启：保路由 -> xl2tpd -> 自动拨号 ----------
if [ "$OS" = "alpine" ]; then
  cat > /etc/local.d/l2tp-vless.start <<EOF
#!/bin/sh
# 开机：先保住 L2TP 服务器路由，再自动拨号
/usr/local/sbin/l2tp-vless-route.sh
for i in \$(seq 1 15); do
  [ -e /var/run/xl2tpd/l2tp-control ] && break
  sleep 1
done
echo "c ${LAC_NAME}" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
EOF
  chmod +x /etc/local.d/l2tp-vless.start
  rc-update add local default >/dev/null 2>&1 || true
else
  cat > /etc/systemd/system/l2tp-vless-route.service <<'EOF'
[Unit]
Description=Keep L2TP server route via original gateway
Before=xl2tpd.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/l2tp-vless-route.sh
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/l2tp-vless-dial.service <<EOF
[Unit]
Description=Dial L2TP tunnel (${LAC_NAME})
After=xl2tpd.service
Requires=xl2tpd.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in \$(seq 1 15); do [ -e /var/run/xl2tpd/l2tp-control ] && break; sleep 1; done; echo "c ${LAC_NAME}" > /var/run/xl2tpd/l2tp-control'
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable l2tp-vless-route.service l2tp-vless-dial.service >/dev/null 2>&1 || true
fi

# ---------- 启动 xl2tpd 并拨号 ----------
/usr/local/sbin/l2tp-vless-route.sh
modprobe ppp_generic 2>/dev/null || true
if [ "$OS" = "alpine" ]; then
  rc-update add xl2tpd default >/dev/null 2>&1 || true
  rc-service xl2tpd restart >/dev/null 2>&1 || rc-service xl2tpd start
else
  systemctl enable xl2tpd >/dev/null 2>&1 || true
  systemctl restart xl2tpd
fi
sleep 2
for i in $(seq 1 10); do
  [ -e /var/run/xl2tpd/l2tp-control ] && break
  sleep 1
done
echo "c ${LAC_NAME}" > /var/run/xl2tpd/l2tp-control 2>/dev/null \
  || warn "拨号命令发送失败，可手动执行：echo 'c ${LAC_NAME}' > /var/run/xl2tpd/l2tp-control"

info "等待 PPP 接口建立（最多 40 秒）…"
PPP_IF=""
for i in $(seq 1 40); do
  PPP_IF="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^ppp[0-9]+$' | head -1)"
  [ -n "$PPP_IF" ] && break
  sleep 1
done
PPP_IP=""
if [ -z "$PPP_IF" ]; then
  warn "PPP 接口未建立：请检查 L2TP 服务器/用户名/密码是否正确"
  warn "查看日志：Debian 用 journalctl -u xl2tpd；Alpine 看 /var/log/messages"
  warn "脚本继续安装 VLESS，L2TP 通之后出口会自动走隧道"
else
  PPP_IP="$(ip -4 -o addr show dev "$PPP_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  info "隧道已建立：$PPP_IF，IP = ${PPP_IP:-未知}"
fi

# ---------- 安装 xray ----------
if [ ! -x /usr/local/bin/xray ]; then
  case "$(uname -m)" in
    x86_64)        XA=64 ;;
    aarch64|arm64) XA=arm64 ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
  T="$(mktemp -d)"
  U="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XA}.zip"
  info "下载 xray…"
  curl -fsSL --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 3 \
    -o "$T/xray.zip" "$U" || { rm -rf "$T"; die "xray 下载失败，请检查网络后重试"; }
  unzip -o -q "$T/xray.zip" -d "$T" || { rm -rf "$T"; die "xray 解压失败"; }
  install -m 755 "$T/xray" /usr/local/bin/xray
  rm -rf "$T"
fi

# ---------- 生成 xray 配置 ----------
if [ "$TRANSPORT" = "reality" ]; then
  _kp="$(/usr/local/bin/xray x25519)"
  PRIV_KEY="$(printf '%s' "$_kp" | awk '/Private key:/{print $3}')"
  PUB_KEY="$(printf '%s' "$_kp" | awk '/Public key:/{print $3}')"
  [ -n "$PRIV_KEY" ] && [ -n "$PUB_KEY" ] || die "REALITY 密钥生成失败"
  SHORT_ID="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  SNI="${REALITY_DEST%%:*}"
fi

mkdir -p /etc/xray
if [ "$TRANSPORT" = "reality" ]; then
  cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${VLESS_UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${PRIV_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "streamSettings": { "sockopt": { "mark": ${FW_MARK} } }
    }
  ]
}
EOF
else
  cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${VLESS_UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WS_PATH}" }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "streamSettings": { "sockopt": { "mark": ${FW_MARK} } }
    }
  ]
}
EOF
fi
/usr/local/bin/xray -test -config /etc/xray/config.json >/dev/null 2>&1 \
  || die "xray 配置校验失败"

# ---------- xray 服务 ----------
if [ "$OS" = "alpine" ]; then
  cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray VLESS (出口经 L2TP)"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; }
EOF
  chmod +x /etc/init.d/xray
  rc-update add xray default >/dev/null 2>&1 || true
  rc-service xray restart >/dev/null 2>&1 || rc-service xray start
else
  cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray VLESS (出口经 L2TP)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
fi
sleep 2

# ---------- 放行 VLESS 端口 ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${VLESS_PORT}"/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${VLESS_PORT}"/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "$VLESS_PORT" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p tcp --dport "$VLESS_PORT" -j ACCEPT 2>/dev/null || true
fi

# ---------- 验证与输出 ----------
DE_IP="$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null \
  || curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "")"
[ -n "$DE_IP" ] || DE_IP="<德国VPS公网IP>"
UK_IP=""
if [ -n "$PPP_IF" ]; then
  UK_IP="$(curl --interface "$PPP_IF" -s --max-time 15 https://ifconfig.me 2>/dev/null || echo "")"
fi
[ -n "$UK_IP" ] || UK_IP="<待 L2TP 拨号成功后自动生效>"

if [ "$TRANSPORT" = "reality" ]; then
  LINK="vless://${VLESS_UUID}@${DE_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#uk-egress"
else
  _p="$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')"
  LINK="vless://${VLESS_UUID}@${DE_IP}:${VLESS_PORT}?encryption=none&type=ws&path=${_p}#uk-egress"
fi
printf '%s\n' "$LINK" > /etc/l2tp-vless/client-link.txt
chmod 600 /etc/l2tp-vless/client-link.txt

echo ""
echo "=============================================="
echo " 安装完成"
echo "=============================================="
echo "VLESS 入口（德国 VPS）： ${DE_IP}:${VLESS_PORT}"
echo "L2TP 隧道 IP：           ${PPP_IP:-未建立}"
echo "VLESS 出口 IP：          ${UK_IP}"
echo ""
echo "客户端链接："
echo "$LINK"
echo ""
echo "链接已保存到 /etc/l2tp-vless/client-link.txt"
echo "手动验证出口： curl --interface ${PPP_IF:-ppp0} https://ifconfig.me"
