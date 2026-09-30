#!/bin/sh
# L2TP-VPS installer; generated with tools/build.py. Download this file, then run sh.
set -eu
trap '' HUP
VERSION=2.0.5
case "${1:-}" in --version) echo "$VERSION"; exit 0;; esac
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
STATE=/etc/l2tp-vless
RUNTIME=/usr/local/sbin/l2tp-vps
PEER=l2tp-aa
LEGACY=0
SUCCESS=0
BACKUP=
fatal() { printf '[出错] %s\n' "$*" >&2; exit 1; }
info() { printf '[L2TP-VPS] %s\n' "$*"; }
[ "$(uname -s)" = Linux ] || fatal '只支持 Linux VPS'
[ "$(id -u)" = 0 ] || fatal '请用 root 或 sudo 运行'
[ -f /etc/alpine-release ] && INIT=openrc || INIT=systemd
if [ "$INIT" = systemd ]; then
  [ -f /etc/debian_version ] && [ -d /run/systemd/system ] || fatal '需要 Debian/Ubuntu 和运行中的 systemd'
else
  command -v rc-service >/dev/null || fatal '需要 OpenRC'
fi
mkdir -p /run
mkdir /run/l2tp-vps-install.lock 2>/dev/null || fatal '另一个安装/升级正在进行。若确认上次已被强制终止，运行 sudo rmdir /run/l2tp-vps-install.lock 后重试（重启也会清掉）'
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

# Read old values as data; never source passwords or untrusted shell assignments.
value() { sed -n "s/^$2=//p" "$1" | head -1; }
if [ -f "$STATE/net.env" ] && [ ! -f "$STATE/v2-owned" ]; then LEGACY=1; fi
[ ! -f "$STATE/legacy-pending" ] || LEGACY=1
old_server=; old_user=; old_pass=
if [ -f "$STATE/password" ]; then
  old_server=$(cat "$STATE/server"); old_user=$(cat "$STATE/user"); old_pass=$(cat "$STATE/password")
elif [ "$LEGACY" = 1 ]; then
  old_server=$(value "$STATE/net.env" SERVER_IP)
  old_user=$(awk '$1=="name" {print $2; exit}' /etc/ppp/options.l2tp-vless 2>/dev/null || true)
  # Parse only the escaped quoted format produced by v1. Ambiguity fails closed.
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
SERVER=${L2TP_SERVER:-$old_server}
USER_NAME=${L2TP_USER:-$old_user}
PASSWORD=${L2TP_PASS:-$old_pass}
ask() {
  [ -t 0 ] || fatal "缺少 $1；无终端时通过对应 L2TP_* 环境变量传入"
  printf '%s: ' "$1"
  IFS= read -r answer || fatal '输入已取消'
}
[ -n "$SERVER" ] || { ask 'L2TP 服务器（域名或 IPv4）'; SERVER=$answer; }
[ -n "$USER_NAME" ] || { ask 'L2TP 用户名'; USER_NAME=$answer; }
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
case "$SERVER" in ''|*[!A-Za-z0-9.-]*|-*) fatal '服务器必须是域名或 IPv4';; esac
# Usernames are provider-defined. Keep them out of the shell; pppd gets a quoted word.
[ -n "$USER_NAME" ] && [ "$USER_NAME" = "$(printf '%s' "$USER_NAME" | tr -d '\r\n')" ] || fatal '用户名为空或包含换行'
[ -n "$PASSWORD" ] && [ "$PASSWORD" = "$(printf '%s' "$PASSWORD" | tr -d '\r\n')" ] || fatal '密码为空或包含换行'
info "准备安装/升级至 ${VERSION}；已有账号会自动复用"
if [ "$LEGACY" = 1 ] && [ ! -f "$STATE/legacy-routes.env" ]; then
  printf 'LEGACY_IP=%s\nLEGACY_ENDPOINT=%s\n' "$(value "$STATE/net.env" NATIVE_IP)" "$(value "$STATE/net.env" SERVER_IP)" > "$STATE/legacy-routes.env"
  cp "$STATE/native-v6.txt" "$STATE/legacy-v6.txt" 2>/dev/null || : > "$STATE/legacy-v6.txt"
  touch "$STATE/legacy-pending"
