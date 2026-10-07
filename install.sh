#!/bin/sh
# L2TP-VPS 安装器。由 tools/build.py 把 src/install.sh 和 src/runtime.sh 拼成一个文件，下载后用 sh 运行。
#
# 这个脚本做什么：
#   让这台 VPS 自己"拨号"连到你购买的 L2TP 线路。装好以后，本机和本机上的节点新发起的上网连接
#   都从 L2TP 隧道出去，外网看到的是线路的出口 IP，而不是 VPS 自己的 IP。
#   别人连进来的连接（SSH、节点端口）仍然走 VPS 原来的 IP，所以客户端配置不用改。
#
# 名词小抄（看不懂下面的注释时先看这里）：
#   L2TP     一种"隧道"协议，可以理解成一根虚拟网线，把 VPS 接到线路服务商那边。
#            本脚本只拨"纯 L2TP"（UDP 1701 端口），不带 IPsec 加密，所以也不需要 PSK（预共享密钥）。
#   PPP      在隧道里跑的拨号协议，负责账号密码认证、分配隧道 IP。拨通后本机多出一张网卡 l2tp-aa。
#   xl2tpd   负责建立 L2TP 隧道的后台程序；隧道建好后它会启动 pppd（PPP 程序）完成拨号。
#   CHAP     一种不在网络上明文传送密码的认证方式。本脚本拒绝明文的 PAP。
#   nftables Linux 自带的防火墙。这里用它做"断线保护"：隧道没通时，不让普通程序从 VPS 原网卡直接出去。
#   策略路由 按规则挑选不同"路由表"的机制。本项目专用的路由表编号是 24680。
#   原生网卡/原生 IP  VPS 自带的网卡（常见名字 eth0、ens3）和它的 IP，即不经过隧道时的出口。
#
# 整体流程：检查系统 → 读取/询问账号 → 安装依赖 → 备份 → 写入配置和服务 → 打开断线保护
#           → 拨号 → 检查出口确实变成了 L2TP → 标记成功。任何一步失败都不会自动放开普通出站。
# -e：任何命令出错就停下；-u：用到未定义的变量就报错。防止半截执行把网络弄乱。
set -eu
# SSH 断开时终端会发 HUP 信号，这里忽略它，避免安装做到一半被打断。
trap '' HUP
VERSION=2.0.6
case "${1:-}" in --version) echo "$VERSION"; exit 0;; esac
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# 以后新建的文件默认只有 root 能读（配置里有密码）。
umask 077
# STATE：保存账号、配置和备份的目录（目录名沿用旧版）。RUNTIME：装好后的管理命令 l2tp-vps。
# PEER：拨号成功后出现的隧道网卡名，只是本机接口名，与服务商无关。
STATE=/etc/l2tp-vless
RUNTIME=/usr/local/sbin/l2tp-vps
PEER=l2tp-aa
LEGACY=0
SUCCESS=0
BACKUP=
# fatal 打印错误并退出；info 打印普通进度。
fatal() { printf '[出错] %s\n' "$*" >&2; exit 1; }
info() { printf '[L2TP-VPS] %s\n' "$*"; }
# ---------- 第 1 步：检查运行环境 ----------
# 只支持 Linux；必须是 root；Debian/Ubuntu 需要正在运行的 systemd，Alpine 需要 OpenRC。
[ "$(uname -s)" = Linux ] || fatal '只支持 Linux VPS'
[ "$(id -u)" = 0 ] || fatal '请用 root 或 sudo 运行'
[ -f /etc/alpine-release ] && INIT=openrc || INIT=systemd
if [ "$INIT" = systemd ]; then
  [ -f /etc/debian_version ] && [ -d /run/systemd/system ] || fatal '需要 Debian/Ubuntu 和运行中的 systemd'
else
  command -v rc-service >/dev/null || fatal '需要 OpenRC'
fi
# 用一个目录当"锁"，防止两个安装同时进行。/run 在重启后会被清空，所以锁不会永久残留。
mkdir -p /run
mkdir /run/l2tp-vps-install.lock 2>/dev/null || fatal '另一个安装/升级正在进行。若确认上次已被强制终止，运行 sudo rmdir /run/l2tp-vps-install.lock 后重试（重启也会清掉）'
# finish 在脚本退出时自动执行（成功或失败都会）：释放锁；如果没成功，告诉用户怎么恢复上网。
finish() {
  rc=$?
  trap - EXIT INT TERM
  rmdir /run/l2tp-vps-install.lock 2>/dev/null || true
  if [ "$SUCCESS" != 1 ]; then
    [ "$rc" != 0 ] || rc=1
    printf '\n安装/升级未完成。没有自动放开普通出站。\n' >&2
    if [ -x "$RUNTIME" ] && [ -f "$STATE/v2-owned" ]; then
      printf '恢复原生上网：sudo l2tp-vps recover\n重新升级：sudo l2tp-vps update\n' >&2
    fi
    [ -z "$BACKUP" ] || printf '本次备份（含密码，仅 root 可读）：%s\n' "$BACKUP" >&2
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------- 第 2 步：读取已有账号（升级时自动复用） ----------
# 旧配置只当作纯文本读取，绝不用 . 或 source 执行它，防止密码里的特殊字符被当成命令运行。
value() { sed -n "s/^$2=//p" "$1" | head -1; }
# LEGACY=1 表示机器上装的是旧版（v1），需要迁移。v2-owned 是新版装过的标记文件。
if [ -f "$STATE/net.env" ] && [ ! -f "$STATE/v2-owned" ]; then LEGACY=1; fi
[ ! -f "$STATE/legacy-pending" ] || LEGACY=1
old_server=; old_user=; old_pass=
if [ -f "$STATE/password" ]; then
  old_server=$(cat "$STATE/server"); old_user=$(cat "$STATE/user"); old_pass=$(cat "$STATE/password")
elif [ "$LEGACY" = 1 ]; then
  old_server=$(value "$STATE/net.env" SERVER_IP)
  old_user=$(awk '$1=="name" {print $2; exit}' /etc/ppp/options.l2tp-vless 2>/dev/null || true)
  # 旧版把密码写在 /etc/ppp/chap-secrets 里。只按旧版自己写出的格式解析；只要有一点歧义就报错，
  # 宁可让用户手动提供密码，也不猜错。
  if [ -z "${L2TP_PASS:-}" ]; then
  # 用户名经环境变量交给 awk：awk -v 会把用户名里的反斜杠当转义符吃掉（如 DOMAIN\user）。
  old_pass=$(L2TP_MATCH_USER="${L2TP_USER:-$old_user}" awk '
    function token(    c,s,quoted) {
      sub(/^[ \t]+/, "", line); s=""; quoted=(substr(line,1,1)=="\""); if(quoted)line=substr(line,2);
      while(length(line)) { c=substr(line,1,1); line=substr(line,2);
        if(c=="\\") { if(!length(line))exit 2; s=s substr(line,1,1); line=substr(line,2) }
        else if(quoted && c=="\"") return s;
        else if(!quoted && c~/[ \t]/) return s;
        else s=s c;
      } if(quoted)exit 2; return s
    }
    BEGIN {user=ENVIRON["L2TP_MATCH_USER"]}
    {line=$0; u=token(); server=token(); password=token(); if(u==user && server=="*"){print password; found++;}}
    END {if(found!=1)exit 2}' /etc/ppp/chap-secrets 2>/dev/null) || fatal '无法无歧义读取旧密码；请用 L2TP_USER/L2TP_PASS 环境变量明确提供账号，或先保留旧配置联系维护者'
  fi
fi
# 上次安装没成功（比如密码填错，一直拨不通）时，再运行安装命令会沿用保存的错误账号。
# 有终端、又没用环境变量指定账号时，给一次重新输入的机会；直接回车仍沿用原账号。
if [ -f "$STATE/password" ] && [ ! -f "$STATE/installed-version" ] && [ -t 0 ] &&
   [ -z "${L2TP_SERVER:-}${L2TP_USER:-}${L2TP_PASS:-}" ]; then
  printf '上次安装没有完成。要重新输入服务器、用户名和密码吗？[y/N] '
  IFS= read -r redo || redo=
  case "$redo" in y|Y|yes|YES) old_server=; old_user=; old_pass=;; esac
fi
# 环境变量 L2TP_SERVER / L2TP_USER / L2TP_PASS 优先；没给就用旧配置里的值。
SERVER=${L2TP_SERVER:-$old_server}
USER_NAME=${L2TP_USER:-$old_user}
PASSWORD=${L2TP_PASS:-$old_pass}
# ask：还缺什么就在终端里问用户。没有终端（比如自动化脚本）时直接报错，提示用环境变量传入。
ask() {
  [ -t 0 ] || fatal "缺少 $1；无终端时通过对应 L2TP_* 环境变量传入"
  printf '%s: ' "$1"
  IFS= read -r answer || fatal '输入已取消'
}
[ -n "$SERVER" ] || { ask 'L2TP 服务器（域名或 IPv4）'; SERVER=$answer; }
[ -n "$USER_NAME" ] || { ask 'L2TP 用户名'; USER_NAME=$answer; }
# 输入密码时用 stty -echo 关闭回显，屏幕上不显示密码；按 Ctrl+C 退出时也会恢复回显。
if [ -z "$PASSWORD" ]; then
  [ -t 0 ] || fatal '缺少 L2TP_PASS'
  printf 'L2TP 密码: '
  trap 'stty echo 2>/dev/null; exit 130' INT TERM
  stty -echo
  IFS= read -r PASSWORD || { stty echo; fatal '输入已取消'; }
  stty echo; printf '\n'
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi
# 检查输入：服务器只允许域名或 IPv4 的字符（字母、数字、点、减号），防止把奇怪内容写进配置。
case "$SERVER" in ''|*[!A-Za-z0-9.-]*|-*) fatal '服务器必须是域名或 IPv4';; esac
# 用户名和密码由服务商决定，允许空格、引号等特殊字符，只禁止换行。
# 它们不会交给 shell 执行，只会带引号写进 pppd 的配置文件。
[ -n "$USER_NAME" ] && [ "$USER_NAME" = "$(printf '%s' "$USER_NAME" | tr -d '\r\n')" ] || fatal '用户名为空或包含换行'
[ -n "$PASSWORD" ] && [ "$PASSWORD" = "$(printf '%s' "$PASSWORD" | tr -d '\r\n')" ] || fatal '密码为空或包含换行'
info "准备安装/升级至 ${VERSION}；已有账号会自动复用"
# 旧版迁移：先记下旧版用过的路由信息，后面才能只删除旧版自己的规则。
if [ "$LEGACY" = 1 ] && [ ! -f "$STATE/legacy-routes.env" ]; then
  printf 'LEGACY_IP=%s\nLEGACY_ENDPOINT=%s\n' "$(value "$STATE/net.env" NATIVE_IP)" "$(value "$STATE/net.env" SERVER_IP)" > "$STATE/legacy-routes.env"
  cp "$STATE/native-v6.txt" "$STATE/legacy-v6.txt" 2>/dev/null || : > "$STATE/legacy-v6.txt"
  touch "$STATE/legacy-pending"
