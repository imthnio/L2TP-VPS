#!/bin/sh
# ============================================================
# vless-l2tp 一键安装脚本（小白版，节点搭建部分参考 dajianjiedian）
#
# 流程：
#   1. 先问 L2TP 服务器 / 用户名 / 密码（仅密码不回显）
#   2. 装依赖 → 写 L2TP 配置 → 拨号（拿 ppp0 与英国 IP）
#   3. 再问 VLESS 端口（手动输入，无默认值）
#      / 传输方式 / REALITY 伪装站（12 选 1）
#   4. 装 xray → 写配置 → 启动 → 输出客户端链接
#
# 出口：VLESS 出站默认走 L2TP 隧道（fwmark 策略路由）。
# 断网保护：table 100 里永远只有一条默认路由（IPv4 和 IPv6 各一条）——
#   隧道通时是 default dev ppp0，隧道断时是 prohibit default。
#   L2TP 一断（比如忘记续费），VLESS 出站直接被丢弃，
#   节点断网，绝不会落到德国 VPS 的 IP 上。
#   隧道恢复后自动恢复，不用重跑脚本。
#   （注意：整台 VPS 的默认路由不动，不然 L2TP 一断你连 SSH 都上不去。）
#
# 无终端时可用环境变量：
#   必填：L2TP_SERVER / L2TP_USER / L2TP_PASS / VLESS_PORT
#   可选：VLESS_UUID / TRANSPORT=reality|ws / REALITY_DEST / WS_PATH
# ============================================================
set -u

FW_MARK=100
RT_TABLE=100
LAC_NAME="uk"
NODE_DIR="/etc/l2tp-vless"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[注意]${NC} %s\n" "$1"; }
err()  { printf "${RED}[出错]${NC} %s\n" "$1"; }
step() { printf "\n${CYAN}${BOLD}%s${NC}\n" "$1"; }
die()  { err "$1"; exit 1; }

# ---------- 通用小工具（参考 dajianjiedian） ----------
rand_hex() { # rand_hex 字节数 -> 十六进制串
  od -An -tx1 -N"$1" /dev/urandom 2>/dev/null | tr -d ' \n'
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr 'A-Z' 'a-z' < /proc/sys/kernel/random/uuid | tr -d '\n'
  else
    rand_hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}

get_ip() { # 只取 IPv4 公网 IP，多个网站轮着试
  for _u in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
    _ip=$(curl -fsSL --max-time 10 -4 "$_u" 2>/dev/null | tr -d ' \r\n')
    if [ -n "$_ip" ]; then printf "%s" "$_ip"; return 0; fi
  done
  return 1
}

# gh_api_dl <仓库> <文件名> <输出路径>：走 GitHub API 下载 release 文件
gh_api_dl() {
  _gh_repo="$1"; _gh_asset="$2"; _gh_out="$3"
  _gh_rel=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${_gh_repo}/releases/latest" 2>/dev/null) || return 1
  [ -n "$_gh_rel" ] || return 1
  _gh_aid=$(printf "%s\n" "$_gh_rel" | grep -B10 -F "\"name\": \"${_gh_asset}\"" | grep '"id"' | tail -1 | grep -o '[0-9][0-9]*' | head -1)
  [ -n "$_gh_aid" ] || return 1
  curl -fSL --connect-timeout 20 --speed-time 30 --speed-limit 1000 --retry 2 --retry-delay 3 \
    -H "Accept: application/octet-stream" \
    -o "$_gh_out" "https://api.github.com/repos/${_gh_repo}/releases/assets/${_gh_aid}"
}

# pick_dldir：选磁盘上的下载目录（/tmp 可能是内存盘）
pick_dldir() {
  for _cand in /var/tmp "${HOME:-/root}" /tmp; do
    if [ -d "$_cand" ] && [ -w "$_cand" ]; then
      _dd="${_cand}/L2TP-VPS-dl"
      if mkdir -p "$_dd" 2>/dev/null; then
        printf "%s" "$_dd"
        return 0
      fi
    fi
  done
  return 1
}