fi
if [ "$LEGACY" = 1 ] && [ -z "${L2TP_SERVER:-}" ]; then
  info '旧版只保存了服务器 IP；本次保留该 IP。若接入点是域名，希望断线后重新解析，请设置 L2TP_SERVER=你的域名 后再次升级。'
fi

if [ "$LEGACY" = 1 ] && [ ! -f "$STATE/legacy-detached" ]; then
  grep -q '^pppoptfile = /etc/ppp/options.l2tp-vless$' /etc/xl2tpd/xl2tpd.conf || fatal '旧配置已被修改，拒绝接管共享服务'
  [ "$(grep -Ec '^\[(lac|lns) ' /etc/xl2tpd/xl2tpd.conf)" = 1 ] || fatal '旧配置包含其他 L2TP 连接，需先人工分离'
fi

# Dependencies are never purged by our uninstaller.
need=0
for binary in curl ip nft xl2tpd pppd su nslookup timeout; do command -v "$binary" >/dev/null 2>&1 || need=1; done
if [ "$need" = 1 ]; then
  if [ "$INIT" = openrc ]; then
    apk add --no-cache curl ca-certificates iproute2 nftables xl2tpd ppp bind-tools || fatal '依赖安装失败；尚未切换网络'
  else
    export DEBIAN_FRONTEND=noninteractive
    # A broken third-party source must not abort before the official packages are tried.
    apt-get -o DPkg::Lock::Timeout=120 update || info 'apt-get update 有报错（常见于失效的第三方源），继续尝试安装依赖'
    apt-get -o DPkg::Lock::Timeout=120 install -y curl ca-certificates iproute2 nftables xl2tpd ppp dnsutils || fatal '依赖安装失败；尚未切换网络。请先修复 apt 软件源后重试（Ubuntu 的 xl2tpd 在 universe 源，可先运行 add-apt-repository universe）'
    unset DEBIAN_FRONTEND
  fi
fi
for binary in curl ip nft xl2tpd pppd su nslookup timeout; do command -v "$binary" >/dev/null || fatal "缺少 $binary"; done
modprobe ppp_generic 2>/dev/null || true
[ -c /dev/ppp ] || mknod /dev/ppp c 108 0 2>/dev/null || true
[ -c /dev/ppp ] || fatal 'VPS 不支持 PPP；需由商家启用 /dev/ppp'
# A node can exist while the kernel has no PPP driver (open fails with ENXIO).
( : <>/dev/ppp ) 2>/dev/null || fatal 'VPS 不支持 PPP：/dev/ppp 无法打开（内核或容器没有开放 PPP）；需由商家启用'
# Reserve only an unused namespace on first migration; never flush somebody else's table.
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
route=$(ip -4 route show default table main | awk '$0 !~ / dev (ppp|l2tp-aa)/ {print; exit}')
NATIVE_IF=$(printf '%s\n' "$route" | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
case "$NATIVE_IF" in ''|*[!A-Za-z0-9_.:-]*) fatal '找不到有效原生网卡';; esac
NATIVE_IP=$(ip -4 -o addr show dev "$NATIVE_IF" scope global | awk 'NR==1{split($4,a,"/");print a[1]}')
[ -n "$NATIVE_IP" ] || fatal '原生网卡没有 IPv4'
# Store an immutable root-only snapshot before changing any existing project files.
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