fi
if [ "$LEGACY" = 1 ] && [ -z "${L2TP_SERVER:-}" ]; then
  info '旧版只保存了服务器 IP；本次保留该 IP。若接入点是域名，希望断线后重新解析，请设置 L2TP_SERVER=你的域名 后再次升级。'
fi

# 旧版用的是系统共用的 xl2tpd 配置。如果里面还有别的连接，拒绝接管，免得误停别人的 L2TP。
if [ "$LEGACY" = 1 ] && [ ! -f "$STATE/legacy-detached" ]; then
  grep -q '^pppoptfile = /etc/ppp/options.l2tp-vless$' /etc/xl2tpd/xl2tpd.conf || fatal '旧配置已被修改，拒绝接管共享服务'
  [ "$(grep -Ec '^\[(lac|lns) ' /etc/xl2tpd/xl2tpd.conf)" = 1 ] || fatal '旧配置包含其他 L2TP 连接，需先人工分离'
fi

# ---------- 第 3 步：安装依赖软件 ----------
# curl 下载/检测出口，ip 改路由，nft 防火墙，xl2tpd + pppd 拨号，su 切换维护账号，nslookup 查域名，timeout 限时。
# 缺任何一个就用系统包管理器安装。卸载时不会删这些软件（可能别的程序也在用）。
need=0
for binary in curl ip nft xl2tpd pppd su nslookup timeout; do command -v "$binary" >/dev/null 2>&1 || need=1; done
if [ "$need" = 1 ]; then
  if [ "$INIT" = openrc ]; then
    apk add --no-cache curl ca-certificates iproute2 nftables xl2tpd ppp bind-tools || fatal '依赖安装失败；尚未切换网络'
  else
    export DEBIAN_FRONTEND=noninteractive
    # 某个第三方软件源坏了时 apt-get update 会报错，但官方源通常还能用，所以继续尝试安装。
    apt-get -o DPkg::Lock::Timeout=120 update || info 'apt-get update 有报错（常见于失效的第三方源），继续尝试安装依赖'
    apt-get -o DPkg::Lock::Timeout=120 install -y curl ca-certificates iproute2 nftables xl2tpd ppp dnsutils || fatal '依赖安装失败；尚未切换网络。请先修复 apt 软件源后重试（Ubuntu 的 xl2tpd 在 universe 源，可先运行 add-apt-repository universe）'
    unset DEBIAN_FRONTEND
  fi
fi
for binary in curl ip nft xl2tpd pppd su nslookup timeout; do command -v "$binary" >/dev/null || fatal "缺少 $binary"; done
# 用 apt 装 xl2tpd 时，系统自带的 xl2tpd 服务会被自动启动，没配任何连接却在公网监听 UDP 1701。
# 本项目用自己独立的一份 xl2tpd，所以只把这个"没配置、白开着"的系统自带服务停掉并禁用；
# 如果它的配置里写了任何 [lac]/[lns] 连接（说明有人在用），就完全不动。
if [ "$INIT" = systemd ] && [ "$LEGACY" != 1 ] && [ -f /etc/xl2tpd/xl2tpd.conf ] && ! grep -Eq '^[[:space:]]*\[(lac|lns) ' /etc/xl2tpd/xl2tpd.conf; then
  # 分两条命令：Debian 12/13 上 "disable --now" 停不掉这种由老式 init 脚本生成的服务。
  systemctl stop xl2tpd.service >/dev/null 2>&1 || true
  systemctl disable xl2tpd.service >/dev/null 2>&1 || true
fi
# PPP 拨号需要内核提供 /dev/ppp 设备。部分 OpenVZ/LXC 容器 VPS 没有开放，这种机器没法使用本脚本。
modprobe ppp_generic 2>/dev/null || true
[ -c /dev/ppp ] || mknod /dev/ppp c 108 0 2>/dev/null || true
[ -c /dev/ppp ] || fatal 'VPS 不支持 PPP；需由商家启用 /dev/ppp'
# 有些机器上 /dev/ppp 文件存在，但内核没有 PPP 驱动，一打开就失败，所以真的打开试一下。
if ! ( : <>/dev/ppp ) 2>/dev/null; then
  # Debian 云镜像（genericcloud）自带的精简版 cloud 内核根本没编译 PPP，换成普通内核就行。
  case "$(uname -r)" in *-cloud-*) fatal 'VPS 不支持 PPP：当前是 Debian 精简版 cloud 内核，不带 PPP。先运行 sudo apt install linux-image-amd64，重启后再安装';; esac
  fatal 'VPS 不支持 PPP：/dev/ppp 无法打开（内核或容器没有开放 PPP）；需由商家启用'
fi
# ---------- 第 4 步：第一次安装时确认没有和别的软件"撞车" ----------
# 本项目要用：路由表 24680、若干条策略路由优先级、nftables 表 l2tp_vps、网卡名 l2tp-aa、系统用户 l2tp-fetch。
# 第一次安装时如果发现它们已被别的软件占用，就停下来，绝不清空或覆盖别人的配置。
# l2tp-fetch 是一个专用的"维护账号"：只有它能在隧道断开时走 VPS 原生网络查 DNS、下载更新。
if [ ! -f "$STATE/v2-owned" ]; then
  for family in -4 -6; do
    [ -z "$(ip "$family" route show table 24680 2>/dev/null)" ] || fatal '路由表 24680 已被其他软件使用'
    for pref in 8900 8904 8905 8910 8911 8915 8920 8930; do
      [ -z "$(ip "$family" rule show pref "$pref" 2>/dev/null)" ] || fatal "路由优先级 $pref 已被其他软件使用"
    done
  done
  nft list table inet l2tp_vps >/dev/null 2>&1 && fatal '同名 nftables 表已存在，拒绝覆盖'
  ip link show "$PEER" >/dev/null 2>&1 && fatal "接口 $PEER 已存在，拒绝接管"
  if id l2tp-fetch >/dev/null 2>&1; then
    [ -f "$STATE/fetch-uid" ] && [ "$(cat "$STATE/fetch-uid")" = "$(id -u l2tp-fetch)" ] || fatal '用户 l2tp-fetch 已存在，拒绝接管'
  elif [ "$INIT" = openrc ]; then adduser -S -D -H -s /sbin/nologin l2tp-fetch
  else useradd --system --no-create-home --shell /usr/sbin/nologin l2tp-fetch; fi
fi
FETCH_UID=$(id -u l2tp-fetch)
mkdir -p "$STATE"
chmod 700 "$STATE"
printf '%s\n' "$FETCH_UID" > "$STATE/fetch-uid"
# ---------- 第 5 步：找出原生网卡和原生 IP ----------
# 看 IPv4 默认路由走哪张网卡（跳过 PPP/隧道网卡），再取这张网卡上的第一个公网 IPv4。
# 纯 IPv6 的 VPS 没有 IPv4 默认路由，会在这里报错。
route=$(ip -4 route show default table main | awk '$0 !~ / dev (ppp|l2tp-aa)/ {print; exit}')
NATIVE_IF=$(printf '%s\n' "$route" | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
case "$NATIVE_IF" in ''|*[!A-Za-z0-9_.:-]*) fatal '找不到有效的原生网卡：没有 IPv4 默认路由（纯 IPv6 VPS 不支持，需要公网 IPv4）';; esac
NATIVE_IP=$(ip -4 -o addr show dev "$NATIVE_IF" scope global | awk 'NR==1{split($4,a,"/");print a[1]}')
[ -n "$NATIVE_IP" ] || fatal '原生网卡没有 IPv4'
# ---------- 第 6 步：改动前先备份 ----------
# 把现有的账号、配置、安装器复制一份到 /etc/l2tp-vless/backups/时间-进程号/（只有 root 能读，含密码）。
# 如果备份里有上一版完整的安装器，就记下这个备份，供 l2tp-vps rollback 离线回滚。
mkdir -p "$STATE/backups" /usr/local/sbin /usr/local/bin /etc/ppp/ip-up.d /etc/ppp/ip-down.d /etc/ppp/ipv6-up.d /etc/ppp/ipv6-down.d
chmod 700 "$STATE" "$STATE/backups"
BACKUP="$STATE/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir "$BACKUP"
for f in net.env native-v4.txt native-v6.txt server user password installed-version install.sh xl2tpd.conf options v2-owned disabled; do
  [ ! -f "$STATE/$f" ] || cp -p "$STATE/$f" "$BACKUP/$f"
done
[ ! -f "$RUNTIME" ] || cp -p "$RUNTIME" "$BACKUP/runtime.sh"
if [ -f "$BACKUP/install.sh" ] && [ -f "$BACKUP/installed-version" ]; then
  printf '%s\n' "$BACKUP" > "$STATE/rollback-path"
fi
if [ "$LEGACY" = 1 ]; then
  for f in /etc/xl2tpd/xl2tpd.conf /etc/ppp/chap-secrets /etc/ppp/options.l2tp-vless; do
    [ ! -f "$f" ] || cp -p "$f" "$BACKUP/$(basename "$f").legacy"
  done
fi

