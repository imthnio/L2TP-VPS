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
