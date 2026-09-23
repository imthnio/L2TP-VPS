#!/bin/sh
# ============================================================
# L2TP 一键安装脚本（小白版）：拨号 + 全机策略路由 + 断网保护
#
# 流程：
#   1. 问 L2TP 服务器 / 用户名 / 密码（仅密码不回显）
#   2. 装依赖 → 写全机断网保护和 L2TP 配置 → 拨号 → 验证出口
#
# 出口：安装完成后，普通的全机出站使用 A&A L2TP。
# 例外：L2TP 接入服务器和以 VPS 原生地址为源的管理连接回包走原生线路。
# 断网保护：table 100 保留高 metric 的 prohibit default；PPP 通时另加低
# metric 默认路由。PPP 消失时不回退原生默认路由。原生 main 默认路由保留。
#
# 无终端时可用环境变量：
#   必填：L2TP_SERVER / L2TP_USER / L2TP_PASS
# ============================================================
set -u

RT_TABLE=100
LAC_NAME="aa"
NODE_DIR="/etc/l2tp-vless"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[注意]${NC} %s\n" "$1"; }
err()  { printf "${RED}[出错]${NC} %s\n" "$1"; }
step() { printf "\n${CYAN}${BOLD}%s${NC}\n" "$1"; }
die()  { err "$1"; exit 1; }

# ---------- 通用小工具 ----------