# ---------- 第 7 步：先装好管理命令 l2tp-vps，再动网络 ----------
# 这样即使后面拨号失败，也已经可以用 sudo l2tp-vps recover 恢复原生上网。
# 下面这段 heredoc 就是 src/runtime.sh 的全部内容，构建时被原样嵌进来。
cat > "$RUNTIME.new" <<'L2TP_RUNTIME_EOF'
#!/bin/sh
# L2TP-VPS 管理命令，安装后位于 /usr/local/sbin/l2tp-vps。
# 常用：sudo l2tp-vps status（看状态）| update（升级）| recover（恢复原生上网）| rollback（回滚）| uninstall（卸载）
# 其余子命令（guard、route、up、down、watch……）由开机服务和拨号钩子自动调用，一般不用手动运行。
#
# 原理一句话：用"策略路由 + 防火墙"让本机新发起的连接只能走 L2TP 隧道网卡 l2tp-aa；
# 别人连进来的连接，回包仍从原生网卡发回；隧道断开时，普通程序的新连接被拒绝，而不是偷偷改走原生 IP。
# 本脚本只改自己的东西：路由表 24680、优先级 8900~8930 的策略规则、nftables 表 l2tp_vps、服务和 l2tp-aa 网卡。
set -eu
trap '' HUP
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# TABLE：本项目专用路由表。MARK：给"回包"打的标记，带这个标记的包查系统主路由表、从原生网卡出去。
# TUNMARK：强制进隧道表的标记（保留给兼容用途）。TAG：pppd 的 ipparam 暗号，用来认出本项目的拨号。
STATE=/etc/l2tp-vless
TABLE=24680
MARK=0x24680
TUNMARK=0x24681
PEER=l2tp-aa
TAG=l2tp-vps
# load：读取安装时保存的网络信息（原生网卡 NATIVE_IF、原生 IP、服务器 IP 等）。
# ipv6_on：系统是否启用了 IPv6。
fatal() { printf '%s\n' "$*" >&2; exit 1; }
load() { [ -f "$STATE/v2-owned" ] || fatal '尚未安装新版'; . "$STATE/net.env"; }
ipv6_on() { [ -e /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" != 1 ]; }
# render_firewall：生成 nftables 防火墙规则（inet 表同时管 IPv4 和 IPv6）。
#   l2tp_route  本机发出的"回包"（别人连进来的连接的回应）打上 MARK，内核会据此重新选路，从原生网卡发回。
#   l2tp_bridge 从 Docker 网桥等其他网卡转发出去的回包也打上 MARK，按原路返回。
#   l2tp_nat    从隧道出去的包做 masquerade（伪装/NAT）：把源地址改成隧道网卡的地址。
#               比如节点绑定 VPS 原生 IP 发起连接，被改送进隧道后，源地址也要跟着换成隧道地址，否则回包回不来。
#   output      断线保护的核心，默认拒绝。只放行：本机回环、隧道网卡、其他本地网卡、原生网卡上的回包、
#               发往 L2TP 服务器的 UDP 1701（隧道本身）、维护账号的 DNS/HTTPS、DHCP 和 IPv6 邻居发现。
#               其余想从原生网卡出去的新连接一律拒绝，这就是"隧道断了也不会从原生 IP 漏出去"。
render_firewall() {
  # 只给回包打标记。新连接不打：8920 规则本来就会把它们送进隧道表，再打标记反而会让维护账号的连接被送错地方。
  cat <<EOF
add table inet l2tp_vps
flush table inet l2tp_vps
table inet l2tp_vps {
  chain l2tp_route {
    type route hook output priority 300; policy accept;
    ct direction reply meta mark set $MARK
  }
  chain l2tp_bridge {
    # 从 Docker 网桥、wg0 等网卡转发过来的回包，按原路返回（查主路由表）。
    type filter hook prerouting priority mangle; policy accept;
    iifname != { "lo", "$NATIVE_IF", "$PEER" } ct direction reply meta mark set $MARK
  }
  chain l2tp_nat {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$PEER" masquerade
  }
  chain output {
    type filter hook output priority 0; policy drop;
    oifname "lo" accept
    oifname "$PEER" accept
    # 其他本地网卡（Docker 网桥、内网网卡、wg0）不是原生出口，不拦。
    oifname != "$NATIVE_IF" accept
    oifname "$NATIVE_IF" ct direction reply ct state established,related accept
    oifname "$NATIVE_IF" ip daddr $ENDPOINT udp dport 1701 accept
    oifname "$NATIVE_IF" meta skuid $FETCH_UID udp dport 53 accept
    oifname "$NATIVE_IF" meta skuid $FETCH_UID tcp dport { 53, 443 } accept
    oifname "$NATIVE_IF" udp sport 68 udp dport 67 accept
    oifname "$NATIVE_IF" udp sport 546 udp dport 547 accept
    oifname "$NATIVE_IF" ip6 hoplimit 255 icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
    counter reject with icmpx type admin-prohibited
  }
}
EOF
}
# rule：添加一条策略路由规则；同优先级下已经有同样的规则就跳过，重复运行也不会越加越多。
rule() {
  family=$1; pref=$2; match=$3; shift 3
  if ! ip "$family" rule show pref "$pref" | grep -F -- "$match" >/dev/null; then
    ip "$family" rule add pref "$pref" "$@"
  fi
}
drop_legacy_source_rules() {
  # 旧版加过"源地址是 VPS 原生 IP 就走原生网卡"的规则（优先级 8910），会让节点流量绕过隧道，这里删掉。
  [ -f "$STATE/native-v4.txt" ] || return 0
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    ip -4 rule del pref 8910 from "$addr/32" table main 2>/dev/null || true
  done < "$STATE/native-v4.txt"
  [ -f "$STATE/native-v6.txt" ] || return 0
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    ip -6 rule del pref 8910 from "$addr/128" table main 2>/dev/null || true
  done < "$STATE/native-v6.txt"
}
copy_dev_prefixes() {
  # 把原生网卡上的"直连网段"（同一局域网内的地址）抄进隧道表，访问同网段的邻居不必绕进隧道。
  # 只抄网段和网卡名；ip route show 输出里的 proto、metric 等字段不能原样写回。
  family=$1
  ip "$family" route show table main dev "$NATIVE_IF" 2>/dev/null | while IFS= read -r line; do
    dest=${line%% *}
    case "$dest" in ''|default*|nexthop|broadcast|local|any|throw|prohibit|unreachable|blackhole) continue;; esac
    # 带 via（经网关）的路由不抄：只抄网卡名会变成错误的"直连"路由，这些地址交给隧道即可。
    case "$line" in *" via "*) continue;; esac
    ip "$family" route replace "$dest" dev "$NATIVE_IF" table "$TABLE" 2>/dev/null || true
  done
}
copy_link_routes() {
  copy_dev_prefixes -4
  if ipv6_on; then
    copy_dev_prefixes -6
  fi
}
install_native_fallback() {
  # 在隧道表里放一条"备用"原生默认路由（metric 40000，优先级比隧道的 100 低）。
  # 为什么需要：隧道没拨通时，如果隧道表里只有 prohibit（禁止），SSH 回包在打上 MARK 之前就会被路由拒绝，
  #   SSH 会断。有了这条备用路由，回包能先"找到路"，再被打标记从原生网卡发回。
  # 普通新连接即使选中这条备用路由，也会被上面 output 防火墙拒绝，所以不会漏。
  family=$1
  route=$(ip "$family" route show default table main 2>/dev/null | awk -v nic="$NATIVE_IF" '{for(i=1;i<NF;i++) if($i=="dev" && $(i+1)==nic) {print; exit}}')
  [ -n "$route" ] || return 0
  gateway=$(printf '%s\n' "$route" | awk '{for(i=1;i<NF;i++) if($i=="via") {print $(i+1); exit}}')
  if [ -n "$gateway" ]; then
    ip "$family" route replace default via "$gateway" dev "$NATIVE_IF" onlink metric 40000 table "$TABLE"
  else
    ip "$family" route replace default dev "$NATIVE_IF" metric 40000 table "$TABLE"
  fi
}
guard() {
  # guard：打开断线保护（开机服务、安装、巡检都会调用，可以重复运行）。
  # 1. 关闭反向路径检查 rp_filter（见安装器第 12 步的说明），否则会误丢正常回包。
  # 2. 一次性提交整套防火墙规则（nft 要么全部生效要么都不生效，不会出现半套规则）。
  # 3. 写隧道表：直连网段、prohibit 兜底（metric 42700，最后才用，表示"禁止"）、备用原生路由。
  # 4. 加策略规则（数字越小越先匹配）：
  #    8900 维护账号 l2tp-fetch 查主路由表（可以走原生网络，用来查 DNS、下载更新）
  #    8904/8905 带标记的包：TUNMARK 进隧道表，MARK（回包）查主路由表
  #    8911 IPv6 链路本地/组播地址查主表（邻居发现要用原生网卡）
  #    8915 主路由表里的具体网段（Docker 网桥、内网）优先，但忽略主表的默认路由
  #    8920 其余所有流量查隧道表 24680 → 默认出口是 l2tp-aa
  #    8930 blackhole 兜底，理论上不会走到这里
  # 先装好回包标记，再删旧版规则，保证切换过程中已有的 SSH 不会被送进隧道。
  for key in all default "$NATIVE_IF"; do
    sysctl -w "net.ipv4.conf.$key.rp_filter=0" >/dev/null 2>&1 || true
  done
  render_firewall | nft -f -
  copy_link_routes
  ip -4 route replace prohibit default metric 42700 table "$TABLE"
  install_native_fallback -4
  rule -4 8900 "uidrange $FETCH_UID-$FETCH_UID lookup main" uidrange "$FETCH_UID-$FETCH_UID" table main
  # 8904 排在维护账号规则之后、旧版残留的 8910 规则之前。
  rule -4 8904 "fwmark $TUNMARK lookup $TABLE" fwmark "$TUNMARK" table "$TABLE"
  rule -4 8905 "fwmark $MARK lookup main" fwmark "$MARK" table main
  # suppress_prefixlength 0：查主路由表，但忽略其中的默认路由（0.0.0.0/0），只用具体网段。
  rule -4 8915 "lookup main suppress_prefixlength 0" table main suppress_prefixlength 0
  rule -4 8920 "from all lookup $TABLE" table "$TABLE"
  rule -4 8930 "blackhole" blackhole
  if ipv6_on; then
    ip -6 route replace prohibit default metric 42700 table "$TABLE"
    install_native_fallback -6
    rule -6 8900 "uidrange $FETCH_UID-$FETCH_UID lookup main" uidrange "$FETCH_UID-$FETCH_UID" table main
    rule -6 8904 "fwmark $TUNMARK lookup $TABLE" fwmark "$TUNMARK" table "$TABLE"
    rule -6 8905 "fwmark $MARK lookup main" fwmark "$MARK" table main
    # IPv6 邻居发现（相当于 IPv4 的 ARP）必须走原生网卡，普通 IPv6 仍然被挡住。
    rule -6 8911 'to fe80::/10 lookup main' to fe80::/10 table main
    rule -6 8911 'to ff02::/16 lookup main' to ff02::/16 table main
    rule -6 8915 "lookup main suppress_prefixlength 0" table main suppress_prefixlength 0
    rule -6 8920 "from all lookup $TABLE" table "$TABLE"
    rule -6 8930 "blackhole" blackhole
  fi
  drop_legacy_source_rules
}
# endpoint_route：让发往 L2TP 服务器的包走原生网卡（隧道自己必须从原生网络出去），并刷新备用原生路由。
endpoint_route() {
  route=$(ip -4 route show default table main | awk -v nic="$NATIVE_IF" '{for(i=1;i<NF;i++) if($i=="dev" && $(i+1)==nic) {print; exit}}')
  gateway=$(printf '%s\n' "$route" | awk '{for(i=1;i<NF;i++) if($i=="via") {print $(i+1); exit}}')
  [ -n "$route" ] || fatal '原生默认路由尚未就绪'
  if [ -n "$gateway" ]; then
    ip -4 route replace "$ENDPOINT/32" via "$gateway" dev "$NATIVE_IF" onlink table "$TABLE"
  else
    ip -4 route replace "$ENDPOINT/32" dev "$NATIVE_IF" table "$TABLE"
  fi
  install_native_fallback -4
}
peer_up() {
  # peer_up：pppd 拨通时由 /etc/ppp/ip-up.d/10-l2tp-vps 调用。参数：$1 网卡名 … $6 ipparam。
  # 网卡名是 l2tp-aa 且 ipparam 是 l2tp-vps 才处理，机器上别的 PPP 连接（如 ppp0）不会被误用。
  # 做的事：在隧道表加默认路由 dev l2tp-aa metric 100，从此新连接都走隧道。
  [ "${1:-}" = "$PEER" ] && [ "${6:-}" = "$TAG" ] || return 0
  ip -4 route replace default dev "$PEER" metric 100 table "$TABLE"
  sysctl -w "net.ipv4.conf.$PEER.rp_filter=0" >/dev/null || true
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
  sysctl -w net.ipv4.conf.all.src_valid_mark=0 >/dev/null || true
  peer_v6 "$@"
}
# peer_v6：隧道网卡拿到了全局 IPv6 地址，才让 IPv6 也走隧道；否则 IPv6 保持被挡住。
peer_v6() {
  [ "${1:-}" = "$PEER" ] && [ "${6:-}" = "$TAG" ] || return 0
  if ip -6 addr show dev "$PEER" scope global 2>/dev/null | grep -q 'inet6'; then
    ip -6 route replace default dev "$PEER" metric 100 table "$TABLE"
  fi
}
# peer_down：断线时撤掉隧道默认路由。新连接会被拒绝（断线保护），不会改走原生网卡。
peer_down() {
  [ "${1:-}" = "$PEER" ] && [ "${6:-}" = "$TAG" ] || return 0
  ip -4 route del default dev "$PEER" metric 100 table "$TABLE" 2>/dev/null || true
  ip -6 route del default dev "$PEER" metric 100 table "$TABLE" 2>/dev/null || true
}
# service：重启/停止本项目的拨号服务，兼容 systemd 和 OpenRC。
service() {
  if [ "$INIT" = systemd ]; then systemctl "$1" l2tp-vps.service
  else rc-service l2tp-vps "$1"; fi
}
# worker：用低权限维护账号 l2tp-fetch 运行 root 事先写好的小脚本。
# 只有这个账号被允许在隧道断开时走原生网络查 DNS（53 端口）、访问 HTTPS（443 端口）；
# root 和其他程序都没有这个例外，所以不能借它绕过断线保护。
worker() {
  task=$1
  # 用 sh 去读脚本而不是直接执行：加固过的系统常把 /tmp 设成不允许执行（noexec）。
  su -s /bin/sh -c "/bin/sh $task" l2tp-fetch
}
# resolve：用维护账号向 1.1.1.1 / 9.9.9.9 查询服务器域名，输出一个 IPv4。服务器本来就是 IP 时原样输出。
resolve() {
  case "$SERVER" in *[!0-9.]* ) ;; *) printf '%s\n' "$SERVER"; return;; esac
  tmp=$(mktemp -d /tmp/l2tp-resolve.XXXXXXXX)
  chmod 755 "$tmp"
  cat > "$tmp/worker" <<EOF
