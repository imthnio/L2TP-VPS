#!/bin/sh
# L2TP-VPS runtime. Only this project's table, chains, service and peer are owned.
set -eu
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
  chain l2tp_nat {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$PEER" masquerade
  }
  chain output {
    type filter hook output priority 0; policy drop;
    oifname "lo" accept
    oifname "$PEER" accept
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
    ip "$family" route replace "$dest" dev "$NATIVE_IF" table "$TABLE" 2>/dev/null || true
  done
}
copy_link_routes() {
  copy_dev_prefixes -4
  if ipv6_on; then
    copy_dev_prefixes -6
  fi
}
guard() {
  # nft submits the whole replacement as one atomic transaction.
  # Install the reply mark before removing the old "from native address" rule,
  # so an existing SSH session is not sent into the tunnel in between.
  render_firewall | nft -f -
  copy_link_routes
  ip -4 route replace prohibit default metric 42700 table "$TABLE"
  rule -4 8900 "uidrange $FETCH_UID-$FETCH_UID lookup main" uidrange "$FETCH_UID-$FETCH_UID" table main
  # 8904 is after the maintenance UID rule and before any leftover "from native address" rule.
  rule -4 8904 "fwmark $TUNMARK lookup $TABLE" fwmark "$TUNMARK" table "$TABLE"
  rule -4 8905 "fwmark $MARK lookup main" fwmark "$MARK" table main
  rule -4 8920 "from all lookup $TABLE" table "$TABLE"
  rule -4 8930 "blackhole" blackhole
  if ipv6_on; then
    ip -6 route replace prohibit default metric 42700 table "$TABLE"
    rule -6 8900 "uidrange $FETCH_UID-$FETCH_UID lookup main" uidrange "$FETCH_UID-$FETCH_UID" table main
    rule -6 8904 "fwmark $TUNMARK lookup $TABLE" fwmark "$TUNMARK" table "$TABLE"
    rule -6 8905 "fwmark $MARK lookup main" fwmark "$MARK" table main
    # Neighbour discovery needs the native link while ordinary IPv6 stays closed.
    rule -6 8911 'to fe80::/10 lookup main' to fe80::/10 table main
    rule -6 8911 'to ff02::/16 lookup main' to ff02::/16 table main
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
}
peer_up() {
  # Both the independent interface name AND pppd ipparam must match.
  [ "${1:-}" = "$PEER" ] && [ "${6:-}" = "$TAG" ] || return 0
  ip -4 route replace default dev "$PEER" metric 100 table "$TABLE"
  sysctl -w "net.ipv4.conf.$PEER.rp_filter=2" >/dev/null || true
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null || true
  sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null || true
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
  su -s /bin/sh -c "$task" l2tp-fetch
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
  ip -4 rule show pref 8920 | grep -q "lookup $TABLE" || return 0
  ip -4 rule show pref 8930 | grep -q blackhole || return 0
  if ipv6_on; then
    ip -6 rule show pref 8904 | grep -q "fwmark $TUNMARK" || return 0
    ip -6 rule show pref 8905 | grep -q "fwmark $MARK" || return 0
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
  while :; do
    sleep 15
    [ ! -f "$STATE/disabled" ] || continue
    (load; refresh; restore_policy; endpoint_route; ensure_peer_route) || true
    # A late global IPv6 assignment must not depend on a 10-second polling window.
    peer_v6 "$PEER" '' '' '' '' "$TAG" || true
  done
}
stop_services() {
  if [ "$INIT" = systemd ]; then
    systemctl disable --now l2tp-vps-watch.service l2tp-vps.service l2tp-vps-guard.service 2>/dev/null || true
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
  ip -4 rule del pref 8920 table "$TABLE" 2>/dev/null || true
  ip -4 rule del pref 8930 blackhole 2>/dev/null || true
  ip -6 rule del pref 8900 uidrange "$FETCH_UID-$FETCH_UID" table main 2>/dev/null || true
  ip -6 rule del pref 8904 fwmark "$TUNMARK" table "$TABLE" 2>/dev/null || true
  ip -6 rule del pref 8905 fwmark "$MARK" table main 2>/dev/null || true
  ip -6 rule del pref 8911 to fe80::/10 table main 2>/dev/null || true
  ip -6 rule del pref 8911 to ff02::/16 table main 2>/dev/null || true
  ip -6 rule del pref 8920 table "$TABLE" 2>/dev/null || true
  ip -6 rule del pref 8930 blackhole 2>/dev/null || true
  ip -4 route show table "$TABLE" dev "$NATIVE_IF" scope link 2>/dev/null | while IFS= read -r line; do
    case "$line" in ''|default*|prohibit*) continue;; esac
    # shellcheck disable=SC2086
    ip -4 route del $line table "$TABLE" 2>/dev/null || true
  done
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