# _fix_ubuntu_eol_source：Ubuntu 旧版本停止支持后，官方源下架该版本的索引，
# apt-get update 会 404 失败。确认是 EOL（官方源上已没有该版本的 Release 文件）
# 才把软件源切到 old-releases.ubuntu.com；成功切换返回 0，否则返回 1
_fix_ubuntu_eol_source() {
  [ -f /etc/os-release ] || return 1
  grep -qi '^ID=ubuntu' /etc/os-release || return 1
  _codename=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d ' ')
  [ -n "$_codename" ] || return 1
  # 官方源上还能拿到该版本的 Release 文件 → 不是 EOL 问题，不动软件源
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 10 -o /dev/null "http://archive.ubuntu.com/ubuntu/dists/${_codename}/Release" 2>/dev/null && return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=10 -O /dev/null "http://archive.ubuntu.com/ubuntu/dists/${_codename}/Release" 2>/dev/null && return 1
  else
    return 1
  fi
  warn "检测到 Ubuntu ${_codename} 已停止支持，软件源切换到 old-releases…"
  sed -i -E 's#https?://(archive|security)\.ubuntu\.com#http://old-releases.ubuntu.com#g' /etc/apt/sources.list 2>/dev/null
  if [ -d /etc/apt/sources.list.d ]; then
    for _f in /etc/apt/sources.list.d/*.list; do
      [ -f "$_f" ] || continue
      sed -i -E 's#https?://(archive|security)\.ubuntu\.com#http://old-releases.ubuntu.com#g' "$_f" 2>/dev/null
    done
  fi
  return 0
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

if [ -t 0 ]; then TTY=1; else TTY=0; fi

get_var() {
  case "$1" in
    L2TP_SERVER)  printf '%s' "$L2TP_SERVER" ;;
    L2TP_USER)    printf '%s' "$L2TP_USER" ;;
    L2TP_PASS)    printf '%s' "$L2TP_PASS" ;;
  esac
}

set_var() {
  case "$1" in
    L2TP_SERVER)  L2TP_SERVER="$2" ;;
    L2TP_USER)    L2TP_USER="$2" ;;
    L2TP_PASS)    L2TP_PASS="$2" ;;
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

# ---------- 0. 必须是 root ----------
[ "$(id -u)" = "0" ] || die "请用 root 运行此脚本"

printf "\n${BOLD}==============================================${NC}\n"
printf "${BOLD}   L2TP+VPS：L2TP 拨号 + 全机走隧道${NC}\n"
printf "${BOLD}==============================================${NC}\n"
printf "安装完成后，普通全机出站走 A&A L2TP；断线后阻断。\n"
printf "L2TP 接入流量和原生 IP 的管理连接回包保留原生线路。\n"

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

# ---------- 1. L2TP 账号 ----------
step "先填 L2TP 账号（输完就开始拨号）"
ask_req    L2TP_SERVER "L2TP 服务器地址（IP 或域名）"
ask_req    L2TP_USER   "L2TP 用户名"
ask_secret L2TP_PASS   "L2TP 密码"
case "$L2TP_USER" in ''|*[!A-Za-z0-9@._+-]*) die "L2TP 用户名只能包含英文字母、数字、@ . _ + -" ;; esac
_PASS_SINGLE_LINE="$(printf '%s' "$L2TP_PASS" | tr -d '\r\n')"
[ "$L2TP_PASS" = "$_PASS_SINGLE_LINE" ] || die "L2TP 密码不能包含换行符"

# ---------- 2. 装依赖（缺啥装啥） ----------
step "[准备] 检查系统工具…"
if [ -f /etc/alpine-release ]; then
  OS="alpine"
elif [ -f /etc/debian_version ]; then
  OS="debian"
else
  die "仅支持 Debian / Ubuntu / Alpine"
fi
if [ "$OS" = alpine ]; then
  command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 || die "Alpine 需要 OpenRC 管理服务"
else
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || die "Debian / Ubuntu 需要正在运行的 systemd"
fi
_missing=""
command -v curl >/dev/null 2>&1 || _missing="$_missing curl"
command -v ss >/dev/null 2>&1 || _missing="$_missing iproute2"
command -v iptables >/dev/null 2>&1 || _missing="$_missing iptables"
command -v xl2tpd >/dev/null 2>&1 || _missing="$_missing xl2tpd"
command -v pppd >/dev/null 2>&1 || _missing="$_missing ppp"
# _apt_retry：apt 自己重试（锁被占、网络抖动）。每轮等锁最多 2 分钟，
# 等的时候打印进度，共 8 轮（约 18 分钟），全程不用人管
_apt_retry() {
  _ar=0
  while [ "$_ar" -lt 8 ]; do
    _ar=$((_ar + 1))
    if "$@" >>"$_PKG_LOG" 2>&1; then return 0; fi
    warn "还在排队等系统后台更新释放锁（第 $_ar 次等待）…"
    sleep 20
  done
  return 1
}

if [ -n "$_missing" ]; then
  printf "正在安装缺失的软件包：%s…\n" "$_missing"
  printf "（刚装完的系统后台在自动更新，脚本会自动排队等，屏幕会打印等待进度，不用管它）\n"
  export DEBIAN_FRONTEND=noninteractive
  # 软件包管理器的输出记到日志里：实在装不上时才把报错打印出来
  _PKG_LOG="/tmp/l2tp-vps-pkg.log"
  : > "$_PKG_LOG" 2>/dev/null
  if [ "$OS" = "alpine" ]; then
    apk add --no-cache $_missing ca-certificates >>"$_PKG_LOG" 2>&1
  else
    # DPkg::Lock::Timeout：开机自动更新占着 dpkg 锁时排队等，不直接报错
    if ! _apt_retry apt-get -o DPkg::Lock::Timeout=120 update -qq; then
      # Ubuntu 旧版本停止支持后官方源 404，修源后再试
      _fix_ubuntu_eol_source
      _apt_retry apt-get -o DPkg::Lock::Timeout=120 update -qq
    fi
    _apt_retry apt-get -o DPkg::Lock::Timeout=120 install -y -qq $_missing ca-certificates
  fi
  unset DEBIAN_FRONTEND
fi
for _b in curl ss iptables xl2tpd pppd; do
  if ! command -v "$_b" >/dev/null 2>&1; then
    # 装不上多半是压根没网（软件源都连不上），先测一下再报错，
    # 免得让人去手动 apt-get（没网时手动也一样装不上）
    if ! curl -fsSL --max-time 10 -o /dev/null "http://archive.ubuntu.com/ubuntu/" 2>/dev/null \
       && ! curl -kfsSL --max-time 10 -o /dev/null "https://1.1.1.1" 2>/dev/null; then
      die "软件包 $_b 安装失败：VPS 当前连不上软件源（没网）。

如果这台机器正在走 A&A 隧道上网，多半是隧道不通——先让隧道通了再重跑脚本。
这时候手动 apt-get install 也一样装不上，不是少敲了命令。"
    fi
    _PKG_TAIL="$(tail -6 /tmp/l2tp-vps-pkg.log 2>/dev/null)"
    die "缺少 $_b，自动安装失败。软件源报错如下：
${_PKG_TAIL:-（无日志输出）}
把上面几行截图发出来，我看下怎么修。"
  fi
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

# 记录原生网络；隧道包和通过原生 IP 进入的管理连接需要这条路径。
DEF_ROUTE="$(ip -4 route show default table main 2>/dev/null | head -1)"
DEF_GW="$(printf '%s\n' "$DEF_ROUTE" | awk '{for(i=1;i<NF;i++) if($i=="via") {print $(i+1); exit}}')"
DEF_IF="$(printf '%s\n' "$DEF_ROUTE" | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')"
[ -n "$DEF_IF" ] || die "找不到原生 IPv4 默认路由；请先确认 VPS 网络正常"
NATIVE_IP="$(ip -4 -o addr show dev "$DEF_IF" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
[ -n "$NATIVE_IP" ] || die "找不到原生网卡的 IPv4 地址"
case "$L2TP_SERVER" in
  ''|*[!A-Za-z0-9.-]*) die "L2TP 服务器只能填写域名或 IPv4 地址" ;;
esac
if printf '%s\n' "$L2TP_SERVER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  SERVER_IP="$L2TP_SERVER"
else
  SERVER_IP="$(getent ahostsv4 "$L2TP_SERVER" 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')"
  [ -n "$SERVER_IP" ] || SERVER_IP="$(getent hosts "$L2TP_SERVER" 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')"
  [ -n "$SERVER_IP" ] || SERVER_IP="$(nslookup -type=A "$L2TP_SERVER" 2>/dev/null | awk '/^Name:/ {answer=1} answer && /^Address:/ && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $2; exit}')"
fi
[ -n "$SERVER_IP" ] || die "无法解析 L2TP 服务器的 IPv4 地址"
ip -4 route get "$SERVER_IP" >/dev/null 2>&1 || die "L2TP 服务器 IPv4 地址无效或不可达"
NATIVE_PUBLIC_IP="$NATIVE_IP"
info "原生网卡：$DEF_IF；L2TP 服务器 IPv4：$SERVER_IP"
mkdir -p "$NODE_DIR" /usr/local/sbin
printf 'GW=%s\nIF=%s\nNATIVE_IP=%s\nSERVER_IP=%s\n' "$DEF_GW" "$DEF_IF" "$NATIVE_IP" "$SERVER_IP" > "$NODE_DIR/net.env"
ip -6 -o addr show dev "$DEF_IF" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' > "$NODE_DIR/native-v6.txt"
chmod 600 "$NODE_DIR/net.env" "$NODE_DIR/native-v6.txt"

# 先建立永久的禁止路由，再建立优先于主路由表的规则。
# PPP 路由用较低 metric 并与禁止路由共存；接口意外消失也不会回落到原生出口。
cat > /usr/local/sbin/l2tp-vless-killswitch.sh <<'EOF'
#!/bin/sh
set -eu
. /etc/l2tp-vless/net.env
ip -4 route replace prohibit default metric 42700 table 100
# 旧版安装器使用无 metric 的禁止路由；重装时移除它，否则会压过 PPP 路由。
if ip -4 route show table 100 | grep -qx 'prohibit default'; then
  ip -4 route del prohibit default metric 0 table 100
fi
if [ -e /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != 1 ]; then
  ip -6 route replace prohibit default metric 42700 table 100
  if ip -6 route show table 100 | grep -qx 'prohibit default'; then
    ip -6 route del prohibit default metric 0 table 100
  fi
fi
# 原生 IP 的回包保留原生路径，避免 SSH/控制台连接被 PPP 非对称路由切断。
if ! ip -4 rule show | grep -Eq "^9000:.*from $NATIVE_IP([ /]|$).*lookup main"; then
  ! ip -4 rule show | grep -q '^9000:' || { echo "IPv4 规则优先级 9000 被占用" >&2; exit 1; }
  ip -4 rule add pref 9000 from "$NATIVE_IP/32" table main
fi
if [ -f /etc/l2tp-vless/native-v6.txt ]; then
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    if ! ip -6 rule show | grep -F "from $addr lookup main" >/dev/null; then
      ip -6 rule add pref 9000 from "$addr/128" table main
    fi
  done < /etc/l2tp-vless/native-v6.txt
fi
if ! ip -4 rule show | grep -Eq '^10000:.*lookup 100'; then
  ! ip -4 rule show | grep -q '^10000:' || { echo "IPv4 规则优先级 10000 被占用" >&2; exit 1; }
  ip -4 rule add pref 10000 table 100
fi
if [ -e /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != 1 ]; then
  if ! ip -6 rule show | grep -Eq '^10000:.*lookup 100'; then
    ! ip -6 rule show | grep -q '^10000:' || { echo "IPv6 规则优先级 10000 被占用" >&2; exit 1; }
    ip -6 rule add pref 10000 table 100
  fi
fi
ip -4 route show table 100 | grep -q '^prohibit default' || { echo "IPv4 禁止路由未生效" >&2; exit 1; }
EOF
chmod 700 /usr/local/sbin/l2tp-vless-killswitch.sh

cat > /usr/local/sbin/l2tp-vless-route.sh <<'EOF'
#!/bin/sh
set -eu
. /etc/l2tp-vless/net.env
# 更新原生网关，但保持安装时固定的管理地址和 A&A 接入 IP。
line="$(ip -4 route show default table main 2>/dev/null | awk '$0 !~ / dev ppp/ {print; exit}')"
if [ -n "$line" ]; then
  current_if="$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  current_gw="$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="via") {print $(i+1); exit}}')"
  if [ "$current_if" = "$IF" ]; then GW="$current_gw"; fi
fi
if [ -n "$GW" ]; then
  ip -4 route replace "$SERVER_IP/32" via "$GW" dev "$IF" table 100
else
  ip -4 route replace "$SERVER_IP/32" dev "$IF" table 100
fi
EOF
chmod 700 /usr/local/sbin/l2tp-vless-route.sh

# A&A 的 PPP 用户名/密码。接入点使用安装时解析出的 IPv4，避免断线时 DNS 被保护规则阻断。
mkdir -p /etc/xl2tpd /etc/ppp
for _existing in /etc/xl2tpd/xl2tpd.conf /etc/ppp/chap-secrets; do
  if [ -f "$_existing" ] && [ ! -f "$NODE_DIR/$(basename "$_existing").before-l2tp-vless" ]; then
    cp -p "$_existing" "$NODE_DIR/$(basename "$_existing").before-l2tp-vless" || die "备份现有 PPP 配置失败"
    chmod 600 "$NODE_DIR/$(basename "$_existing").before-l2tp-vless"
  fi
done
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]

[lac $LAC_NAME]
lns = $SERVER_IP
redial = yes
redial timeout = 10
ppp debug = no
pppoptfile = /etc/ppp/options.l2tp-vless
refuse pap = yes
length bit = yes
EOF
cat > /etc/ppp/options.l2tp-vless <<EOF
ipcp-accept-local
ipcp-accept-remote
refuse-eap
noccp
noauth
nodefaultroute
nobsdcomp
nodeflate
novj
novjccomp
lcp-echo-interval 20
lcp-echo-failure 3
mtu 1400
mru 1400
name $L2TP_USER
EOF
# pppd 的 secrets 文件使用双引号；转义引号和反斜杠。
_ESC_USER="$(printf '%s' "$L2TP_USER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
_ESC_PASS="$(printf '%s' "$L2TP_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '"%s" * "%s" *\n' "$_ESC_USER" "$_ESC_PASS" > /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets /etc/ppp/options.l2tp-vless

mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d
cat > /etc/ppp/ip-up.d/10-vless-egress <<'EOF'
#!/bin/sh
IF="${1:-}"
[ -n "$IF" ] || exit 0
/usr/local/sbin/l2tp-vless-killswitch.sh || exit 1
ip -4 route replace default dev "$IF" metric 100 table 100 || exit 1
# IPv6CP 常比 IPCP 晚几秒才给 PPP 口分配全局地址：轮询等最多 10 秒再下结论。
# 查一次就判的话，A&A 分了 IPv6 也走不上隧道（IPv6 会被永久阻断）。
_has_v6=0
_i=0
while [ "$_i" -lt 10 ]; do
  if ip -6 addr show dev "$IF" scope global 2>/dev/null | grep -q 'inet6'; then
    _has_v6=1
    break
  fi
  _i=$((_i + 1))
  sleep 1
done
if [ "$_has_v6" = 1 ]; then
  ip -6 route replace default dev "$IF" metric 100 table 100 || exit 1
fi
# 未确认 PPP 有全局地址时 IPv6 保持阻断，绝不回落到原生出口。
sysctl -w "net.ipv4.conf.$IF.rp_filter=2" >/dev/null 2>&1 || true
iptables -t mangle -C OUTPUT -o "$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null ||
  iptables -t mangle -A OUTPUT -o "$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t mangle -C OUTPUT -o "$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null ||
    ip6tables -t mangle -A OUTPUT -o "$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
EOF
cat > /etc/ppp/ip-down.d/10-vless-egress <<'EOF'
#!/bin/sh
IF="$1"
[ -n "$IF" ] || exit 0
ip -4 route del default dev "$IF" metric 100 table 100 2>/dev/null || true
ip -6 route del default dev "$IF" metric 100 table 100 2>/dev/null || true
# metric 42700 的永久禁止路由保留，异常断线也不会走原生默认路由。
EOF
chmod 700 /etc/ppp/ip-up.d/10-vless-egress /etc/ppp/ip-down.d/10-vless-egress

if [ "$OS" = alpine ]; then
  if [ ! -f /etc/init.d/xl2tpd ]; then
    cat > /etc/init.d/xl2tpd <<'EOF'
#!/sbin/openrc-run
name="xl2tpd"
command="/usr/sbin/xl2tpd"
command_args="-D -p /run/xl2tpd.pid"
command_background="yes"
pidfile="/run/xl2tpd.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/xl2tpd
  fi
  for hook in up down; do
    hf="/etc/ppp/ip-$hook"
    if [ ! -f "$hf" ]; then
      printf '#!/bin/sh\n' > "$hf"
      chmod +x "$hf"
    fi
    if ! grep -q "ip-$hook\\.d" "$hf" 2>/dev/null; then
      {
        printf '\nfor hs in /etc/ppp/ip-%s.d/*; do\n' "$hook"
        printf '  [ -x "$hs" ] || continue\n'
        printf '  "$hs" "$@"\n'
        printf 'done\n'
      } >> "$hf"
    fi
  done
  cat > /etc/init.d/l2tp-vless-guard <<'EOF'
#!/sbin/openrc-run
name="l2tp-vless-guard"
depend() { before net; }
start() {
  ebegin "Installing L2TP fail-closed routing"
  /usr/local/sbin/l2tp-vless-killswitch.sh
  eend $?
}
EOF
  chmod +x /etc/init.d/l2tp-vless-guard
  rc-update add l2tp-vless-guard boot >/dev/null 2>&1 || die "无法设置开机断网保护"
  cat > /etc/local.d/l2tp-vless.start <<EOF
#!/bin/sh
/usr/local/sbin/l2tp-vless-killswitch.sh || exit 1
/usr/local/sbin/l2tp-vless-route.sh || exit 1
for i in \$(seq 1 15); do
  [ -p /var/run/xl2tpd/l2tp-control ] && break
  sleep 1
done
[ -p /var/run/xl2tpd/l2tp-control ] || exit 1
echo "c $LAC_NAME" > /var/run/xl2tpd/l2tp-control
EOF
  chmod +x /etc/local.d/l2tp-vless.start
  rc-update add local default >/dev/null 2>&1 || die "无法设置开机拨号"
else
  cat > /etc/systemd/system/l2tp-vless-guard.service <<'EOF'
[Unit]
Description=Install fail-closed routing before network startup
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/l2tp-vless-killswitch.sh
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/l2tp-vless-route.service <<'EOF'
[Unit]
Description=Keep A&A L2TP endpoint on native network
Requires=l2tp-vless-guard.service
After=l2tp-vless-guard.service network-online.target
Wants=network-online.target
Before=xl2tpd.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/l2tp-vless-route.sh
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/l2tp-vless-dial.service <<EOF
[Unit]
Description=Dial A&A L2TP tunnel
Requires=xl2tpd.service l2tp-vless-route.service
After=xl2tpd.service l2tp-vless-route.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in \$(seq 1 15); do [ -p /var/run/xl2tpd/l2tp-control ] && break; sleep 1; done; [ -p /var/run/xl2tpd/l2tp-control ] && echo "c $LAC_NAME" > /var/run/xl2tpd/l2tp-control'
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable l2tp-vless-guard.service l2tp-vless-route.service l2tp-vless-dial.service >/dev/null 2>&1 || die "无法设置开机保护与拨号"
fi
# ---------- 4. 拨号 ----------
step "[拨号] 正在拨号…"
/usr/local/sbin/l2tp-vless-killswitch.sh || die "无法安装全机断网保护，已停止安装"
/usr/local/sbin/l2tp-vless-route.sh || die "无法建立 A&A 接入点原生路由，已停止安装"
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
  [ -p /var/run/xl2tpd/l2tp-control ] && break
  sleep 1
done
# 先判 -p：xl2tpd 没起来时直接重定向会建出一个普通文件，反而挡住以后建 FIFO
if [ -p /var/run/xl2tpd/l2tp-control ]; then
  echo "c ${LAC_NAME}" > /var/run/xl2tpd/l2tp-control 2>/dev/null \
    || warn "拨号命令发送失败，可手动执行：echo 'c ${LAC_NAME}' > /var/run/xl2tpd/l2tp-control"
else
  warn "xl2tpd 控制管道不存在（服务可能没起来），拨号命令没发出去"
fi

info "等待 PPP 接口建立（最多 40 秒）…"
PPP_IF=""
for i in $(seq 1 40); do
  PPP_IF="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^ppp[0-9]+$' | head -1)"
  [ -n "$PPP_IF" ] && break
  sleep 1
done
PPP_IP=""
if [ -z "$PPP_IF" ]; then
  die "L2TP 未连接。请确认旧 VPS 已停止自动重连，并检查 A&A 的服务器、线路账号和密码；此时普通出站已被阻断。"
fi
# ppp 接口出现不等于 IPCP 已完成：CHAP 认证和 IP 分配还要几秒，这里轮询等 IP，
# 否则接口刚出来就查一次会误判失败
info "等待 PPP 分配 IPv4 地址（最多 30 秒）…"
for i in $(seq 1 30); do
  PPP_IP="$(ip -4 -o addr show dev "$PPP_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  [ -n "$PPP_IP" ] && break
  sleep 1
done
if [ -z "$PPP_IP" ]; then
  warn "ppp 接口 $PPP_IF 建好了，但 30 秒都没拿到 IPv4。最近的拨号日志："
  { journalctl --no-pager -n 80 2>/dev/null || tail -n 80 /var/log/syslog 2>/dev/null || true; } \
    | grep -Ei 'pppd|xl2tpd|chap|ipcp|lcp' | tail -12 || true
  die "PPP 接口没有 IPv4 地址，停止安装（隧道能建但拿不到 IP，多半是 A&A 那边的旧会话还没释放：等 10 分钟再重跑；还不行就找 A&A 客服）"
fi
ip -4 route show table 100 | grep -q "default dev $PPP_IF" || die "PPP 已建立，但全机策略路由未切换到隧道"
ip -4 route get 1.1.1.1 2>/dev/null | grep -Eq " dev $PPP_IF( |$)" || die "全机 IPv4 默认出口未切换到 PPP，停止安装"
info "隧道已建立：$PPP_IF，IP = $PPP_IP"
# 隧道健康检查：PPP 拿到 IP 不代表数据能走。A&A 账号侧出问题（L2TP 服务没开通/
# 被暂停、密码不对）时，LNS 会让 PPP 建好却不转发任何流量；提前报清楚。
info "检查隧道数据是否通畅…"
_TUN_OK=0
for _try in 1 2; do
  if curl -4 -sS -m 20 -o /dev/null "https://github.com" 2>/dev/null \
     || curl -4 -sk -m 15 -o /dev/null "https://1.1.1.1" 2>/dev/null; then
    _TUN_OK=1
    break
  fi
  [ "$_try" = "1" ] && sleep 5
done
if [ "$_TUN_OK" -ne 1 ]; then
  die "隧道已连上（IP $PPP_IP），但数据走不过去：A&A 那边没有转发流量。这通常是 A&A 账号侧的问题——L2TP 服务没开通/被暂停，或密码不对。请登录 control.aa.net.uk 检查 L2TP 服务页（用户名形如 xxx@a.1，密码用服务页上分配的那个），或联系 A&A 客服；解决后重跑脚本即可"
fi
info "隧道数据通畅"
# ---------- 5. 断网保护确认 + 出口验证 ----------
step "[保护] 检查断网保护…"
/usr/local/sbin/l2tp-vless-killswitch.sh || die "断网保护规则安装失败"
ip -4 route show table "$RT_TABLE" 2>/dev/null | grep -Eq "^default dev $PPP_IF( |$)" \
  || die "隧道默认路由已丢失，停止安装"
PPP_IP6=""
AA_IP6=""
if [ -n "$PPP_IF" ]; then
  PPP_IP6="$(ip -6 -o addr show dev "$PPP_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  if [ -n "$PPP_IP6" ]; then
    # 钩子里的轮询也可能错过晚到的 IPv6CP 地址：这里再补一次，保证隧道有 v6 就一定走隧道。
    if ! ip -6 route show table 100 2>/dev/null | grep -Eq "^default dev $PPP_IF( |$)"; then
      warn "PPP 口已有 IPv6 但策略路由缺失，补加隧道 IPv6 默认路由"
      ip -6 route replace default dev "$PPP_IF" metric 100 table 100 || die "补加隧道 IPv6 默认路由失败"
    fi
    info "隧道 IPv6：$PPP_IP6（IPv6 出站同样走 L2TP，受断网保护）"
    AA_IP6="$(curl -6 -fsS --noproxy '*' --max-time 15 https://ifconfig.me 2>/dev/null || echo "")"
    if [ -n "$AA_IP6" ]; then
      info "出口 IPv6：$AA_IP6（走 A&A L2TP，自动识别）"
    else
      warn "隧道有 IPv6 地址但连不通公网，IPv6 出口不可用"
    fi
  else
    warn "隧道没有分到公网 IPv6：普通 IPv6 出站将被阻断"
  fi
fi
# IPv6 永不静默泄漏：断言 v6 策略规则存在，且 table 100 的 v6 默认路由
# 只能是走 PPP 隧道或 prohibit（阻断）——绝不能是原生出口。
if [ -e /proc/net/if_inet6 ]; then
  ip -6 rule show | grep -Eq '^10000:.*lookup 100' || die "IPv6 策略路由规则缺失：IPv6 可能走原生出口，已停止安装"
  # table 100 里可能同时有 metric 100 的隧道默认路由和 metric 42700 的禁止路由：
  # 隧道路由优先检查（metric 小先生效），禁止路由次之，其他一律视为泄漏风险。
  _v6tbl="$(ip -6 route show table 100 2>/dev/null || true)"
  if printf '%s\n' "$_v6tbl" | grep -Eq "^default dev $PPP_IF( |$)"; then
    info "IPv6 默认路由走隧道（table 100），不会泄漏到原生出口"
  elif printf '%s\n' "$_v6tbl" | grep -Eq '^prohibit default( |$)'; then
    info "IPv6 已阻断（table 100），不会走原生出口"
  else
    die "IPv6 默认路由异常（table 100 无隧道路由也无禁止路由）：为防止泄漏到原生出口，已停止安装"
  fi
fi

VPS_IP="$NATIVE_PUBLIC_IP"
[ -n "$VPS_IP" ] || die "无法确定 VPS 入口 IPv4 地址"
AA_IP=""
if [ -n "$PPP_IF" ]; then
  AA_IP="$(curl -4 -fsS --noproxy '*' --max-time 15 https://ifconfig.me 2>/dev/null || echo "")"
fi
[ -n "$AA_IP" ] || die "无法验证整台 VPS 的 IPv4 出口；请先检查 L2TP 与路由"
[ "$AA_IP" != "$VPS_IP" ] || die "检测到出口仍是 VPS 原生 IP，安装未达到全机 A&A 出口目标"

# ---------- 6. 安装 shanchu 一键删除命令 ----------
step "[工具] 安装 shanchu 一键删除命令…"
cat > /usr/local/bin/shanchu <<'SHANCHU_EOF'
#!/bin/sh
# shanchu：删除 L2TP 一键脚本安装的一切（L2TP 拨号 + 策略路由 + 相关文件）
# 用法：在终端直接运行 shanchu
trap 'rm -f /usr/local/bin/shanchu' EXIT

echo "正在删除 L2TP 相关的一切…"

# ---------- 1. 停服务 ----------
echo "[1/5] 停止服务…"
if command -v systemctl >/dev/null 2>&1; then
  for _s in l2tp-vless-dial l2tp-vless-route l2tp-vless-guard xl2tpd; do
    systemctl stop "$_s" 2>/dev/null || true
    systemctl disable "$_s" 2>/dev/null || true
  done
fi
if command -v rc-service >/dev/null 2>&1; then
  rc-service xl2tpd stop 2>/dev/null || true
  rc-update del xl2tpd default 2>/dev/null || true
  rc-service l2tp-vless-guard stop 2>/dev/null || true
  rc-update del l2tp-vless-guard boot 2>/dev/null || true
fi

# ---------- 2. 断开 L2TP ----------
echo "[2/5] 断开 L2TP…"
if [ -p /var/run/xl2tpd/l2tp-control ]; then
  echo "d aa" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
  sleep 2
fi
pkill -x pppd 2>/dev/null || true
sleep 1

# ---------- 3. 清策略路由和防火墙 ----------
echo "[3/5] 清理策略路由和防火墙…"
for _p in 9000 10000; do
  while ip -4 rule del pref "$_p" 2>/dev/null; do :; done
  while ip -6 rule del pref "$_p" 2>/dev/null; do :; done
done
ip -4 route flush table 100 2>/dev/null || true
ip -6 route flush table 100 2>/dev/null || true
# 删加在 ppp 接口上的 MSS 钳制规则
for _t in iptables ip6tables; do
  if command -v "$_t" >/dev/null 2>&1; then
    "$_t" -t mangle -S OUTPUT 2>/dev/null | grep " -o ppp" | while IFS= read -r _r; do
      _d="$(printf '%s' "$_r" | sed 's/^-A /-D /')"
      # shellcheck disable=SC2086
      "$_t" -t mangle $_d 2>/dev/null || true
    done
  fi
done

# ---------- 4. 卸载 xl2tpd/ppp ----------
echo "[4/5] 卸载 xl2tpd/ppp…"
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq xl2tpd ppp >/dev/null 2>&1 || true
elif command -v apk >/dev/null 2>&1; then
  apk del xl2tpd ppp >/dev/null 2>&1 || true
fi

# ---------- 5. 删文件（先恢复安装前备份的配置） ----------
echo "[5/5] 删除配置文件…"
if [ -f /etc/l2tp-vless/xl2tpd.conf.before-l2tp-vless ]; then
  mkdir -p /etc/xl2tpd 2>/dev/null || true
  cp -p /etc/l2tp-vless/xl2tpd.conf.before-l2tp-vless /etc/xl2tpd/xl2tpd.conf 2>/dev/null || true
else
  rm -f /etc/xl2tpd/xl2tpd.conf
fi
if [ -f /etc/l2tp-vless/chap-secrets.before-l2tp-vless ]; then
  cp -p /etc/l2tp-vless/chap-secrets.before-l2tp-vless /etc/ppp/chap-secrets 2>/dev/null || true
  chmod 600 /etc/ppp/chap-secrets 2>/dev/null || true
else
  rm -f /etc/ppp/chap-secrets
fi
rm -f /etc/ppp/options.l2tp-vless
rm -f /etc/ppp/ip-up.d/10-vless-egress /etc/ppp/ip-down.d/10-vless-egress
rm -rf /etc/l2tp-vless
rm -f /usr/local/sbin/l2tp-vless-killswitch.sh /usr/local/sbin/l2tp-vless-route.sh
rm -f /etc/systemd/system/l2tp-vless-guard.service \
      /etc/systemd/system/l2tp-vless-route.service /etc/systemd/system/l2tp-vless-dial.service
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload 2>/dev/null || true
fi
rm -f /etc/init.d/xl2tpd /etc/init.d/l2tp-vless-guard
rm -f /etc/local.d/l2tp-vless.start

echo "完成：L2TP 拨号、策略路由、相关文件已全部删除。"
SHANCHU_EOF
chmod +x /usr/local/bin/shanchu

# ---------- 7. 显示结果 ----------
step "[自动检查] 安装完成后验证全机出口和断线保护…"
printf '① VPS 普通流量的公网 IPv4 出口\n'
printf '   执行：curl -4 --noproxy "*" https://ifconfig.me\n'
CHECK_IP="$(curl -4 -fsS --noproxy '*' --max-time 15 https://ifconfig.me 2>/dev/null || true)"
[ -n "$CHECK_IP" ] || die "公网 IPv4 出口检查失败；不能确认流量已走 A&A"
printf '%s\n' "$CHECK_IP" | awk -F. 'NF != 4 { exit 1 } { for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1 }' \
  || die "公网 IPv4 出口检查返回了无效地址"
printf '   结果：%s（应与你的 A&A 出口 IPv4 一致）\n' "$CHECK_IP"
[ "$CHECK_IP" != "$VPS_IP" ] || die "出口仍是 VPS 原生 IPv4，安装未达到目标"

printf '\n② A&A 路由表（数字 %s）\n' "$RT_TABLE"
printf '   执行：ip -4 route show table %s\n' "$RT_TABLE"
CHECK_ROUTES="$(ip -4 route show table "$RT_TABLE" 2>/dev/null)" || die "无法读取 A&A 路由表"
[ -n "$CHECK_ROUTES" ] || die "A&A 路由表为空"
printf '%s\n' "$CHECK_ROUTES" | while IFS= read -r _route; do
  case "$_route" in
    "default dev $PPP_IF"*) printf '   A&A 隧道默认路由：%s\n' "$_route" ;;
    'prohibit default'*) printf '   断线保护（隧道断开时阻止回落）：%s\n' "$_route" ;;
    "$SERVER_IP "*|"$SERVER_IP/32 "*) printf '   A&A 接入服务器使用原生线路：%s\n' "$_route" ;;
    *) printf '   其他路由：%s\n' "$_route" ;;
  esac
done
printf '%s\n' "$CHECK_ROUTES" | grep -Eq "^default dev $PPP_IF( |$)" || die "A&A 隧道默认路由缺失"
printf '%s\n' "$CHECK_ROUTES" | grep -q '^prohibit default' || die "断线保护的禁止路由缺失"

printf '\n③ 出站策略规则（数字越小越优先）\n'
printf '   执行：ip -4 rule show\n'
CHECK_RULES="$(ip -4 rule show 2>/dev/null)" || die "无法读取出站策略规则"
printf '%s\n' "$CHECK_RULES" | while IFS= read -r _rule; do
  case "$_rule" in
    '0:'*) printf '   系统本机地址规则：%s\n' "$_rule" ;;
    '9000:'*) printf '   原生 IP 管理连接的回包走原生线路：%s\n' "$_rule" ;;
    '10000:'*) printf '   普通出站优先查 A&A 路由表：%s\n' "$_rule" ;;
    '32766:'*) printf '   系统原生主路由表：%s\n' "$_rule" ;;
    '32767:'*) printf '   系统默认规则：%s\n' "$_rule" ;;
    *) printf '   其他规则：%s\n' "$_rule" ;;
  esac
done
printf '%s\n' "$CHECK_RULES" | grep -Eq '^9000:.*lookup main' || die "原生管理回包规则缺失"
printf '%s\n' "$CHECK_RULES" | grep -Eq "^10000:.*lookup $RT_TABLE" || die "全机 A&A 出站规则缺失"
ip -4 route get 1.1.1.1 2>/dev/null | grep -Eq " dev $PPP_IF( |$)" || die "普通 IPv4 目的地没有走 A&A 隧道"
info "三项自动检查通过；普通 IPv4 出站使用 A&A 隧道"

printf "\n"
printf "\n${GREEN}${BOLD}安装完成！${NC}全机普通流量已走 A&A L2TP 隧道。\n"
printf "全机普通出口：${BOLD}%s${NC}（A&A L2TP）\n" "$CHECK_IP"
printf "删除：以后想删掉 L2TP 相关的一切，直接运行 ${BOLD}shanchu${NC}\n"
