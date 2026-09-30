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
VERSION=2.0.5
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
  old_pass=$(awk -v user="${L2TP_USER:-$old_user}" '
    function token(    c,s,quoted) {
      sub(/^[ \t]+/, "", line); s=""; quoted=(substr(line,1,1)=="\""); if(quoted)line=substr(line,2);
      while(length(line)) { c=substr(line,1,1); line=substr(line,2);
        if(c=="\\") { if(!length(line))exit 2; s=s substr(line,1,1); line=substr(line,2) }
        else if(quoted && c=="\"") return s;
        else if(!quoted && c~/[ \t]/) return s;
        else s=s c;
      } if(quoted)exit 2; return s
    }
    {line=$0; u=token(); server=token(); password=token(); if(u==user && server=="*"){print password; found++;}}
    END {if(found!=1)exit 2}' /etc/ppp/chap-secrets 2>/dev/null) || fatal '无法无歧义读取旧密码；请用 L2TP_USER/L2TP_PASS 环境变量明确提供账号，或先保留旧配置联系维护者'
  fi
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
@@RUNTIME@@
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
  if [ ! -e "$STATE/resolv.conf.before-v2" ] && [ ! -L "$STATE/resolv.conf.before-v2" ]; then
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
[ "$connected" = 1 ] || fatal 'L2TP 90 秒内没有拨通。请检查：服务器地址、用户名密码、服务商是否放行 UDP 1701。拨号日志：journalctl -u l2tp-vps -n 50（Alpine 看 /var/log/messages）。拨号失败不一定是账号欠费。'
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