#!/bin/sh
timeout 15 nslookup -type=A '$SERVER' 1.1.1.1 2>/dev/null || timeout 15 nslookup -type=A '$SERVER' 9.9.9.9 2>/dev/null
EOF
  chmod 755 "$tmp/worker"
  result=$(worker "$tmp/worker" 2>/dev/null || true)
  rm -rf "$tmp"
  # 如果当前在用的 IP 仍在解析结果里就继续用它，不因为 DNS 返回顺序变了就重新拨号。
  picked=$(printf '%s\n' "$result" | awk '
    function valid(x, a,n,i) { n=split(x,a,"."); if(n!=4)return 0; for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0; return 1 }
    valid($1) { print $1 }
    /^Name:/ { answer=1 }
    answer && /^Address/ { for (i=1; i<=NF; i++) if (valid($i)) print $i }')
  if [ -n "${ENDPOINT:-}" ] && printf '%s\n' "$picked" | grep -Fx -- "$ENDPOINT" >/dev/null; then
    printf '%s\n' "$ENDPOINT"
  else
    printf '%s\n' "$picked" | awk 'NF {print; exit}'
  fi
}
# fetch：用维护账号下载文件（升级用）。只允许本项目官方仓库的地址，防止被拿去下载别的东西。
# 下载的内容先存在维护账号自己的临时目录里，成功后再由 root 复制到目标位置。
fetch() (
  url=$1; dest=$2
  case "$url" in
    https://raw.githubusercontent.com/imthnio/L2TP-VPS/*|https://api.github.com/repos/imthnio/L2TP-VPS/*|https://cdn.jsdelivr.net/gh/imthnio/L2TP-VPS@*|https://github.com/imthnio/L2TP-VPS.git/info/refs?service=git-upload-pack) ;;
    *) fatal '更新下载仅允许本项目官方仓库地址';;
  esac
  case "$url" in *[!A-Za-z0-9:/._?=@%+-]* ) fatal '下载地址包含不支持的字符';; esac
  tmp=$(mktemp -d /tmp/l2tp-fetch.XXXXXXXX)
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  chmod 755 "$tmp"
  mkdir "$tmp/out"
  chown l2tp-fetch "$tmp/out"
  host=${url#https://}; host=${host%%/*}
  cat > "$tmp/worker" <<EOF
#!/bin/sh
answer=\$(timeout 15 nslookup -type=A '$host' 1.1.1.1 2>/dev/null || timeout 15 nslookup -type=A '$host' 9.9.9.9 2>/dev/null)
addr=\$(printf '%s\\n' "\$answer" | awk '/^Name:/ {a=1} a && /^Address/ { for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$/) {print \$i; exit} }')
[ -n "\$addr" ] || exit 1
exec curl --resolve '$host:443:'"\$addr" -4 --noproxy '*' --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 90 --retry 2 -o '$tmp/out/payload' '$url'
EOF
  chmod 755 "$tmp/worker"
  worker "$tmp/worker" || exit 1
  [ -s "$tmp/out/payload" ] || exit 1
  cat "$tmp/out/payload" > "$dest"
)
# legacy_source_rule：检查是否还有旧版留下的"原生 IP 直连"规则。
legacy_source_rule() {
  [ -f "$STATE/native-v4.txt" ] || return 1
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    if ip -4 rule show pref 8910 2>/dev/null | grep -F "from $addr" >/dev/null; then
      return 0
    fi
  done < "$STATE/native-v4.txt"
  [ -f "$STATE/native-v6.txt" ] || return 1
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    if ip -6 rule show pref 8910 2>/dev/null | grep -F "from $addr" >/dev/null; then
      return 0
    fi
  done < "$STATE/native-v6.txt"
  return 1
}
policy_missing() {
  # policy_missing：检查保护是否完整。防火墙表还在，但策略规则被 networkd 等程序删掉的情况也要发现。
  nft list table inet l2tp_vps >/dev/null 2>&1 || return 0
  legacy_source_rule && return 0
  # 8900 丢了时维护账号走不了原生网络，隧道断开后就没法重新解析域名，也没法升级。
  ip -4 rule show pref 8900 | grep -q "uidrange $FETCH_UID-$FETCH_UID" || return 0
  ip -4 rule show pref 8904 | grep -q "fwmark $TUNMARK" || return 0
  ip -4 rule show pref 8905 | grep -q "fwmark $MARK" || return 0
  ip -4 rule show pref 8915 | grep -q suppress_prefixlength || return 0
  ip -4 rule show pref 8920 | grep -q "lookup $TABLE" || return 0
  ip -4 rule show pref 8930 | grep -q blackhole || return 0
  if ipv6_on; then
    ip -6 rule show pref 8900 | grep -q "uidrange $FETCH_UID-$FETCH_UID" || return 0
    ip -6 rule show pref 8904 | grep -q "fwmark $TUNMARK" || return 0
    ip -6 rule show pref 8905 | grep -q "fwmark $MARK" || return 0
    ip -6 rule show pref 8915 | grep -q suppress_prefixlength || return 0
    ip -6 rule show pref 8920 | grep -q "lookup $TABLE" || return 0
    ip -6 rule show pref 8930 | grep -q blackhole || return 0
  fi
  return 1
}
# restore_policy：保护不完整就重新装一遍。
restore_policy() {
  if policy_missing; then
    guard
    endpoint_route
  fi
}
refresh() (
  # refresh：隧道断开时，重新解析服务器域名。IP 变了就更新防火墙、路由和拨号配置，再重启拨号服务。
  # 用 /run 下的目录当锁，避免和正在进行的安装/升级同时改配置；重启后锁自动消失。
  mkdir /run/l2tp-vps-refresh.lock 2>/dev/null || exit 0
  trap 'rmdir /run/l2tp-vps-refresh.lock' EXIT
  # 服务被停止/重启时会收到 TERM；不接住的话 EXIT 不会执行，锁会一直留到重启，域名就再也不会重新解析。
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ ! -d /run/l2tp-vps-install.lock ] || exit 0
  if ip -4 addr show dev "$PEER" 2>/dev/null | grep -q 'inet '; then
    exit 0
  fi
  new=$(resolve)
  if [ -n "$new" ] && [ "$new" != "$ENDPOINT" ]; then
    old=$ENDPOINT
    ENDPOINT=$new
    endpoint_route
    # 先改防火墙和配置文件，最后只重启本项目的拨号服务。
    guard
    sed "s/^ENDPOINT=.*/ENDPOINT=$ENDPOINT/" "$STATE/net.env" > "$STATE/net.env.new"
    chmod 600 "$STATE/net.env.new"
    mv "$STATE/net.env.new" "$STATE/net.env"
    sed "s/^lns = .*/lns = $ENDPOINT/" "$STATE/xl2tpd.conf" > "$STATE/xl2tpd.conf.new"
    mv "$STATE/xl2tpd.conf.new" "$STATE/xl2tpd.conf"
    ip -4 route del "$old/32" table "$TABLE" 2>/dev/null || true
    service restart
  else
    # IP 没变或查不到：原生网关也可能变了，刷新一下服务器路由。
    endpoint_route
  fi
)
# ensure_peer_route：隧道明明在线，但隧道默认路由丢了（比如被别的程序删掉），就补回来。
ensure_peer_route() {
  ip -4 addr show dev "$PEER" 2>/dev/null | grep -q 'inet ' || return 0
  if ! ip -4 route show default table "$TABLE" | grep -q "dev $PEER"; then
    peer_up "$PEER" '' '' '' '' "$TAG"
  fi
}
# watch：l2tp-vps-watch 服务运行的后台巡检循环。
watch() {
  tick=0
  # 只有这个巡检会长期调用 refresh。上一个巡检进程如果被强杀，锁会残留，启动时先清掉。
  rmdir /run/l2tp-vps-refresh.lock 2>/dev/null || true
  while :; do
    sleep 3
    [ ! -f "$STATE/disabled" ] || continue
    tick=$((tick + 3))
    # 每 3 秒看一眼防火墙表还在不在：重启 nftables 服务或执行 nft flush ruleset 会把它清掉，
    # 如果此时隧道正好断开，原生网卡就没有保护了。发现丢了立即补回；平时每 15 秒做一次完整巡检。
    if [ "$tick" -lt 15 ] && nft list table inet l2tp_vps >/dev/null 2>&1; then continue; fi
    tick=0
    (load; refresh; restore_policy; endpoint_route; ensure_peer_route) || true
    # 隧道的 IPv6 地址可能晚一些才分配到，每轮都检查一次。
    peer_v6 "$PEER" '' '' '' '' "$TAG" || true
  done
}
# stop_services：停止并取消开机启动本项目的三个服务。
stop_services() {
  if [ "$INIT" = systemd ]; then
    systemctl disable --now l2tp-vps-watch.service l2tp-vps.service l2tp-vps-guard.service 2>/dev/null || true
    # xl2tpd 收到停止信号时返回 1，systemd 会把服务标成 failed；清掉这个状态，免得看起来像出了故障。
    systemctl reset-failed l2tp-vps-watch.service l2tp-vps.service l2tp-vps-guard.service 2>/dev/null || true
  else
    for s in l2tp-vps-watch l2tp-vps l2tp-vps-guard; do
      rc-service "$s" stop 2>/dev/null || true
      rc-update del "$s" default 2>/dev/null || true
      rc-update del "$s" boot 2>/dev/null || true
    done
  fi
}
remove_routes() {
  # remove_routes：删除本项目加的全部策略规则和隧道表路由。
  # 每条都写完整条件再删，绝不只按优先级删，避免误删别的软件恰好用同一优先级的规则。
  ip -4 rule del pref 8900 uidrange "$FETCH_UID-$FETCH_UID" table main 2>/dev/null || true
  ip -4 rule del pref 8904 fwmark "$TUNMARK" table "$TABLE" 2>/dev/null || true
  ip -4 rule del pref 8905 fwmark "$MARK" table main 2>/dev/null || true
  drop_legacy_source_rules
  ip -4 rule del pref 8915 table main suppress_prefixlength 0 2>/dev/null || true
  ip -4 rule del pref 8920 table "$TABLE" 2>/dev/null || true
  ip -4 rule del pref 8930 blackhole 2>/dev/null || true
  ip -6 rule del pref 8900 uidrange "$FETCH_UID-$FETCH_UID" table main 2>/dev/null || true
  ip -6 rule del pref 8904 fwmark "$TUNMARK" table "$TABLE" 2>/dev/null || true
  ip -6 rule del pref 8905 fwmark "$MARK" table main 2>/dev/null || true
  ip -6 rule del pref 8911 to fe80::/10 table main 2>/dev/null || true
  ip -6 rule del pref 8911 to ff02::/16 table main 2>/dev/null || true
  ip -6 rule del pref 8915 table main suppress_prefixlength 0 2>/dev/null || true
  ip -6 rule del pref 8920 table "$TABLE" 2>/dev/null || true
  ip -6 rule del pref 8930 blackhole 2>/dev/null || true
  ip -4 route show table "$TABLE" dev "$NATIVE_IF" scope link 2>/dev/null | while IFS= read -r line; do
    case "$line" in ''|default*|prohibit*) continue;; esac
    # shellcheck disable=SC2086
    ip -4 route del $line table "$TABLE" 2>/dev/null || true
  done
  ip -6 route show table "$TABLE" dev "$NATIVE_IF" 2>/dev/null | while IFS= read -r line; do
    dest=${line%% *}
    case "$dest" in ''|default|prohibit) continue;; esac
    ip -6 route del "$dest" dev "$NATIVE_IF" table "$TABLE" 2>/dev/null || true
  done
  ip -4 route del default metric 40000 table "$TABLE" 2>/dev/null || true
  ip -6 route del default metric 40000 table "$TABLE" 2>/dev/null || true
  ip -4 route del prohibit default metric 42700 table "$TABLE" 2>/dev/null || true
  ip -6 route del prohibit default metric 42700 table "$TABLE" 2>/dev/null || true
  ip -4 route del "$ENDPOINT/32" table "$TABLE" 2>/dev/null || true
  peer_down "$PEER" '' '' '' '' "$TAG"
}
# legacy_routes：清理旧版（v1）的服务、钩子和路由规则，只在迁移时执行。
legacy_routes() {
  [ -f "$STATE/legacy-pending" ] && [ -f "$STATE/legacy-routes.env" ] || return 0
  . "$STATE/legacy-routes.env"
  if [ "$INIT" = systemd ]; then
    systemctl disable --now l2tp-vless-dial.service l2tp-vless-route.service l2tp-vless-guard.service 2>/dev/null || true
  else
    rc-service l2tp-vless-guard stop 2>/dev/null || true
    rc-update del l2tp-vless-guard boot 2>/dev/null || true
  fi
  rm -f /etc/ppp/ip-up.d/10-vless-egress /etc/ppp/ip-down.d/10-vless-egress /etc/local.d/l2tp-vless.start
  ip -4 rule del pref 9000 from "$LEGACY_IP/32" table main 2>/dev/null || true
  ip -4 rule del pref 10000 table 100 2>/dev/null || true
  ip -6 rule del pref 10000 table 100 2>/dev/null || true
  while IFS= read -r addr; do
    [ -z "$addr" ] || ip -6 rule del pref 9000 from "$addr/128" table main 2>/dev/null || true
  done < "$STATE/legacy-v6.txt"
  ip -4 route del prohibit default metric 42700 table 100 2>/dev/null || true
  ip -6 route del prohibit default metric 42700 table 100 2>/dev/null || true
  ip -4 route del "$LEGACY_ENDPOINT/32" table 100 2>/dev/null || true
}
# restore_dns：/etc/resolv.conf 仍指向本项目的 DNS 文件时，还原安装前备份的原文件。
restore_dns() {
  if [ "$(readlink /etc/resolv.conf 2>/dev/null || true)" = /etc/l2tp-vps-resolv.conf ]; then
    if [ -e "$STATE/resolv.conf.before-v2" ] || [ -L "$STATE/resolv.conf.before-v2" ]; then
      rm -f /etc/resolv.conf
      cp -a "$STATE/resolv.conf.before-v2" /etc/resolv.conf
    fi
  fi
  # 删掉安装时补进 /etc/hosts 的那一行主机名（只认 "# l2tp-vps" 记号，其他行原样保留）。
  if grep -q ' # l2tp-vps$' /etc/hosts 2>/dev/null; then
    { grep -v ' # l2tp-vps$' /etc/hosts || true; } > /etc/hosts.l2tp-vps-new
    cat /etc/hosts.l2tp-vps-new > /etc/hosts
    rm -f /etc/hosts.l2tp-vps-new
  fi
}
# recover：恢复 VPS 原生上网。先写 disabled 标记（开机服务看到它就不启动），停服务、删规则、还原 DNS。
# 账号和备份都保留，重新运行安装命令即可再次启用隧道。
recover() {
  touch "$STATE/disabled"
  stop_services
  remove_routes
  legacy_routes
  restore_dns
  nft delete table inet l2tp_vps 2>/dev/null || true
  rm -f /etc/systemd/networkd.conf.d/l2tp-vps.conf /etc/sysctl.d/99-l2tp-vps.conf
  rmdir /etc/systemd/networkd.conf.d 2>/dev/null || true
  printf '%s\n' '已恢复 VPS 原生出站。L2TP 和断线保护已关闭；账号和备份保留。重新运行安装命令可恢复隧道。'
}
# uninstall（也就是 shanchu）：先 recover，再删掉拨号钩子和服务文件。
uninstall() {
  recover
  for hook in ip-up ip-down ipv6-up ipv6-down; do
    rm -f "/etc/ppp/$hook.d/10-l2tp-vps"
  done
  rm -f /etc/systemd/system/l2tp-vps.service /etc/systemd/system/l2tp-vps-watch.service /etc/systemd/system/l2tp-vps-guard.service
  rm -f /etc/init.d/l2tp-vps /etc/init.d/l2tp-vps-watch /etc/init.d/l2tp-vps-guard
  [ "$INIT" != systemd ] || systemctl daemon-reload
  # recover 已经还原了原来的 resolv.conf；本项目的 DNS 文件没人用了就删掉。
  [ "$(readlink /etc/resolv.conf 2>/dev/null || true)" = /etc/l2tp-vps-resolv.conf ] || rm -f /etc/l2tp-vps-resolv.conf
  # 不卸载 xl2tpd、ppp 等软件包：无法确定别的程序是否也在用。
  # 保留 /etc/l2tp-vless 里的账号和备份（仅 root 可读），方便以后离线恢复或重装。
  rm -f "$STATE/installed-version"
  printf '%s\n' '已卸载本项目服务和网络规则；未卸载共享软件包。账号及备份仍保存在 /etc/l2tp-vless（仅 root 可读）。'
}
# update：升级到 GitHub 上的最新版本，账号自动保留。
# 先问 GitHub API main 分支最新提交的编号，再只从这个固定提交下载 bootstrap.sh（它会校验安装器的 SHA256）。
# 下载走维护账号，所以隧道断开时也能升级。
update() (
  tmp=$(mktemp -d /tmp/l2tp-update.XXXXXXXX)
  trap 'rm -rf "$tmp"' EXIT
  commit=
  if fetch "https://api.github.com/repos/imthnio/L2TP-VPS/commits/main?cb=$(date +%s)" "$tmp/commit.json"; then
    commit=$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$tmp/commit.json" | head -1)
  fi
  # GitHub API 对同一个 IP 每小时只给 60 次，共享 IP 的 NAT 小鸡很容易被限流（返回 403）。
  # 这时改查 git 的引用列表（git clone 也用它），拿到的是同一个 main 提交号，没有这个次数限制。
  if [ "${#commit}" != 40 ] && fetch "https://github.com/imthnio/L2TP-VPS.git/info/refs?service=git-upload-pack" "$tmp/refs"; then
    commit=$(tr -d '\000' < "$tmp/refs" | sed -n 's/^[0-9a-f]\{4\}\([0-9a-f]\{40\}\) refs\/heads\/main$/\1/p' | head -1)
  fi
  [ -n "$commit" ] || fatal '无法确认最新版本（网络错误或 GitHub 限流），未安装缓存旧版'
  [ "${#commit}" = 40 ] || fatal 'GitHub 未返回有效提交'
  case "$commit" in *[!0-9a-f]*) fatal 'GitHub 未返回有效提交';; esac
  fetch "https://raw.githubusercontent.com/imthnio/L2TP-VPS/$commit/bootstrap.sh" "$tmp/bootstrap.sh" ||
    fetch "https://cdn.jsdelivr.net/gh/imthnio/L2TP-VPS@$commit/bootstrap.sh" "$tmp/bootstrap.sh" ||
    fatal '无法下载安装入口'
  sh -n "$tmp/bootstrap.sh"
  sh "$tmp/bootstrap.sh"
)
# rollback：用上一次安装前保存的快照离线回滚（不联网下载任何东西），账号用快照里的。
rollback() {
  [ -f "$STATE/rollback-path" ] || fatal '没有可离线回滚的新版快照；旧版迁移失败请使用 recover'
  previous=$(cat "$STATE/rollback-path")
  case "$previous" in "$STATE"/backups/*) ;; *) fatal '无效的备份路径';; esac
  [ -f "$previous/install.sh" ] || fatal '上一版本安装器不存在'
  # 快照只有 root 能写，比临时下载更可信。
  L2TP_SERVER=$(cat "$previous/server")
  L2TP_USER=$(cat "$previous/user")
  L2TP_PASS=$(cat "$previous/password")
  export L2TP_SERVER L2TP_USER L2TP_PASS
  exec sh "$previous/install.sh"
}
# status：显示版本、隧道地址、隧道路由表、策略规则和防火墙。
status() {
  printf '版本：'; cat "$STATE/installed-version" 2>/dev/null || echo '未完成安装'
  printf '隧道：'; ip -4 -o addr show dev "$PEER" 2>/dev/null || true
  printf '出口路由：\n'; ip -4 route show table "$TABLE" 2>/dev/null || true
  printf '策略规则：\n'
  ip -4 rule show pref 8905 2>/dev/null || true
  ip -4 rule show pref 8920 2>/dev/null || true
  ip -4 rule show pref 8930 2>/dev/null || true
  printf '防火墙：\n'; nft list table inet l2tp_vps 2>/dev/null || true
}
# ---------- 命令入口 ----------
# 下面按第一个参数执行对应功能（不带参数等于 status）。测试会删掉 BEGIN DISPATCH 之后的部分再加载本文件。
# BEGIN DISPATCH
[ "$(id -u)" = 0 ] || fatal '请用 root 或 sudo 运行'
cmd=${1:-status}; shift || true
# 第一次安装如果在写入配置之前就失败，机器上只有 l2tp-vps 而没有 v2-owned，README 的命令会走到 update。
# 这时网络还没被改动，update 也不需要读配置，直接重新走一遍安装入口；否则会一直报"尚未安装新版"。
if [ "$cmd" != update ] || [ -f "$STATE/v2-owned" ]; then load; fi
case "$cmd" in
  legacy-cleanup) legacy_routes;;
  guard) guard;; route) endpoint_route;;
  up) peer_up "$@";; down) peer_down "$@";; v6-up) peer_v6 "$@";;
  v6-down) [ "${1:-}" != "$PEER" ] || [ "${6:-}" != "$TAG" ] || ip -6 route del default dev "$PEER" metric 100 table "$TABLE" 2>/dev/null || true;;
  fetch) [ "$#" = 2 ] || fatal 'fetch 参数错误'; fetch "$@";;
  resolve) resolve;; refresh) refresh;; watch) watch;;
  recover) recover;; uninstall) uninstall;; update) update;; rollback) rollback;; status) status;;
  *) fatal '用法：l2tp-vps status | update | rollback | recover | uninstall';;
esac
L2TP_RUNTIME_EOF
chmod 700 "$RUNTIME.new"
sh -n "$RUNTIME.new"
mv "$RUNTIME.new" "$RUNTIME"
# shanchu（"删除"的拼音）是卸载命令的简写：sudo shanchu 等于 sudo l2tp-vps uninstall。
printf '#!/bin/sh\nexec /usr/local/sbin/l2tp-vps uninstall "$@"\n' > /usr/local/bin/shanchu
chmod 700 /usr/local/bin/shanchu
# ---------- 第 8 步：确定 L2TP 服务器的 IP（ENDPOINT） ----------
# 服务器可以填域名，但防火墙和路由只能写 IP，所以要先把域名解析成 IPv4。
# 升级时先用上次保存的 IP 兜底（隧道断开时本机 DNS 可能暂时不通），稍后再用维护账号重新解析一次。
ENDPOINT=
if [ -f "$STATE/net.env" ]; then
  ENDPOINT=$(value "$STATE/net.env" ENDPOINT)
  [ -n "$ENDPOINT" ] || ENDPOINT=$(value "$STATE/net.env" SERVER_IP)
fi
case "$SERVER" in
  *[!0-9.]* )
    # 先用系统自己的 DNS（getent）；查不到再直接问公共 DNS 1.1.1.1 / 9.9.9.9。
    resolved=$(timeout 15 getent ahostsv4 "$SERVER" 2>/dev/null | awk '
      function valid(x, a,n,i) { n=split(x,a,"."); if(n!=4)return 0; for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0; return 1 }
      valid($1) { print $1; exit }' || true)
    if [ -z "$resolved" ]; then
      resolved=$({ timeout 15 nslookup -type=A "$SERVER" 1.1.1.1 || timeout 15 nslookup -type=A "$SERVER" 9.9.9.9; } 2>/dev/null | awk '
        function valid(x, a,n,i) { n=split(x,a,"."); if(n!=4)return 0; for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0; return 1 }
        /^Name:/ { answer=1 }
        answer && /^Address/ { for (i=1; i<=NF; i++) if (valid($i)) { print $i; exit } }' || true)
    fi
    [ -z "$resolved" ] || ENDPOINT=$resolved;;
  *) ENDPOINT=$SERVER;;
esac
# 旧 IP 只用来先把保护规则搭起来，并不代表域名现在还指向它；正式拨号前会再解析一次。
[ -n "$ENDPOINT" ] || fatal '服务器域名无法解析；尚未启用保护'
printf '%s\n' "$ENDPOINT" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' || fatal '无效的服务器 IPv4'
# 保存本机网络信息（net.env，管理命令每次运行都会读取）和账号（server/user/password 三个文件）。
# native-v4/v6.txt 记下原生 IP，卸载时用来精确删除旧版留下的规则。
printf 'NATIVE_IF=%s\nNATIVE_IP=%s\nENDPOINT=%s\nSERVER=%s\nFETCH_UID=%s\nINIT=%s\n' "$NATIVE_IF" "$NATIVE_IP" "$ENDPOINT" "$SERVER" "$FETCH_UID" "$INIT" > "$STATE/net.env"
ip -4 -o addr show dev "$NATIVE_IF" scope global | awk '{split($4,a,"/");print a[1]}' > "$STATE/native-v4.txt"
ip -6 -o addr show dev "$NATIVE_IF" scope global 2>/dev/null | awk '{split($4,a,"/");print a[1]}' > "$STATE/native-v6.txt"
printf '%s\n' "$SERVER" > "$STATE/server"
printf '%s\n' "$USER_NAME" > "$STATE/user"
printf '%s\n' "$PASSWORD" > "$STATE/password"
touch "$STATE/v2-owned"
chmod 600 "$STATE/net.env" "$STATE/native-v4.txt" "$STATE/native-v6.txt" "$STATE/server" "$STATE/user" "$STATE/password" "$STATE/v2-owned"

# ---------- 第 9 步：写拨号配置 ----------
# 本项目用自己独立的一份 xl2tpd 配置和进程，不碰系统自带的 /etc/xl2tpd/xl2tpd.conf，也不改共享的
# /etc/ppp/chap-secrets，所以不会影响机器上其他 L2TP/PPP 连接。
# xl2tpd.conf 要点：port = 0 让本机随机选一个源端口（不和系统 xl2tpd 抢 1701）；lac 表示"我们是拨号的一方"；
#   lns 是服务器 IP；autodial/redial 表示启动后自动拨号、断了每 10 秒重拨；refuse pap 拒绝明文密码认证。
write_peer() {
  cat > "$STATE/xl2tpd.conf" <<EOF
[global]
port = 0
[lac vps]
lns = $ENDPOINT
autodial = yes
redial = yes
redial timeout = 10
ppp debug = no
pppoptfile = $STATE/options
refuse pap = yes
length bit = yes
EOF
  # options 是 pppd 的参数：接受服务器分配的地址，不自动改系统默认路由（路由由本项目自己管），
  #   每 20 秒发一次心跳、连续 3 次没回应就判定断线，MTU 1400 防止大包在隧道里被截断，网卡名固定为 l2tp-aa，
  #   ipparam l2tp-vps 是个"暗号"，拨号脚本靠它认出这是本项目的连接。
  # 注意：这段用带引号的 heredoc（<<'EOF'），里面的 $ 不会被展开。用户名和密码单独用 printf 写入，
  #   先把 \ 和 " 转义，再用双引号包起来——这样密码里的 $()、反引号、空格等都只是普通字符，不会被执行。
  cat > "$STATE/options" <<'EOF'
ipcp-accept-local
ipcp-accept-remote
noipdefault
refuse-eap
noccp
noauth
nodefaultroute
nodefaultroute6
+ipv6
nobsdcomp
nodeflate
novj
novjccomp
lcp-echo-interval 20
lcp-echo-failure 3
mtu 1400
mru 1400
ifname l2tp-aa
ipparam l2tp-vps
EOF
  user_q=$(printf '%s' "$USER_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
  pass_q=$(printf '%s' "$PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf 'user "%s"\npassword "%s"\n' "$user_q" "$pass_q" >> "$STATE/options"
  chmod 600 "$STATE/xl2tpd.conf" "$STATE/options"
}
write_peer
# ---------- 第 10 步：安装拨号钩子 ----------
# pppd 拨通/断开时会运行 /etc/ppp/ip-up.d/、ip-down.d/ 等目录里的脚本。这里放一个小脚本，
# 让它调用 l2tp-vps up/down，从而在拨通时把默认出口指向隧道、断开时撤掉。
for hook in ip-up ip-down ipv6-up ipv6-down; do
  case "$hook" in ip-up) op=up;; ip-down) op=down;; ipv6-up) op='v6-up';; ipv6-down) op='v6-down';; esac
  printf '#!/bin/sh\nexec /usr/local/sbin/l2tp-vps %s "$@"\n' "$op" > "/etc/ppp/$hook.d/10-l2tp-vps"
  chmod 700 "/etc/ppp/$hook.d/10-l2tp-vps"
  if [ "$INIT" = openrc ]; then
    # Alpine 自带的 /etc/ppp/ip-up 不会去运行 ip-up.d 目录，需要追加几行分发代码。
    # 用户自己改过的脚本如果中途就 exit，追加的代码永远执行不到，所以直接报错让用户处理。
    hf="/etc/ppp/$hook"
    if [ ! -f "$hf" ]; then printf '#!/bin/sh\n' > "$hf"; chmod 755 "$hf"; fi
    if ! grep -q "$hook.d" "$hf"; then
      if grep -Eq '^[[:space:]]*(exit|exec)[[:space:]]' "$hf"; then fatal "自定义 $hf 提前退出，无法安全安装钩子"; fi
      printf '\n# L2TP-VPS dispatcher\nfor hs in /etc/ppp/%s.d/*; do\n  [ ! -x "$hs" ] || "$hs" "$@"\ndone\n' "$hook" >> "$hf"
    fi
  fi
done
# ---------- 第 11 步：注册开机服务 ----------
# l2tp-vps-guard：开机时在网络启动之前先加上断线保护，保证开机那一刻也不会从原生 IP 漏出去。
# l2tp-vps：运行本项目专用的 xl2tpd 负责拨号，进程退出会自动重启。
# l2tp-vps-watch：后台巡检，隧道断开时重新解析服务器域名、补回被别的程序删掉的规则。
# 存在 /etc/l2tp-vless/disabled 文件时（执行过 recover），这三个服务都不会启动。
if [ "$INIT" = systemd ]; then
  cat > /etc/systemd/system/l2tp-vps-guard.service <<'EOF'
[Unit]
Description=L2TP-VPS outbound guard
DefaultDependencies=no
After=local-fs.target nftables.service
Before=network-pre.target
Wants=network-pre.target
ConditionPathExists=!/etc/l2tp-vless/disabled
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/l2tp-vps guard
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/l2tp-vps.service <<'EOF'
[Unit]
Description=Isolated L2TP connection
Requires=l2tp-vps-guard.service
After=l2tp-vps-guard.service network-online.target
Wants=network-online.target
ConditionPathExists=!/etc/l2tp-vless/disabled
[Service]
Type=simple
RuntimeDirectory=l2tp-vps
# systemd-networkd 可能删掉不是它创建的策略路由，所以在网络就绪后再装一次路由规则。
ExecStartPre=/usr/local/sbin/l2tp-vps guard
ExecStartPre=/usr/local/sbin/l2tp-vps route
ExecStart=/usr/sbin/xl2tpd -D -c /etc/l2tp-vless/xl2tpd.conf -p /run/l2tp-vps/xl2tpd.pid -C /run/l2tp-vps/control
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/l2tp-vps-watch.service <<'EOF'
[Unit]
Description=Refresh L2TP endpoint after disconnect
After=l2tp-vps.service
ConditionPathExists=!/etc/l2tp-vless/disabled
[Service]
Type=simple
ExecStart=/usr/local/sbin/l2tp-vps watch
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
  # 告诉 systemd-networkd：别删除不是你创建的路由和策略规则（默认会删，本项目的规则就没了）。
  mkdir -p /etc/systemd/networkd.conf.d
  cat > /etc/systemd/networkd.conf.d/l2tp-vps.conf <<'EOF'
[Network]
ManageForeignRoutingPolicyRules=no
ManageForeignRoutes=no
EOF
  systemctl daemon-reload
else
  # Alpine（OpenRC）版本的三个服务，作用同上。
  cat > /etc/init.d/l2tp-vps-guard <<'EOF'
#!/sbin/openrc-run
name="L2TP-VPS guard"
depend() { after nftables; before net; }
start() { [ -f /etc/l2tp-vless/disabled ] || /usr/local/sbin/l2tp-vps guard; }
EOF
  cat > /etc/init.d/l2tp-vps <<'EOF'
#!/sbin/openrc-run
name="L2TP-VPS"
command="/usr/sbin/xl2tpd"
command_args="-D -c /etc/l2tp-vless/xl2tpd.conf -p /run/l2tp-vps/xl2tpd.pid -C /run/l2tp-vps/control"
supervisor="supervise-daemon"
respawn_delay=10
pidfile="/run/l2tp-vps/supervisor.pid"
depend() { need net l2tp-vps-guard; }
start_pre() { [ ! -f /etc/l2tp-vless/disabled ] && checkpath -d -m 0755 /run/l2tp-vps && /usr/local/sbin/l2tp-vps guard && /usr/local/sbin/l2tp-vps route; }
EOF
  cat > /etc/init.d/l2tp-vps-watch <<'EOF'
#!/sbin/openrc-run
name="L2TP-VPS endpoint watcher"
command="/usr/local/sbin/l2tp-vps"
command_args="watch"
supervisor="supervise-daemon"
respawn_delay=10
pidfile="/run/l2tp-vps-watch.pid"
depend() { need l2tp-vps; }
EOF
  chmod 755 /etc/init.d/l2tp-vps /etc/init.d/l2tp-vps-guard /etc/init.d/l2tp-vps-watch
fi

info '恢复命令已准备好：sudo l2tp-vps recover'
# ---------- 第 12 步：内核参数 ----------
# rp_filter 是"反向路径检查"：收到包时内核会检查"如果我回这个地址，会从同一张网卡出去吗"，不是就丢掉。
# 本项目让回包和新连接走不同路由表，这个检查会误伤正常回包，所以关掉。写进 sysctl.d 是为了重启后仍然生效。
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-l2tp-vps.conf <<'EOF'
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.src_valid_mark=0
EOF
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf.all.src_valid_mark=0 >/dev/null || true
# ---------- 第 13 步：打开断线保护，然后准备拨号 ----------
# guard：装好防火墙和策略路由；route：让发往 L2TP 服务器的包走原生网卡（隧道本身得从原生网卡出去）。
"$RUNTIME" guard
"$RUNTIME" route
# 用维护账号重新解析服务器域名（此时保护已开启，普通程序的 DNS 可能不通，维护账号可以走原生网络）。
# 如果 IP 变了，就更新配置、路由和防火墙。
new=$("$RUNTIME" resolve)
[ -n "$new" ] || fatal '无法解析接入域名；保护保留，可运行 l2tp-vps recover 恢复原生网络'
if [ "$new" != "$ENDPOINT" ]; then
  old_endpoint=$ENDPOINT; ENDPOINT=$new
  sed "s/^ENDPOINT=.*/ENDPOINT=$ENDPOINT/" "$STATE/net.env" > "$STATE/net.env.new"
  mv "$STATE/net.env.new" "$STATE/net.env"
  "$RUNTIME" route
  "$RUNTIME" guard
  ip -4 route del "$old_endpoint/32" table 24680 2>/dev/null || true
  write_peer
fi

# ---------- 第 14 步：从旧版迁移（只有装过旧版才会执行） ----------
# 每一步都有完成标记，中途失败后重跑会从断点继续；只删除确认属于旧版的东西，并还原旧版之前的共享配置。
if [ "$LEGACY" = 1 ]; then
  if [ ! -f "$STATE/legacy-detached" ]; then
    grep -q '^pppoptfile = /etc/ppp/options.l2tp-vless$' /etc/xl2tpd/xl2tpd.conf || fatal '旧 xl2tpd 配置已被修改，拒绝停止其他连接'
    [ "$(grep -Ec '^\[(lac|lns) ' /etc/xl2tpd/xl2tpd.conf)" = 1 ] || fatal '检测到其他 L2TP 连接，拒绝停止共享服务'
    if [ "$INIT" = systemd ]; then systemctl stop xl2tpd; else rc-service xl2tpd stop; fi
    touch "$STATE/legacy-detached"
  fi
  "$RUNTIME" legacy-cleanup
  rm -f /etc/init.d/l2tp-vless-guard
  rm -f /etc/systemd/system/l2tp-vless-dial.service /etc/systemd/system/l2tp-vless-route.service /etc/systemd/system/l2tp-vless-guard.service
  if [ ! -f "$STATE/legacy-restored" ]; then
    if [ -f "$STATE/chap-secrets.before-l2tp-vless" ]; then cp -p "$STATE/chap-secrets.before-l2tp-vless" /etc/ppp/chap-secrets; fi
    if [ -f "$STATE/xl2tpd.conf.before-l2tp-vless" ]; then
      cp -p "$STATE/xl2tpd.conf.before-l2tp-vless" /etc/xl2tpd/xl2tpd.conf
      if [ "$INIT" = systemd ]; then systemctl start xl2tpd; else rc-service xl2tpd start; fi
    else
      rm -f /etc/xl2tpd/xl2tpd.conf
      if [ "$INIT" = systemd ]; then systemctl disable xl2tpd; else rc-update del xl2tpd default; fi
    fi
    touch "$STATE/legacy-restored"
  fi
  rm -f "$STATE/legacy-pending"
fi
# ---------- 第 15 步：DNS ----------
# 把系统 DNS 换成 1.1.1.1 / 9.9.9.9，并让 DNS 查询也走隧道，防止断线后从原生网络查 DNS 泄露访问记录。
# 原来的 /etc/resolv.conf 会先备份，recover/卸载时还原。用"先建新链接再改名"的方式替换，避免中途没有 DNS 文件。
if [ "$(readlink /etc/resolv.conf 2>/dev/null || true)" != /etc/l2tp-vps-resolv.conf ]; then
  # 少数精简系统根本没有 /etc/resolv.conf，没东西可备份就跳过（否则 cp 失败会让安装半途退出）。
  if [ ! -e "$STATE/resolv.conf.before-v2" ] && [ ! -L "$STATE/resolv.conf.before-v2" ] &&
     { [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; }; then
    cp -a /etc/resolv.conf "$STATE/resolv.conf.before-v2"
  fi
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions timeout:2 attempts:2\n' > /etc/l2tp-vps-resolv.conf
  chmod 644 /etc/l2tp-vps-resolv.conf
  ln -s /etc/l2tp-vps-resolv.conf /etc/resolv.conf.l2tp-vps-new
  mv -f /etc/resolv.conf.l2tp-vps-new /etc/resolv.conf
fi
# Ubuntu 云镜像的 /etc/hosts 里没有本机主机名，以前全靠 systemd-resolved（127.0.0.53）顺带解析。
# 换成 1.1.1.1 以后主机名就查不到了：每次 sudo 都会报 "unable to resolve host"，隧道断开时还要卡几秒，
# 主机名也会被发到公网 DNS。所以系统没有 myhostname 兜底、/etc/hosts 里也没有它时，补一行 127.0.1.1
# （Debian 系的惯例写法），末尾带 "# l2tp-vps" 记号；recover / 卸载时只删这一行。
host_name=$(hostname 2>/dev/null || true)
case "$host_name" in
  ''|*[!A-Za-z0-9.-]*) ;;
  *)
    if ! grep -Eq '^hosts:.*myhostname' /etc/nsswitch.conf 2>/dev/null &&
       ! awk -v h="$host_name" '$1 !~ /^#/ {for(i=2;i<=NF;i++){if($i ~ /^#/)break; if($i==h)f=1}} END{exit !f}' /etc/hosts 2>/dev/null; then
      printf '127.0.1.1 %s # l2tp-vps\n' "$host_name" >> /etc/hosts
    fi;;