# wait_for_port <端口> <超时秒>：硬检查端口真的在监听
wait_for_port() {
  _wp="$1"; _wtimeout="${2:-15}"
  _wtry=0
  while [ "$_wtry" -lt "$_wtimeout" ]; do
    if command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | grep -q ":${_wp} " && return 0
    elif command -v netstat >/dev/null 2>&1; then
      netstat -ltn 2>/dev/null | grep -q ":${_wp} " && return 0
    else
      return 0
    fi
    sleep 1
    _wtry=$((_wtry + 1))
  done
  return 1
}

# ---------- 安全的变量读写（避免 eval 注入，密码里有特殊字符也不怕） ----------
L2TP_SERVER="${L2TP_SERVER:-}"
L2TP_USER="${L2TP_USER:-}"
L2TP_PASS="${L2TP_PASS:-}"
VLESS_PORT="${VLESS_PORT:-}"
VLESS_UUID="${VLESS_UUID:-}"
TRANS_CHOICE="${TRANS_CHOICE:-}"
TRANSPORT="${TRANSPORT:-}"
REALITY_DEST="${REALITY_DEST:-}"
REALITY_CHOICE="${REALITY_CHOICE:-}"
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
    REALITY_CHOICE) printf '%s' "$REALITY_CHOICE" ;;
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
    REALITY_CHOICE) REALITY_CHOICE="$2" ;;
    WS_PATH)      WS_PATH="$2" ;;
    *) die "内部错误：未知变量 $1" ;;
  esac
}