# Recovery is installed before activating rules or dialing. Keep a copy of this
# self-contained installer for future offline rollback; never read via stdin.
cat > "$RUNTIME.new" <<'L2TP_RUNTIME_EOF'
#!/bin/sh
# L2TP-VPS runtime. Only this project's table, chains, service and peer are owned.
set -eu
trap '' HUP
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
STATE=/etc/l2tp-vless
TABLE=24680
MARK=0x24680
TUNMARK=0x24681
PEER=l2tp-aa
TAG=l2tp-vps
fatal() { printf '%s\n' "$*" >&2; exit 1; }
load() { [ -f "$STATE/v2-owned" ] || fatal '尚未安装新版'; . "$STATE/net.env"; }
ipv6_on() { [ -e /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" != 1 ]; }
render_firewall() {
  # Replies are marked so a second lookup sends them out the native NIC.
  # New connections are not marked: rule 8920 already selects the tunnel table,
  # and marking them again drops the maintenance UID on the second lookup.
  cat <<EOF
add table inet l2tp_vps
flush table inet l2tp_vps
table inet l2tp_vps {
  chain l2tp_route {
    type route hook output priority 300; policy accept;
    ct direction reply meta mark set $MARK
  }
  chain l2tp_bridge {
    # Replies forwarded from Docker bridges, wg0 etc. go back the way they came in.
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
    # Other local interfaces (Docker bridges, private NICs, wg0) are not the native exit.
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
rule() {
  family=$1; pref=$2; match=$3; shift 3
  if ! ip "$family" rule show pref "$pref" | grep -F -- "$match" >/dev/null; then
    ip "$family" rule add pref "$pref" "$@"
  fi
}
drop_legacy_source_rules() {
  # Old builds sent every packet sourced from the VPS address out the native NIC.
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
  # IPv6 connected prefixes are scope global. Copy only the prefix and device;
  # proto, metric and pref from "ip route show" are rejected by route replace.
  family=$1
  ip "$family" route show table main dev "$NATIVE_IF" 2>/dev/null | while IFS= read -r line; do
    dest=${line%% *}
    case "$dest" in ''|default*|nexthop|broadcast|local|any|throw|prohibit|unreachable|blackhole) continue;; esac
    # A gatewayed route copied as "dev" only would become a wrong on-link route.
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
  # A usable route must exist before the output hook runs. Otherwise an SSH
  # reply is rejected by prohibit and the session dies before it can be
  # marked and sent back out the native NIC. Metric 40000 loses to the
  # tunnel route at metric 100. The output filter still rejects new
  # connections that take this fallback.
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
  # nft submits the whole replacement as one atomic transaction.
  # Install the reply mark before removing the old "from native address" rule,
  # so an existing SSH session is not sent into the tunnel in between.
  # Policy routing makes the reverse-path check drop replies from the public Internet.
  for key in all default "$NATIVE_IF"; do
    sysctl -w "net.ipv4.conf.$key.rp_filter=0" >/dev/null 2>&1 || true
  done
  render_firewall | nft -f -
  copy_link_routes
  ip -4 route replace prohibit default metric 42700 table "$TABLE"
  install_native_fallback -4
  rule -4 8900 "uidrange $FETCH_UID-$FETCH_UID lookup main" uidrange "$FETCH_UID-$FETCH_UID" table main
  # 8904 is after the maintenance UID rule and before any leftover "from native address" rule.
  rule -4 8904 "fwmark $TUNMARK lookup $TABLE" fwmark "$TUNMARK" table "$TABLE"
  rule -4 8905 "fwmark $MARK lookup main" fwmark "$MARK" table main
  # Specific main-table routes (Docker bridges, private LANs) win; default routes do not.
  rule -4 8915 "lookup main suppress_prefixlength 0" table main suppress_prefixlength 0
  rule -4 8920 "from all lookup $TABLE" table "$TABLE"
  rule -4 8930 "blackhole" blackhole
  if ipv6_on; then
    ip -6 route replace prohibit default metric 42700 table "$TABLE"
    install_native_fallback -6
    rule -6 8900 "uidrange $FETCH_UID-$FETCH_UID lookup main" uidrange "$FETCH_UID-$FETCH_UID" table main
    rule -6 8904 "fwmark $TUNMARK lookup $TABLE" fwmark "$TUNMARK" table "$TABLE"
    rule -6 8905 "fwmark $MARK lookup main" fwmark "$MARK" table main
    # Neighbour discovery needs the native link while ordinary IPv6 stays closed.
    rule -6 8911 'to fe80::/10 lookup main' to fe80::/10 table main
    rule -6 8911 'to ff02::/16 lookup main' to ff02::/16 table main
    rule -6 8915 "lookup main suppress_prefixlength 0" table main suppress_prefixlength 0
    rule -6 8920 "from all lookup $TABLE" table "$TABLE"
    rule -6 8930 "blackhole" blackhole
  fi
  drop_legacy_source_rules
}
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
  # Both the independent interface name AND pppd ipparam must match.
  [ "${1:-}" = "$PEER" ] && [ "${6:-}" = "$TAG" ] || return 0
  ip -4 route replace default dev "$PEER" metric 100 table "$TABLE"
  sysctl -w "net.ipv4.conf.$PEER.rp_filter=0" >/dev/null || true
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
  sysctl -w net.ipv4.conf.all.src_valid_mark=0 >/dev/null || true
  peer_v6 "$@"
}
peer_v6() {
  [ "${1:-}" = "$PEER" ] && [ "${6:-}" = "$TAG" ] || return 0
  if ip -6 addr show dev "$PEER" scope global 2>/dev/null | grep -q 'inet6'; then
    ip -6 route replace default dev "$PEER" metric 100 table "$TABLE"
  fi
}
peer_down() {
  [ "${1:-}" = "$PEER" ] && [ "${6:-}" = "$TAG" ] || return 0
  ip -4 route del default dev "$PEER" metric 100 table "$TABLE" 2>/dev/null || true
  ip -6 route del default dev "$PEER" metric 100 table "$TABLE" 2>/dev/null || true
}
service() {
  if [ "$INIT" = systemd ]; then systemctl "$1" l2tp-vps.service
  else rc-service l2tp-vps "$1"; fi
}
# Run only a root-created, immutable worker as an unprivileged account. That UID
# has native DNS/HTTPS access; ordinary root/apps have NO such exception.
worker() {
  task=$1
  # Run through sh: /tmp is often mounted noexec on hardened VPS images.
  su -s /bin/sh -c "/bin/sh $task" l2tp-fetch
}
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
  # Keep the current address when it is still published. Record order alone must not reconnect.
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
fetch() (
  url=$1; dest=$2
  case "$url" in
    https://raw.githubusercontent.com/imthnio/L2TP-VPS/*|https://api.github.com/repos/imthnio/L2TP-VPS/*|https://cdn.jsdelivr.net/gh/imthnio/L2TP-VPS@*) ;;
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
  # nft can still be present after a reboot while the policy rules are gone.
  nft list table inet l2tp_vps >/dev/null 2>&1 || return 0
  legacy_source_rule && return 0
  ip -4 rule show pref 8904 | grep -q "fwmark $TUNMARK" || return 0
  ip -4 rule show pref 8905 | grep -q "fwmark $MARK" || return 0
  ip -4 rule show pref 8915 | grep -q suppress_prefixlength || return 0
  ip -4 rule show pref 8920 | grep -q "lookup $TABLE" || return 0
  ip -4 rule show pref 8930 | grep -q blackhole || return 0
  if ipv6_on; then
    ip -6 rule show pref 8904 | grep -q "fwmark $TUNMARK" || return 0
    ip -6 rule show pref 8905 | grep -q "fwmark $MARK" || return 0
    ip -6 rule show pref 8915 | grep -q suppress_prefixlength || return 0
    ip -6 rule show pref 8920 | grep -q "lookup $TABLE" || return 0
    ip -6 rule show pref 8930 | grep -q blackhole || return 0
  fi
  return 1
}
restore_policy() {
  if policy_missing; then
    guard
    endpoint_route
  fi
}
refresh() (
  # Serialize endpoint changes with upgrades; stale /run locks vanish on reboot.
  mkdir /run/l2tp-vps-refresh.lock 2>/dev/null || exit 0
  trap 'rmdir /run/l2tp-vps-refresh.lock' EXIT
  [ ! -d /run/l2tp-vps-install.lock ] || exit 0
  if ip -4 addr show dev "$PEER" 2>/dev/null | grep -q 'inet '; then
    exit 0
  fi
  new=$(resolve)
  if [ -n "$new" ] && [ "$new" != "$ENDPOINT" ]; then
    old=$ENDPOINT
    ENDPOINT=$new
    endpoint_route
    # Replace the firewall and disk config before restarting only our daemon.
    guard
    sed "s/^ENDPOINT=.*/ENDPOINT=$ENDPOINT/" "$STATE/net.env" > "$STATE/net.env.new"
    chmod 600 "$STATE/net.env.new"
    mv "$STATE/net.env.new" "$STATE/net.env"
    sed "s/^lns = .*/lns = $ENDPOINT/" "$STATE/xl2tpd.conf" > "$STATE/xl2tpd.conf.new"
    mv "$STATE/xl2tpd.conf.new" "$STATE/xl2tpd.conf"
    ip -4 route del "$old/32" table "$TABLE" 2>/dev/null || true
    service restart
  else
    # Same or unknown address: the native gateway may still have moved.
    endpoint_route
  fi
)
ensure_peer_route() {
  ip -4 addr show dev "$PEER" 2>/dev/null | grep -q 'inet ' || return 0
  if ! ip -4 route show default table "$TABLE" | grep -q "dev $PEER"; then
    peer_up "$PEER" '' '' '' '' "$TAG"
  fi
}
watch() {
  tick=0
  while :; do
    sleep 3
    [ ! -f "$STATE/disabled" ] || continue
    tick=$((tick + 3))
    # "nft flush ruleset" (e.g. restarting nftables.service) removes the guard. While the
    # tunnel is down that opens native egress, so check for it every 3 seconds.
    if [ "$tick" -lt 15 ] && nft list table inet l2tp_vps >/dev/null 2>&1; then continue; fi
    tick=0
    (load; refresh; restore_policy; endpoint_route; ensure_peer_route) || true
    # A late global IPv6 assignment must not depend on a 10-second polling window.
    peer_v6 "$PEER" '' '' '' '' "$TAG" || true
  done
}
stop_services() {
  if [ "$INIT" = systemd ]; then
    systemctl disable --now l2tp-vps-watch.service l2tp-vps.service l2tp-vps-guard.service 2>/dev/null || true
    # xl2tpd exits 1 on SIGTERM; do not leave a stopped service marked "failed".
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
  # Full selectors are intentional. Never delete rules by priority alone.
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
restore_dns() {
  if [ "$(readlink /etc/resolv.conf 2>/dev/null || true)" = /etc/l2tp-vps-resolv.conf ]; then
    if [ -e "$STATE/resolv.conf.before-v2" ] || [ -L "$STATE/resolv.conf.before-v2" ]; then
      rm -f /etc/resolv.conf
      cp -a "$STATE/resolv.conf.before-v2" /etc/resolv.conf
    fi
  fi
}
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
uninstall() {
  recover
  for hook in ip-up ip-down ipv6-up ipv6-down; do
    rm -f "/etc/ppp/$hook.d/10-l2tp-vps"
  done
  rm -f /etc/systemd/system/l2tp-vps.service /etc/systemd/system/l2tp-vps-watch.service /etc/systemd/system/l2tp-vps-guard.service
  rm -f /etc/init.d/l2tp-vps /etc/init.d/l2tp-vps-watch /etc/init.d/l2tp-vps-guard
  [ "$INIT" != systemd ] || systemctl daemon-reload
  # restore_dns has put the original resolv.conf back; drop our copy unless still linked.
  [ "$(readlink /etc/resolv.conf 2>/dev/null || true)" = /etc/l2tp-vps-resolv.conf ] || rm -f /etc/l2tp-vps-resolv.conf
  # Keep dependencies: ownership of distro packages cannot be safely inferred.
  # Keep root-only backups and the state for offline recovery and reinstallation.
  rm -f "$STATE/installed-version"
  printf '%s\n' '已卸载本项目服务和网络规则；未卸载共享软件包。账号及备份仍保存在 /etc/l2tp-vless（仅 root 可读）。'
}
update() (
  tmp=$(mktemp -d /tmp/l2tp-update.XXXXXXXX)
  trap 'rm -rf "$tmp"' EXIT
  fetch "https://api.github.com/repos/imthnio/L2TP-VPS/commits/main?cb=$(date +%s)" "$tmp/commit.json" || fatal '无法确认最新版本（网络错误或 GitHub API 限流），未安装缓存旧版'
  commit=$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$tmp/commit.json" | head -1)
  [ "${#commit}" = 40 ] || fatal 'GitHub 未返回有效提交'
  case "$commit" in *[!0-9a-f]*) fatal 'GitHub 未返回有效提交';; esac
  fetch "https://raw.githubusercontent.com/imthnio/L2TP-VPS/$commit/bootstrap.sh" "$tmp/bootstrap.sh" ||
    fetch "https://cdn.jsdelivr.net/gh/imthnio/L2TP-VPS@$commit/bootstrap.sh" "$tmp/bootstrap.sh" ||
    fatal '无法下载安装入口'
  sh -n "$tmp/bootstrap.sh"
  sh "$tmp/bootstrap.sh"
)
rollback() {
  [ -f "$STATE/rollback-path" ] || fatal '没有可离线回滚的新版快照；旧版迁移失败请使用 recover'
  previous=$(cat "$STATE/rollback-path")
  case "$previous" in "$STATE"/backups/*) ;; *) fatal '无效的备份路径';; esac
  [ -f "$previous/install.sh" ] || fatal '上一版本安装器不存在'
  # The snapshot was created root-only; never download code during rollback.
  L2TP_SERVER=$(cat "$previous/server")
  L2TP_USER=$(cat "$previous/user")
  L2TP_PASS=$(cat "$previous/password")
  export L2TP_SERVER L2TP_USER L2TP_PASS
  exec sh "$previous/install.sh"
}
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
# Tests source this file after removing ONLY this dispatch section.
# BEGIN DISPATCH
[ "$(id -u)" = 0 ] || fatal '请用 root 或 sudo 运行'
load
cmd=${1:-status}; shift || true
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
printf '#!/bin/sh\nexec /usr/local/sbin/l2tp-vps uninstall "$@"\n' > /usr/local/bin/shanchu
chmod 700 /usr/local/bin/shanchu
# Prefer saved endpoint when upgrading offline; refresh it through maintenance UID later.
ENDPOINT=
if [ -f "$STATE/net.env" ]; then
  ENDPOINT=$(value "$STATE/net.env" ENDPOINT)
  [ -n "$ENDPOINT" ] || ENDPOINT=$(value "$STATE/net.env" SERVER_IP)
fi
case "$SERVER" in
  *[!0-9.]* )
    # getent uses the VPS resolver and may be missing. A public resolver is the fallback.
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
# An old endpoint is safe for bootstrapping maintenance DNS; it is NOT proof the
# domain still resolves to it. Resolve again before the first dial below.
[ -n "$ENDPOINT" ] || fatal '服务器域名无法解析；尚未启用保护'
printf '%s\n' "$ENDPOINT" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' || fatal '无效的服务器 IPv4'
printf 'NATIVE_IF=%s\nNATIVE_IP=%s\nENDPOINT=%s\nSERVER=%s\nFETCH_UID=%s\nINIT=%s\n' "$NATIVE_IF" "$NATIVE_IP" "$ENDPOINT" "$SERVER" "$FETCH_UID" "$INIT" > "$STATE/net.env"
ip -4 -o addr show dev "$NATIVE_IF" scope global | awk '{split($4,a,"/");print a[1]}' > "$STATE/native-v4.txt"
ip -6 -o addr show dev "$NATIVE_IF" scope global 2>/dev/null | awk '{split($4,a,"/");print a[1]}' > "$STATE/native-v6.txt"
printf '%s\n' "$SERVER" > "$STATE/server"
printf '%s\n' "$USER_NAME" > "$STATE/user"
printf '%s\n' "$PASSWORD" > "$STATE/password"
touch "$STATE/v2-owned"
chmod 600 "$STATE/net.env" "$STATE/native-v4.txt" "$STATE/native-v6.txt" "$STATE/server" "$STATE/user" "$STATE/password" "$STATE/v2-owned"

# Install isolated xl2tpd service with its own config, PID and control FIFO.
# autodial removes reliance on a one-shot FIFO command after daemon restarts.
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
  # Quoted heredoc would not expand ENDPOINT. Password must not go through an
  # unquoted heredoc: $() and backticks in it would be executed by the shell.
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
for hook in ip-up ip-down ipv6-up ipv6-down; do
  case "$hook" in ip-up) op=up;; ip-down) op=down;; ipv6-up) op='v6-up';; ipv6-down) op='v6-down';; esac
  printf '#!/bin/sh\nexec /usr/local/sbin/l2tp-vps %s "$@"\n' "$op" > "/etc/ppp/$hook.d/10-l2tp-vps"
  chmod 700 "/etc/ppp/$hook.d/10-l2tp-vps"
  if [ "$INIT" = openrc ]; then
    # Alpine's stock hooks are empty. Preserve custom dispatchers unchanged;
    # refuse an early-exit script instead of silently appending unreachable code.
    hf="/etc/ppp/$hook"
    if [ ! -f "$hf" ]; then printf '#!/bin/sh\n' > "$hf"; chmod 755 "$hf"; fi
    if ! grep -q "$hook.d" "$hf"; then
      if grep -Eq '^[[:space:]]*(exit|exec)[[:space:]]' "$hf"; then fatal "自定义 $hf 提前退出，无法安全安装钩子"; fi
      printf '\n# L2TP-VPS dispatcher\nfor hs in /etc/ppp/%s.d/*; do\n  [ ! -x "$hs" ] || "$hs" "$@"\ndone\n' "$hook" >> "$hf"
    fi
  fi
done
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
# networkd removes policy rules it did not create. Install them again after it has finished.
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
  # Default ManageForeignRoutingPolicyRules=yes deletes rules installed before the NIC is configured.
  mkdir -p /etc/systemd/networkd.conf.d
  cat > /etc/systemd/networkd.conf.d/l2tp-vps.conf <<'EOF'
[Network]
ManageForeignRoutingPolicyRules=no
ManageForeignRoutes=no
EOF
  systemctl daemon-reload
else
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
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-l2tp-vps.conf <<'EOF'
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.src_valid_mark=0
EOF
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf.all.src_valid_mark=0 >/dev/null || true
"$RUNTIME" guard
"$RUNTIME" route
# Resolve through the dedicated UID even when the old tunnel is down.
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

# Migration is restartable. Each destructive step concerns only verified v1 state.
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
if [ "$(readlink /etc/resolv.conf 2>/dev/null || true)" != /etc/l2tp-vps-resolv.conf ]; then
  if [ ! -e "$STATE/resolv.conf.before-v2" ] && [ ! -L "$STATE/resolv.conf.before-v2" ]; then
    cp -a /etc/resolv.conf "$STATE/resolv.conf.before-v2"
  fi
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions timeout:2 attempts:2\n' > /etc/l2tp-vps-resolv.conf
  chmod 644 /etc/l2tp-vps-resolv.conf
  ln -s /etc/l2tp-vps-resolv.conf /etc/resolv.conf.l2tp-vps-new
  mv -f /etc/resolv.conf.l2tp-vps-new /etc/resolv.conf
fi
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
info '等待 L2TP 连接（最多 90 秒）'
connected=0
for _attempt in $(seq 1 90); do
  if ip -4 addr show dev "$PEER" 2>/dev/null | grep -q 'inet ' && ip -4 route get 1.1.1.1 2>/dev/null | grep -q "dev $PEER"; then connected=1; break; fi
  sleep 1
done
[ "$connected" = 1 ] || fatal 'L2TP 拨号或路由未就绪。请检查服务器、账号、UDP 1701 和 PPP 日志。拨号失败不一定是账号欠费。'
out=$(curl -4 --noproxy '*' -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org || curl -4 --noproxy '*' -fsS --connect-timeout 10 --max-time 20 https://ifconfig.me || true)
out=$(printf '%s' "$out" | tr -d '[:space:]')
if ! printf '%s\n' "$out" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}'; then
  # Hostname lookups can fail while the tunnel itself is up. This URL is an address.
  trace=$(curl -4 --noproxy '*' -kfsS --connect-timeout 10 --max-time 20 https://1.1.1.1/cdn-cgi/trace || true)
  out=$(printf '%s\n' "$trace" | awk -F= '$1=="ip" {print $2; exit}')
  out=$(printf '%s' "$out" | tr -d '[:space:]')
fi
printf '%s\n' "$out" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' || fatal '隧道出口验证没有返回有效 IPv4（可能是 DNS、MTU、防火墙或服务端问题）'
[ "$out" != "$NATIVE_IP" ] || fatal '出口仍为 VPS 原生地址；未标记升级成功'
# NAT is normal. The public address does not have to equal the PPP address.
route_line=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
printf '%s\n' "$route_line" | grep -q "dev $PEER" || fatal '出站没有走隧道；未标记升级成功'
route_src=$(printf '%s\n' "$route_line" | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')
peer_ip=$(ip -4 -o addr show dev "$PEER" | awk '{split($4,a,"/");print a[1];exit}')
[ -n "$peer_ip" ] || fatal '隧道没有 IPv4 地址；未标记升级成功'
if [ -n "$route_src" ] && [ "$route_src" != "$peer_ip" ]; then
  fatal '出站源地址不是隧道地址；未标记升级成功'
fi
# A socket bound to the VPS address is how most proxy nodes dial out.
# It must leave through the tunnel and must not be visible as the native address.
from_native=$(ip -4 route get 1.1.1.1 from "$NATIVE_IP" 2>/dev/null || true)
printf '%s\n' "$from_native" | grep -q "dev $PEER" || fatal '绑定 VPS 原地址的连接没有走 L2TP；节点出口会仍是 VPS'
bound=$(curl -4 --noproxy '*' --interface "$NATIVE_IP" -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org || curl -4 --noproxy '*' --interface "$NATIVE_IP" -fsS --connect-timeout 10 --max-time 20 https://ifconfig.me || true)
bound=$(printf '%s' "$bound" | tr -d '[:space:]')
printf '%s\n' "$bound" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' || fatal '绑定 VPS 原地址后无法经隧道访问外网'
[ "$bound" != "$NATIVE_IP" ] || fatal '绑定 VPS 原地址的连接出口仍是 VPS'
v6=$(awk 'NF {print; exit}' "$STATE/native-v6.txt" 2>/dev/null || true)
if [ -n "$v6" ]; then
  v6out=$(curl -6 --noproxy '*' --interface "$v6" -fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org || true)
  v6out=$(printf '%s' "$v6out" | tr -d '[:space:]')
  [ "$v6out" != "$v6" ] || fatal 'IPv6 仍从 VPS 原生地址出去'
fi
printf '%s\n' "$VERSION" > "$STATE/installed-version"
if [ -f "$0" ]; then cp "$0" "$STATE/install.sh"; chmod 600 "$STATE/install.sh"; fi
info "安装/升级成功：${VERSION}；公网出口 ${out}，不是 VPS 原生地址"
info "本机新连接和节点出站都走 L2TP。SSH 与节点端口仍使用 VPS 原地址 ${NATIVE_IP}。"
info '以后重复运行 README 安装命令，或运行 sudo l2tp-vps update，即可升级并保留账号。'
info '状态：sudo l2tp-vps status；恢复原生网络：sudo l2tp-vps recover；卸载：sudo shanchu'
SUCCESS=1