esac
# ---------- 第 16 步：启动服务并开始拨号 ----------
# 删除 disabled 标记（执行 recover 时留下的），设置开机启动并重启三个服务。升级时隧道会短暂中断。
rm -f "$STATE/disabled"
if [ "$INIT" = systemd ]; then
  systemctl daemon-reload
  systemctl enable l2tp-vps-guard.service l2tp-vps.service l2tp-vps-watch.service
  systemctl restart l2tp-vps-guard.service l2tp-vps.service l2tp-vps-watch.service
else
  rc-update add l2tp-vps-guard boot
  rc-update add l2tp-vps default
  rc-update add l2tp-vps-watch default
  rc-service l2tp-vps restart || rc-service l2tp-vps start
  rc-service l2tp-vps-watch restart || rc-service l2tp-vps-watch start
fi
# 每秒检查一次：隧道网卡拿到了 IPv4，而且去往 1.1.1.1 的路由确实走隧道网卡，才算拨通。
info '等待 L2TP 连接（最多 90 秒）'
connected=0
for _attempt in $(seq 1 90); do
  if ip -4 addr show dev "$PEER" 2>/dev/null | grep -q 'inet ' && ip -4 route get 1.1.1.1 2>/dev/null | grep -q "dev $PEER"; then connected=1; break; fi
  sleep 1