ask_req() { # 必填项
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

ask_def() { # 有默认值的选项
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

ask_secret() { # 密码，输入不回显
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

ask_port() { # 端口：手动输入，无默认值；校验数字/范围/占用
  while :; do
    _cur="$(get_var "$1")"
    if [ "$TTY" = "1" ]; then
      printf '%s（纯数字，1-65535）: ' "$2"
      IFS= read -r _ans || _ans=""
      [ -z "$_ans" ] && _ans="$_cur"
    else
      _ans="$_cur"
    fi
    case "$_ans" in ''|*[!0-9]*)
      if [ "$TTY" = "1" ]; then echo "端口必须是纯数字，请重新输入"; continue; fi
      die "$2 无效（无终端时请用环境变量 $1 传入纯数字端口）" ;;
    esac
    if [ "$_ans" -lt 1 ] || [ "$_ans" -gt 65535 ]; then
      if [ "$TTY" = "1" ]; then echo "端口范围 1-65535，请重新输入"; continue; fi
      die "$2 超出范围 1-65535"
    fi
    if ss -lnt 2>/dev/null | grep -q ":${_ans} "; then
      if [ "$TTY" = "1" ]; then echo "端口 ${_ans} 已被占用，请换一个"; continue; fi
      die "端口 ${_ans} 已被占用"
    fi
    set_var "$1" "$_ans"
    break
  done
}

# ---------- 0. 必须是 root ----------
[ "$(id -u)" = "0" ] || die "请用 root 运行此脚本"

printf "\n${BOLD}==============================================${NC}\n"
printf "${BOLD}   L2TP+VPS：L2TP 拨号 + VLESS 节点${NC}\n"
printf "${BOLD}==============================================${NC}\n"
printf "出口默认走 L2TP 隧道；L2TP 一断节点直接断网，\n"
printf "绝不会落到德国 VPS 的 IP 上（断网保护）。\n"

if [ -f "$NODE_DIR/net.env" ]; then
  warn "检测到已经安装过节点，继续会覆盖重装。"
  if [ "$TTY" = "1" ]; then
    printf '继续重装吗？(y/n) [默认 y]: '
    IFS= read -r _re || _re=""
    [ -z "$_re" ] && _re="y"
    case "$_re" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
  else
    warn "无终端，默认继续覆盖重装"
  fi
fi

# ---------- 1. 第一阶段：L2TP 账号 ----------
step "[1/2] 先填 L2TP 账号（输完就开始拨号）"
ask_req    L2TP_SERVER "L2TP 服务器地址（IP 或域名）"
ask_req    L2TP_USER   "L2TP 用户名"
ask_secret L2TP_PASS   "L2TP 密码"

# ---------- 2. 装依赖（缺啥装啥） ----------
step "[准备] 检查系统工具…"
if [ -f /etc/alpine-release ]; then
  OS="alpine"
elif [ -f /etc/debian_version ]; then
  OS="debian"
else
  die "仅支持 Debian / Ubuntu / Alpine"
fi
_missing=""
command -v curl >/dev/null 2>&1 || _missing="$_missing curl"
command -v unzip >/dev/null 2>&1 || _missing="$_missing unzip"
command -v ss >/dev/null 2>&1 || _missing="$_missing iproute2"
command -v iptables >/dev/null 2>&1 || _missing="$_missing iptables"
command -v xl2tpd >/dev/null 2>&1 || _missing="$_missing xl2tpd"
command -v pppd >/dev/null 2>&1 || _missing="$_missing ppp"
if [ -n "$_missing" ]; then
  printf "正在安装缺失的软件包：%s（最多等几分钟）…\n" "$_missing"
  export DEBIAN_FRONTEND=noninteractive
  if [ "$OS" = "alpine" ]; then
    apk add --no-cache $_missing ca-certificates >/dev/null 2>&1
  else
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq $_missing ca-certificates >/dev/null 2>&1
  fi
  unset DEBIAN_FRONTEND
fi
for _b in curl unzip ss iptables xl2tpd pppd; do
  command -v "$_b" >/dev/null 2>&1 || die "缺少 $_b，自动安装失败，请手动安装后重试"
done
info "系统工具就绪"

# ---------- PPP 内核支持自检（小鸡能不能拨号就看这个） ----------
# 软件包是装得上的，但 /dev/ppp 得靠内核。容器型小鸡（OpenVZ/LXC）通常没有，
# 这里自动尝试加载模块、建设备节点，实在不行就直接报错，不让用户白填一堆信息。
if [ ! -c /dev/ppp ]; then
  info "没检测到 /dev/ppp，正在尝试自动启用 PPP 内核支持…"
  if command -v modprobe >/dev/null 2>&1; then
    modprobe ppp_generic 2>/dev/null || true
    modprobe ppp_async 2>/dev/null || true
    sleep 1
  fi
  [ -c /dev/ppp ] || mknod /dev/ppp c 108 0 2>/dev/null || true
fi
if [ ! -c /dev/ppp ]; then
  die "你的 VPS 不支持 PPP（/dev/ppp 不存在且无法创建）。

这通常是 OpenVZ / LXC 这类容器型小鸡：内核和母鸡共用，
装不了 PPP 模块，L2TP 拨号跑不起来。

解决办法：换一台 KVM / Xen / VMware 的 VPS（买的时候看虚拟化类型），
然后重跑这个脚本。"
fi
info "PPP 内核支持正常"

# ---------- 3. L2TP 配置 ----------
step "[拨号] 配置 L2TP…"

# 记录原始默认路由：L2TP 服务器必须走这条，否则隧道自环
DEF_GW="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
DEF_IF="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
[ -n "$DEF_GW" ] && [ -n "$DEF_IF" ] || die "获取默认路由失败"
info "原始网关：$DEF_GW，经由 $DEF_IF"
mkdir -p "$NODE_DIR"
printf 'GW=%s\nIF=%s\nSERVER=%s\n' "$DEF_GW" "$DEF_IF" "$L2TP_SERVER" > "$NODE_DIR/net.env"

# 保路由脚本：L2TP 服务器 IP 始终走原始网关
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

# 断网保护脚本：table 100 里永远只有一条默认路由
cat > /usr/local/sbin/l2tp-vless-killswitch.sh <<EOF
#!/bin/sh
# 断网保护：fwmark ${FW_MARK} 的包只查 table ${RT_TABLE}。
# 隧道通 → default dev pppX；隧道断 → prohibit default 直接丢弃。
# L2TP 一断（比如忘记续费），VLESS 出站直接断网，
# 绝不会落到德国 VPS 的 IP 上。隧道恢复后自动恢复。
ip rule list 2>/dev/null | grep -q "fwmark 0x64 lookup ${RT_TABLE}" \
  || ip rule add fwmark ${FW_MARK} table ${RT_TABLE} 2>/dev/null || true
ip route show table ${RT_TABLE} 2>/dev/null | grep -q "^default" \
  || ip route add prohibit default table ${RT_TABLE} 2>/dev/null || true
# IPv6 同样处理：不写 -6 的 ip rule / ip route 只管 IPv4。
# 不加这两行，IPv6 流量会绕过隧道，断网保护也管不住它。
ip -6 rule list 2>/dev/null | grep -q "fwmark 0x64 lookup ${RT_TABLE}" \
  || ip -6 rule add fwmark ${FW_MARK} table ${RT_TABLE} 2>/dev/null || true
ip -6 route show table ${RT_TABLE} 2>/dev/null | grep -q "^default" \
  || ip -6 route add prohibit default table ${RT_TABLE} 2>/dev/null || true
EOF
chmod +x /usr/local/sbin/l2tp-vless-killswitch.sh

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

# ppp 钩子：拨号成功把 table 100 切到 ppp；断开换回 prohibit
mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d
cat > /etc/ppp/ip-up.d/10-vless-egress <<EOF
#!/bin/sh
# \$1=ppp 接口名。先确保断网保护就位，再把 table ${RT_TABLE} 切到本接口。
IF="\$1"
[ -n "\$IF" ] || exit 0
/usr/local/sbin/l2tp-vless-killswitch.sh
ip route replace default dev "\$IF" table ${RT_TABLE}
# IPv6：如果隧道分到了公网 IPv6，打标的 IPv6 包也走本接口；
# 没分到就保持 prohibit——宁可 IPv6 不通，也不让它从 VPS 本机 IPv6 漏出去。
_HAS_V6=0
for _w in \$(seq 1 10); do
  if ip -6 addr show dev "\$IF" scope global 2>/dev/null | grep -q "inet6"; then _HAS_V6=1; break; fi
  sleep 1
done
if [ "\$_HAS_V6" = "1" ]; then
  ip -6 route replace default dev "\$IF" table ${RT_TABLE} 2>/dev/null || true
else
  ip -6 route replace prohibit default table ${RT_TABLE} 2>/dev/null || \
  ip -6 route add prohibit default table ${RT_TABLE} 2>/dev/null || true
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -t mangle -C OUTPUT -o "\$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  iptables -t mangle -A OUTPUT -o "\$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
# IPv6 的 MSS 钳制（IPv6 路由器不分片，PMTU 黑洞更致命）
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t mangle -C OUTPUT -o "\$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  ip6tables -t mangle -A OUTPUT -o "\$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
EOF
chmod +x /etc/ppp/ip-up.d/10-vless-egress

cat > /etc/ppp/ip-down.d/10-vless-egress <<EOF
#!/bin/sh
# 隧道断开：table ${RT_TABLE} 换回 prohibit，出站直接丢弃（断网保护）
ip route replace prohibit default table ${RT_TABLE} 2>/dev/null || \
ip route add prohibit default table ${RT_TABLE} 2>/dev/null || true
# IPv6 同样换回 prohibit：隧道一断，IPv6 出站也直接丢弃
ip -6 route replace prohibit default table ${RT_TABLE} 2>/dev/null || \
ip -6 route add prohibit default table ${RT_TABLE} 2>/dev/null || true
EOF
chmod +x /etc/ppp/ip-down.d/10-vless-egress

# 开机自启：保路由 → 断网保护 → xl2tpd → 自动拨号
if [ "$OS" = "alpine" ]; then
  cat > /etc/local.d/l2tp-vless.start <<EOF
#!/bin/sh
# 开机：先保住 L2TP 服务器路由，上断网保护，再自动拨号
/usr/local/sbin/l2tp-vless-route.sh
/usr/local/sbin/l2tp-vless-killswitch.sh
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
Description=Keep L2TP server route via original gateway + killswitch
Before=xl2tpd.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/l2tp-vless-route.sh
ExecStart=/usr/local/sbin/l2tp-vless-killswitch.sh
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

# ---------- 4. 拨号 ----------
step "[拨号] 正在拨号…"
/usr/local/sbin/l2tp-vless-route.sh
/usr/local/sbin/l2tp-vless-killswitch.sh
modprobe ppp_generic 2>/dev/null || true
if [ "$OS" = "alpine" ]; then
  rc-update add xl2tpd default >/dev/null 2>&1 || true
  rc-service xl2tpd restart >/dev/null 2>&1 || rc-service xl2tpd start >/dev/null 2>&1
else
  systemctl enable xl2tpd >/dev/null 2>&1 || true
  systemctl restart xl2tpd >/dev/null 2>&1
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
  warn "脚本继续安装 VLESS（断网保护已生效，出站不会走德国 IP）"
  warn "L2TP 通之后出口自动走隧道，不用重跑脚本"
else
  PPP_IP="$(ip -4 -o addr show dev "$PPP_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  info "隧道已建立：$PPP_IF，IP = ${PPP_IP:-未知}"
fi

# ---------- 5. 第二阶段：VLESS 配置 ----------
step "[2/2] 隧道就绪，下面配置 VLESS 节点"
ask_port VLESS_PORT "VLESS 端口"

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
  if [ -z "$REALITY_DEST" ]; then
    if [ "$TTY" = "1" ]; then
      echo ""
      echo "REALITY 目标网站（伪装对象）："
      echo "  1) www.samsung.com                     2018-2026 零干扰，最稳"
      echo "  2) www.cisco.com                       2026 年 0% 干扰，TLS 极稳"
      echo "  3) itunes.apple.com                    2025-2026 全干净"
      echo "  4) www.python.org                      技术站，小众不扎眼"
      echo "  5) m.media-amazon.com                  零干扰记录"
      echo "  6) images-na.ssl-images-amazon.com      图片 CDN，流量普通"
      echo "  7) download-installer.cdn.mozilla.net  火狐下载站"
      echo "  8) www.lovelive-anime.jp               日本动画官网，小厂气质"
      echo "  9) academy.nvidia.com"
      echo " 10) lol.secure.dyn.riotcdn.net          游戏补丁 CDN"
      echo " 11) s0.awsstatic.com"
      echo " 12) www.amd.com                         有 3% 干扰率，只当备胎"
      ask_def REALITY_CHOICE "请选择 [1-12]" "1"
      case "$REALITY_CHOICE" in
        1)  _rd="www.samsung.com" ;;
        2)  _rd="www.cisco.com" ;;
        3)  _rd="itunes.apple.com" ;;
        4)  _rd="www.python.org" ;;
        5)  _rd="m.media-amazon.com" ;;
        6)  _rd="images-na.ssl-images-amazon.com" ;;
        7)  _rd="download-installer.cdn.mozilla.net" ;;
        8)  _rd="www.lovelive-anime.jp" ;;
        9)  _rd="academy.nvidia.com" ;;
        10) _rd="lol.secure.dyn.riotcdn.net" ;;
        11) _rd="s0.awsstatic.com" ;;
        12) _rd="www.amd.com" ;;
        *)  _rd="www.samsung.com" ;;
      esac
      REALITY_DEST="${_rd}:443"
    else
      REALITY_DEST="www.samsung.com:443"
    fi
  fi
else
  ask_def WS_PATH "WebSocket 路径" "/ws"
  case "$WS_PATH" in /*) ;; *) WS_PATH="/$WS_PATH" ;; esac
fi

# ---------- 6. 下载 xray（参考 dajianjiedian：API 路线优先，直链兜底） ----------
step "[下载] 获取 Xray 内核…"
case "$(uname -m)" in
  x86_64|amd64) XARCH="64" ;;
  aarch64|arm64) XARCH="arm64-v8a" ;;
  *) die "不支持的 CPU 架构：$(uname -m)" ;;
esac
if [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
  info "Xray 已存在，直接用现有的：$($XRAY_BIN version 2>/dev/null | head -1)"
else
  DL_DIR=$(pick_dldir) || die "找不到可写的下载目录"
  _asset="Xray-linux-${XARCH}.zip"
  if [ -s "$DL_DIR/xray.zip" ] && unzip -t -q "$DL_DIR/xray.zip" >/dev/null 2>&1; then
    info "安装包已在本地，直接使用（跳过下载）"
  else
    rm -f "$DL_DIR/xray.zip"
    _ok=0
    info "尝试下载：GitHub API"
    if gh_api_dl "XTLS/Xray-core" "$_asset" "$DL_DIR/xray.zip"; then
      _ok=1
    else
      warn "API 路线失败，换 github.com 直链试试…"
      rm -f "$DL_DIR/xray.zip"
      _ver=$(curl -fsSL --max-time 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
      for _url in ${_ver:+https://github.com/XTLS/Xray-core/releases/download/v${_ver}/Xray-linux-${XARCH}.zip} \
                 "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XARCH}.zip"; do
        [ -z "$_url" ] && continue
        info "尝试下载：$_url"
        if curl -fSL --connect-timeout 20 --speed-time 30 --speed-limit 1000 --retry 2 --retry-delay 3 \
             -o "$DL_DIR/xray.zip" "$_url"; then
          _ok=1
          break
        fi
        warn "这个地址下载失败，换下一个试试…"
        rm -f "$DL_DIR/xray.zip"
      done
    fi
    [ "$_ok" -eq 1 ] || die "Xray 下载失败：到 GitHub 的网络不稳定，稍等几分钟后重跑脚本试试"
  fi
  unzip -t -q "$DL_DIR/xray.zip" >/dev/null 2>&1 || die "下载的安装包已损坏，请重跑脚本重新下载"
  rm -rf "$DL_DIR/xray-dl" && mkdir -p "$DL_DIR/xray-dl"
  unzip -o "$DL_DIR/xray.zip" -d "$DL_DIR/xray-dl" xray || die "解压失败"
  [ -s "$DL_DIR/xray-dl/xray" ] || die "解压后没找到 xray 文件"
  install -m 0755 "$DL_DIR/xray-dl/xray" "$XRAY_BIN" || die "安装 Xray 失败"
  "$XRAY_BIN" version >/dev/null 2>&1 || die "装完的 Xray 跑不起来，安装包可能有问题"
  rm -rf "$DL_DIR"
  info "Xray 安装成功：$($XRAY_BIN version 2>/dev/null | head -1)"
fi

# ---------- 7. 写 xray 配置（UUID 自动生成；出站打标走 L2TP） ----------
step "[配置] 写入配置…"
[ -n "$VLESS_UUID" ] || VLESS_UUID="$(gen_uuid)"
[ -n "$VLESS_UUID" ] || die "UUID 生成失败"
if [ "$TRANSPORT" = "reality" ]; then
  _kp="$($XRAY_BIN x25519 2>/dev/null)"
  PRIV_KEY="$(printf '%s' "$_kp" | awk '/Private key:/{print $3}')"
  PUB_KEY="$(printf '%s' "$_kp" | awk '/Public key:/{print $3}')"
  [ -n "$PRIV_KEY" ] && [ -n "$PUB_KEY" ] || die "REALITY 密钥生成失败"
  SHORT_ID="$(rand_hex 8)"
  SNI="${REALITY_DEST%%:*}"
fi

mkdir -p "$XRAY_CONF_DIR"
if [ "$TRANSPORT" = "reality" ]; then
  cat > "$XRAY_CONF_DIR/config.json" <<EOF
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
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
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
  cat > "$XRAY_CONF_DIR/config.json" <<EOF
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
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
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
"$XRAY_BIN" -test -config "$XRAY_CONF_DIR/config.json" >/dev/null 2>&1 \
  || die "配置文件校验没通过，请截图发我看看"
info "配置文件校验通过"

# ---------- 8. xray 服务 + 硬检查端口 ----------
step "[服务] 启动 xray…"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray VLESS (出口经 L2TP，断网保护)
After=network.target
[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} -config ${XRAY_CONF_DIR}/config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray >/dev/null 2>&1
  sleep 1
  if systemctl is-active --quiet xray; then
    info "xray 已启动，并设为开机自启"
  else
    warn "xray 好像没起来，运行 systemctl status xray 看看原因"
  fi
elif command -v rc-service >/dev/null 2>&1; then
  cat > /etc/init.d/xray <<RCEOF
#!/sbin/openrc-run
name="xray"
description="Xray VLESS (出口经 L2TP，断网保护)"
command="${XRAY_BIN}"
command_args="-config ${XRAY_CONF_DIR}/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
retry="SIGTERM/5/SIGKILL/5"
depend() { need net; after xl2tpd; }
start_pre() {
    if [ -f "\$pidfile" ]; then
        _ppid=\$(cat "\$pidfile" 2>/dev/null)
        if [ -n "\$_ppid" ] && ! kill -0 "\$_ppid" 2>/dev/null; then
            rm -f "\$pidfile"
        fi
    fi
    checkpath -f -m 0644 -o root:root "\$output_log"
}
RCEOF
  chmod +x /etc/init.d/xray
  rc-update add xray default >/dev/null 2>&1
  rc-service xray zap >/dev/null 2>&1
  rc-service xray start >/dev/null 2>&1
  sleep 1
  if rc-service xray status >/dev/null 2>&1; then
    info "xray 已启动，并设为开机自启"
  else
    warn "xray 好像没起来，运行 rc-service xray status 看看原因"
  fi
else
  warn "没找到 systemd/OpenRC，改用后台方式启动（重启后需手动再跑一次脚本）"
  pkill -f "${XRAY_BIN} -config ${XRAY_CONF_DIR}/config.json" >/dev/null 2>&1
  nohup "$XRAY_BIN" -config "$XRAY_CONF_DIR/config.json" >/var/log/xray.log 2>&1 &
  sleep 1
  info "xray 已在后台启动"
fi

# 硬检查：端口必须真的在监听（服务显示已启动不代表真在工作）
if wait_for_port "$VLESS_PORT" 15; then
  info "端口 $VLESS_PORT/tcp 已在监听，服务真正跑起来了"
else
  die "服务没能监听端口 $VLESS_PORT：节点装坏了。请先运行 systemctl status xray（或 rc-service xray status）看原因，修好再重跑脚本"
fi

# ---------- 9. 放行端口 ----------
step "[网络] 放行端口…"
echo "$VLESS_PORT tcp" > "$NODE_DIR/fw_info"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$VLESS_PORT"/tcp >/dev/null 2>&1 && info "ufw 已放行 $VLESS_PORT/tcp"
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$VLESS_PORT"/tcp >/dev/null 2>&1
  firewall-cmd --reload >/dev/null 2>&1 && info "firewalld 已放行 $VLESS_PORT/tcp"
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "$VLESS_PORT" -j ACCEPT >/dev/null 2>&1 \
    || iptables -I INPUT -p tcp --dport "$VLESS_PORT" -j ACCEPT >/dev/null 2>&1
fi
warn "如果是云服务器（阿里云/腾讯云/AWS 等），还去控制台安全组放行 $VLESS_PORT 端口"

# ---------- 10. 断网保护确认 + 出口验证 ----------
step "[保护] 检查断网保护…"
/usr/local/sbin/l2tp-vless-killswitch.sh
printf "当前 table ${RT_TABLE} 路由（IPv4）：\n"
ip route show table "$RT_TABLE" 2>/dev/null | sed 's/^/  /'
printf "当前 table ${RT_TABLE} 路由（IPv6）：\n"
ip -6 route show table "$RT_TABLE" 2>/dev/null | sed 's/^/  /'
if ip route show table "$RT_TABLE" 2>/dev/null | grep -q "dev ppp"; then
  info "隧道正常，VLESS 出站走 L2TP"
else
  warn "隧道未建立：table ${RT_TABLE} 为 prohibit，出站直接丢弃，不会走德国 IP（这就是断网保护）"
fi
PPP_IP6=""
UK_IP6=""
if [ -n "$PPP_IF" ]; then
  PPP_IP6="$(ip -6 -o addr show dev "$PPP_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  if [ -n "$PPP_IP6" ]; then
    info "隧道 IPv6：$PPP_IP6（IPv6 出站同样走 L2TP，受断网保护）"
    UK_IP6="$(curl -6 --interface "$PPP_IF" -s --max-time 15 https://ifconfig.me 2>/dev/null || echo "")"
    if [ -n "$UK_IP6" ]; then
      info "出口 IPv6：$UK_IP6（走英国 L2TP，自动识别）"
    else
      warn "隧道有 IPv6 地址但连不通公网，IPv6 出口不可用"
    fi
  else
    warn "隧道没有分到公网 IPv6：IPv6 出站将被丢弃，不会从德国 IP 漏出去（这就是断网保护）"
  fi
fi

DE_IP="$(get_ip || echo "")"
[ -n "$DE_IP" ] || DE_IP="<德国VPS公网IP>"
UK_IP=""
if [ -n "$PPP_IF" ]; then
  UK_IP="$(curl --interface "$PPP_IF" -s --max-time 15 https://ifconfig.me 2>/dev/null || echo "")"
fi
[ -n "$UK_IP" ] || UK_IP="<待 L2TP 拨号成功后自动生效>"

# ---------- 11. 生成链接 + 保存节点信息 ----------
step "[完成] 生成你的节点…"
if [ "$TRANSPORT" = "reality" ]; then
  LINK="vless://${VLESS_UUID}@${DE_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#uk-egress"
  PROTO_NAME="VLESS + REALITY + Vision"
else
  _p="$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')"
  LINK="vless://${VLESS_UUID}@${DE_IP}:${VLESS_PORT}?encryption=none&type=ws&path=${_p}#uk-egress"
  PROTO_NAME="VLESS + WebSocket"
fi

{
  printf "==============================================\n"
  printf " 你的节点（复制下面整行，粘贴到客户端导入）\n"
  printf "==============================================\n"
  printf "%s\n" "$LINK"
  printf -- "----------------------------------------------\n"
  printf "协议: %s\n" "$PROTO_NAME"
  printf "地址: %s\n" "$DE_IP"
  printf "端口: %s\n" "$VLESS_PORT"
  printf "UUID: %s\n" "$VLESS_UUID"
  if [ "$TRANSPORT" = "reality" ]; then
    printf "伪装域名: %s\n" "$SNI"
  else
    printf "WS 路径: %s\n" "$WS_PATH"
  fi
  printf "出口 IP: %s（走英国 L2TP）\n" "$UK_IP"
  if [ -n "$UK_IP6" ]; then
    printf "出口 IPv6: %s（走英国 L2TP）\n" "$UK_IP6"
  else
    printf "出口 IPv6: 无（已禁用，不会从德国 IP 漏出）\n"
  fi
  printf "断网保护: L2TP 断开后节点直接断网，不会用德国 IP 出口\n"
  printf -- "----------------------------------------------\n"
  printf "==============================================\n"
}

# ---------- 12. 显示结果 ----------
printf "\n"
printf "\n${GREEN}${BOLD}安装完成！${NC}把上面那行链接复制到客户端就能用了。\n"
printf "VLESS 入口：${BOLD}%s:%s${NC}（德国 VPS）\n" "$DE_IP" "$VLESS_PORT"
printf "VLESS 出口：${BOLD}%s${NC}（英国 L2TP）\n" "$UK_IP"