done
[ "$connected" = 1 ] || fatal 'L2TP 90 秒内没有拨通。请检查：服务器地址、用户名密码、服务商是否放行 UDP 1701。拨号日志：journalctl -u l2tp-vps -n 50（Alpine 看 /var/log/messages）。拨号失败不一定是账号欠费。账号填错了就重新运行安装命令，按提示输入 y 重新填写。'
# ---------- 第 17 步：验收（全部通过才算安装成功） ----------
# 1. 访问"查询我的 IP"网站，看公网出口是不是已经不是 VPS 原生 IP。
out=$(curl -4 --noproxy '*' -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org || curl -4 --noproxy '*' -fsS --connect-timeout 10 --max-time 20 https://ifconfig.me || true)
out=$(printf '%s' "$out" | tr -d '[:space:]')
if ! printf '%s\n' "$out" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}'; then
  # 隧道通了但 DNS 暂时不通时，换一个直接用 IP 访问的地址再查一次出口。
  trace=$(curl -4 --noproxy '*' -kfsS --connect-timeout 10 --max-time 20 https://1.1.1.1/cdn-cgi/trace || true)
  out=$(printf '%s\n' "$trace" | awk -F= '$1=="ip" {print $2; exit}')
  out=$(printf '%s' "$out" | tr -d '[:space:]')
fi
printf '%s\n' "$out" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' || fatal '隧道出口验证没有返回有效 IPv4（可能是 DNS、MTU、防火墙或服务端问题）'
[ "$out" != "$NATIVE_IP" ] || fatal '出口仍为 VPS 原生地址；未标记升级成功'
# 2. 确认出站路由走隧道网卡，源地址是隧道地址。
#    有的服务商会对隧道做 NAT（地址转换），公网出口 IP 和隧道网卡上的 IP 不一样，这是正常的。
route_line=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
printf '%s\n' "$route_line" | grep -q "dev $PEER" || fatal '出站没有走隧道；未标记升级成功'
route_src=$(printf '%s\n' "$route_line" | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')
peer_ip=$(ip -4 -o addr show dev "$PEER" | awk '{split($4,a,"/");print a[1];exit}')
[ -n "$peer_ip" ] || fatal '隧道没有 IPv4 地址；未标记升级成功'
if [ -n "$route_src" ] && [ "$route_src" != "$peer_ip" ]; then
  fatal '出站源地址不是隧道地址；未标记升级成功'
fi
# 3. 很多节点程序会"绑定"VPS 原生 IP 发起连接。确认这种连接也会被改走隧道，出口同样不是原生 IP。
from_native=$(ip -4 route get 1.1.1.1 from "$NATIVE_IP" 2>/dev/null || true)
printf '%s\n' "$from_native" | grep -q "dev $PEER" || fatal '绑定 VPS 原地址的连接没有走 L2TP；节点出口会仍是 VPS'
bound=$(curl -4 --noproxy '*' --interface "$NATIVE_IP" -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org || curl -4 --noproxy '*' --interface "$NATIVE_IP" -fsS --connect-timeout 10 --max-time 20 https://ifconfig.me || true)
bound=$(printf '%s' "$bound" | tr -d '[:space:]')
printf '%s\n' "$bound" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' || fatal '绑定 VPS 原地址后无法经隧道访问外网'
[ "$bound" != "$NATIVE_IP" ] || fatal '绑定 VPS 原地址的连接出口仍是 VPS'
# 4. 如果 VPS 有原生 IPv6，确认 IPv6 不会从原生地址出去。
v6=$(awk 'NF {print; exit}' "$STATE/native-v6.txt" 2>/dev/null || true)
if [ -n "$v6" ]; then
  v6out=$(curl -6 --noproxy '*' --interface "$v6" -fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org || true)
  v6out=$(printf '%s' "$v6out" | tr -d '[:space:]')
  [ "$v6out" != "$v6" ] || fatal 'IPv6 仍从 VPS 原生地址出去'
fi
# 全部通过：记下版本号，保存这份安装器（以后 rollback 用），打印结果。SUCCESS=1 让 finish 不再报失败。
printf '%s\n' "$VERSION" > "$STATE/installed-version"
if [ -f "$0" ]; then cp "$0" "$STATE/install.sh"; chmod 600 "$STATE/install.sh"; fi
info "安装/升级成功：${VERSION}；公网出口 ${out}，不是 VPS 原生地址"
info "本机新连接和节点出站都走 L2TP。SSH 与节点端口仍使用 VPS 原地址 ${NATIVE_IP}。"
info '以后重复运行 README 安装命令，或运行 sudo l2tp-vps update，即可升级并保留账号。'
info '状态：sudo l2tp-vps status；恢复原生网络：sudo l2tp-vps recover；卸载：sudo shanchu'
SUCCESS=1
