#!/bin/sh
# L2TP-VPS 管理命令，安装后位于 /usr/local/sbin/l2tp-vps。
# 常用：sudo l2tp-vps status（看状态）| ports（不走 L2TP 的端口）| update（升级）| recover（恢复原生上网）| rollback（回滚）| uninstall（卸载）
# 其余子命令（guard、route、up、down、watch……）由开机服务和拨号钩子自动调用，一般不用手动运行。
#
# 原理一句话：用"策略路由 + 防火墙"让本机新发起的连接只能走 L2TP 隧道网卡 l2tp-aa；
# 别人连进来的连接，回包仍从原生网卡发回；隧道断开时，普通程序的新连接被拒绝，而不是偷偷改走原生 IP。
# 本脚本只改自己的东西：路由表 24680、优先级 8900~8930 的策略规则、nftables 表 l2tp_vps、服务和 l2tp-aa 网卡，
# 以及设置了排除端口时，内核保留端口（ip_local_reserved_ports）里本项目自己加的那几项。
set -eu
trap '' HUP
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# TABLE：本项目专用路由表。MARK：给"回包"打的标记，带这个标记的包查系统主路由表、从原生网卡出去。
# TUNMARK：强制进隧道表的标记（保留给兼容用途）。TAG：pppd 的 ipparam 暗号，用来认出本项目的拨号。
# BYPASS：排除端口的标记。带这个标记的包查主路由表、从原生网卡进出，完全不经过 L2TP（十进制 149122）。
STATE=/etc/l2tp-vless
TABLE=24680
MARK=0x24680
TUNMARK=0x24681
BYPASS=0x24682
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
#   forward     转发流量（Docker 容器、wg0 客户端等）的断线保护。output 只管本机自己发出的包，管不到转发。
#               隧道断开时隧道表里只剩备用原生路由，容器的新连接会选中它、从原生 IP 出去；这里只放行回包
#               和排除端口的中转流量。
#   l2tp_bypass_* 排除端口（见下方 bypass_rules 的说明），没设置排除端口时这几条链是空的、不起作用。
#   直连标记 BYPASS 的放行和地址伪装（见 mark_rules）不管有没有排除端口都在。
render_firewall() {
  # 只给回包打标记。新连接不打：8920 规则本来就会把它们送进隧道表，再打标记反而会让维护账号的连接被送错地方。
  bypass_in=; bypass_out=; bypass_nat=; bypass_accept=; bypass_elements=; bypass_cg=
  mark_rules
  if bypass_on; then bypass_rules; fi
  # flush table 不会清空集合里的旧端口，所以先确保集合存在，再单独清空，最后写入这次的端口。
  cat <<EOF
add table inet l2tp_vps
flush table inet l2tp_vps
add set inet l2tp_vps bypass_ports { type inet_service; flags interval; }
flush set inet l2tp_vps bypass_ports
table inet l2tp_vps {
  set bypass_ports {
    type inet_service; flags interval;$bypass_elements
  }
  chain l2tp_bypass_in {
    type filter hook prerouting priority mangle; policy accept;$bypass_in
  }
  chain l2tp_bypass_out {
    type route hook output priority mangle; policy accept;$bypass_out
  }
  chain l2tp_bypass_cg {$bypass_cg
  }
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
    oifname "$PEER" masquerade$bypass_nat
  }
  chain output {
    type filter hook output priority 0; policy drop;
    oifname "lo" accept
    oifname "$PEER" accept
    # 其他本地网卡（Docker 网桥、内网网卡、wg0）不是原生出口，不拦。
    oifname != "$NATIVE_IF" accept
    oifname "$NATIVE_IF" ct direction reply ct state established,related accept$bypass_accept
    oifname "$NATIVE_IF" ip daddr $ENDPOINT udp dport 1701 accept
    oifname "$NATIVE_IF" meta skuid $FETCH_UID udp dport 53 accept
    oifname "$NATIVE_IF" meta skuid $FETCH_UID tcp dport { 53, 443 } accept
    oifname "$NATIVE_IF" udp sport 68 udp dport 67 accept
    oifname "$NATIVE_IF" udp sport 546 udp dport 547 accept
    oifname "$NATIVE_IF" ip6 hoplimit 255 icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
    counter reject with icmpx type admin-prohibited
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
    oifname != "$NATIVE_IF" accept
    # 别人连进容器（Docker 端口映射）的回包照常放行；排除端口上的中转（BYPASS 标记）照常放行；
    # 容器自己发起、要从原生网卡出去的一律拒绝。
    oifname "$NATIVE_IF" ct direction reply ct state established,related accept$bypass_accept
    counter reject with icmpx type admin-prohibited
  }
  # L2TP 只用来出站：别人用 L2TP 出口 IP 连进来的新连接一律丢弃（连本机的和要转发的都算），
  # 只收本机先发出去的连接的回包。入站只走 VPS 自己的 IP。
  # 例外：IPv6 自动配置要用的路由器通告、邻居发现和 DHCPv6 回复，不放行的话隧道拿不到 IPv6 地址。
  chain tunnel_in {
    type filter hook input priority 0; policy accept;
    iifname "$PEER" ct state established,related accept
    iifname "$PEER" icmpv6 type { nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
    iifname "$PEER" udp sport 547 udp dport 546 accept
    iifname "$PEER" counter drop
  }
  chain tunnel_forward {
    type filter hook forward priority 0; policy accept;
    iifname "$PEER" ct state established,related accept
    iifname "$PEER" counter drop
  }
}
EOF
}
# ---------- 排除端口（不走 L2TP 的端口） ----------
# 用户在 $STATE/bypass-ports 里列出的端口（如 1112、2000-2010），无论跑网站还是节点，都用 VPS 自己的 IP，
# 和 L2TP 互不影响。分三层实现：
#   1. 别人连进本机这些端口的连接（包括 Docker 映射、DNAT 中转），整条连接打上 BYPASS 标记，进出都走原生网卡。
#   2. 本机从这些端口发起的连接（源端口是排除端口），同样打 BYPASS 标记走原生网卡。
#      这些端口会加进内核的"保留端口"，系统不再把它们随机分给别的程序当源端口：
#      既不会被 xl2tpd 等程序抢占，别的程序也不会因为碰巧用了这个源端口而绕过 L2TP。
#   3. 节点转发流量时，出站连接的源端口是随机的，单看端口认不出来。所以找出"正在监听排除端口的系统服务"，
#      按 cgroup 把这个服务的全部出站都改走原生网卡（见 bypass_scan）。
#      这个服务如果还监听了别的端口（比如一个 xray 同时跑好几个入站），就不按程序排除，以免把别的端口也带出 L2TP。
# 带 BYPASS 标记的包查主路由表（规则 8906），防火墙放行，源地址不是原生 IP 的做一次地址伪装。
# 节点程序也可以自己给某个出站设置 mark 149122（即 0x24682，xray 的 sockopt.mark、sing-box 的 routing_mark），
# 这个出站同样走原生网络；设置 mark 需要 root 权限，普通程序做不到。
# 这个直连标记（路由规则 8906、防火墙放行、地址伪装）不管有没有设置排除端口都生效：比如 WireGuard 用
# fwmark 0x24682 让自己的加密包直接走原生网卡去连落地机。以前只在设了排除端口时才有，没设时带标记的包
# 被送进 L2TP（MTU 只有 1400），握手和 ping 这种小包能过，网页这种大包就卡住。
# 没有设置排除端口时，上面 1~3 层不生效。
#
# normalize_ports：检查并整理用户输入的端口。支持空格、逗号、顿号分隔，支持 2000-2010 这样的范围。
#   输出每行一个端口或端口段，按从小到大排好，重叠或相邻的段会合并。有任何一项不合法就什么都不输出、
#   把这一项打印到 stderr（方便告诉用户错在哪），返回 2。
#   安装器里有一份完全相同的副本（安装时管理命令还没装好），改动时两处一起改，测试会检查两份一致。
normalize_ports() {
  printf '%s\n' "$1" | sed 's/，/ /g; s/、/ /g; s/[,;]/ /g' | awk '
    function out(a, b) { print (a == b) ? a : a "-" b }
    { for (i = 1; i <= NF; i++) {
        t = $i
        if (t !~ /^[0-9]+(-[0-9]+)?$/) { bad = t; exit }
        n = split(t, p, "-"); a = p[1] + 0; b = (n == 2) ? p[2] + 0 : a
        if (a < 1 || b > 65535 || a > b) { bad = t; exit }
        c++; lo[c] = a; hi[c] = b
    } }
    END {
      if (bad != "") { print bad > "/dev/stderr"; exit 2 }
      for (i = 2; i <= c; i++) {
        x = lo[i]; y = hi[i]
        for (j = i - 1; j >= 1 && lo[j] > x; j--) { lo[j + 1] = lo[j]; hi[j + 1] = hi[j] }
        lo[j + 1] = x; hi[j + 1] = y
      }
      for (i = 1; i <= c; i++) {
        if (m && lo[i] <= e + 1) { if (hi[i] > e) e = hi[i]; continue }
        if (m) out(s, e)
        s = lo[i]; e = hi[i]; m = 1
      }
      if (m) out(s, e)
    }'
}
# bypass_ports：读出已保存的排除端口（每行一个）。文件被手动改坏时当作没有排除端口：
#   宁可让这些端口暂时也走 L2TP，也不能让防火墙规则加载失败、断线保护失效。
bypass_ports() {
  [ -s "$STATE/bypass-ports" ] || return 0
  normalize_ports "$(cat "$STATE/bypass-ports")" 2>/dev/null || true
}
bypass_on() { [ -n "$(bypass_ports)" ]; }
# port_list 分隔符：把排除端口连成一行（nft 集合用 ", "，内核保留端口用 ","）。
port_list() { bypass_ports | awk -v sep="$1" 'NF {printf "%s%s", (n++ ? sep : ""), $1}'; }
# portset：端口集合运算，参数是逗号分隔的端口/端口段（内核 ip_local_reserved_ports 的格式）。
#   portset has A B    A 是否包含 B 的全部端口
#   portset minus A B  输出 A 去掉 B 以后剩下的端口段
#   portset free A B "起 止"  输出起止范围内既不在 A 也不在 B 里的端口个数
portset() {
  awk -v op="$1" -v a="$2" -v b="$3" -v range="${4:-}" '
    function load(s, set,   n, i, p, x, lo, hi) {
      n = split(s, p, ",")
      for (i = 1; i <= n; i++) {
        gsub(/[^0-9-]/, "", p[i]); if (p[i] == "") continue
        if (split(p[i], x, "-") == 2) { lo = x[1] + 0; hi = x[2] + 0 } else { lo = p[i] + 0; hi = lo }
        if (hi > 65535) hi = 65535
        for (; lo <= hi; lo++) set[lo] = 1
      }
    }
    BEGIN {
      load(a, A); load(b, B)
      if (op == "has") { for (k in B) if (!(k in A)) exit 1; exit 0 }
      if (op == "free") { split(range, e, " "); for (k = e[1] + 0; k <= e[2] + 0; k++) if (!(k in A) && !(k in B)) free++; print free + 0; exit 0 }
      for (k = 1; k <= 65536; k++) {
        if (k <= 65535 && (k in A) && !(k in B)) { if (!s) s = k; continue }
        if (s) { out = out (out == "" ? "" : ",") (s == k - 1 ? s : s "-" (k - 1)); s = 0 }
      }
      print out
    }'
}
RESERVED=/proc/sys/net/ipv4/ip_local_reserved_ports
# reserve_ok：排除端口是否都已在内核保留端口里。没保留成功时不启用"按源端口排除"（见上面第 2 层）。
reserve_ok() { [ -f "$RESERVED" ] && portset has "$(cat "$RESERVED")" "$(port_list ,)"; }
# bypass_reserve [release]：把排除端口加进内核保留端口；不再排除的端口从里面删掉。
#   只删本项目自己加进去的（记在 $STATE/bypass-reserved），别的软件保留的端口原样不动。
#   release：全部撤掉（recover/卸载时用）。重启后内核会清空这个设置，开机的 guard 会重新加上。
bypass_reserve() {
  [ -f "$RESERVED" ] || return 1
  want=; [ "${1:-}" = release ] || want=$(port_list ,)
  owned=$(cat "$STATE/bypass-reserved" 2>/dev/null || true)
  current=$(cat "$RESERVED")
  release=$(portset minus "$owned" "$want")
  if [ -n "$release" ]; then
    current=$(portset minus "$current" "$release")
    { printf '%s\n' "$current" > "$RESERVED"; } 2>/dev/null || return 1
    owned=$(portset minus "$owned" "$release")
    printf '%s\n' "$owned" > "$STATE/bypass-reserved"
  fi
  added=$(portset minus "$want" "$current")
  # 系统随机分配源端口时从"临时端口范围"（默认 32768-60999）里挑。保留太多会让 xl2tpd 和所有程序
  # 都分不到端口、连不了网，反而把 L2TP 弄坏。所以保留后剩下的临时端口不足 8192 个时就不保留，
  # 改为不按源端口排除（连进排除端口的连接仍然不走 L2TP）。
  range=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo '32768 60999')
  if [ -n "$added" ] && [ "$(portset free "$current" "$added" "$range")" -lt 8192 ]; then return 1; fi
  if [ -n "$added" ]; then
    { printf '%s\n' "${current:+$current,}$added" > "$RESERVED"; } 2>/dev/null || return 1
    owned=$(portset minus "${owned:+$owned,}$added" '')
    printf '%s\n' "$owned" > "$STATE/bypass-reserved"
  fi
  portset has "$(cat "$RESERVED")" "$want"
}
# addresses 文件 字符：读出 native-v4/v6.txt 里的地址，用 ", " 连起来；只保留合法字符，保证防火墙规则能加载。
addresses() { awk -v ok="$2" '$1 ~ ok {printf "%s%s", (n++ ? ", " : ""), $1}' "$1" 2>/dev/null || true; }
# bypass_rules：生成 render_firewall 里排除端口相关的规则，存进几个变量。
bypass_rules() {
  bypass_elements="
    elements = { $(port_list ', ') }"
  # 第 1 层：新连接的目的地址是本机、目的端口是排除端口，就给整条连接打标记（ct mark）；
  #   之后这条连接来回的每个包都打上 BYPASS，按主路由表走原生网卡。从隧道进来的连接不管。
  bypass_in="
    iifname != { \"lo\", \"$PEER\" } ct state new fib daddr type local tcp dport @bypass_ports ct mark set $BYPASS
    iifname != { \"lo\", \"$PEER\" } ct state new fib daddr type local udp dport @bypass_ports ct mark set $BYPASS
    ct mark $BYPASS meta mark set $BYPASS"
  # 本机发出的包：回包照旧交给 l2tp_route；已经判定为排除的连接继续打标记；
  #   第 2 层按源端口、第 3 层按程序（l2tp_bypass_cg 链由 bypass_refresh 动态填写）。
  bypass_out="
    ct direction reply accept
    ct mark $BYPASS meta mark set $BYPASS accept"
  if reserve_ok; then
    bypass_out="$bypass_out
    tcp sport @bypass_ports ct mark set $BYPASS meta mark set $BYPASS accept
    udp sport @bypass_ports ct mark set $BYPASS meta mark set $BYPASS accept"
  fi
  bypass_out="$bypass_out
    jump l2tp_bypass_cg"
  # 上次成功装上的按程序排除规则一起写进去，重写防火墙的那一瞬间也不会有空档。
  # 只接受本项目自己生成的格式；这些规则加载失败时 guard 会不带它们再装一次。
  if [ -z "${BYPASS_NO_CG:-}" ] && [ -f /run/l2tp-vps-bypass.rules ]; then
    bypass_cg=$(awk -v mark="$BYPASS" '
      $0 ~ "^socket cgroupv2 level [0-9]+ \"([A-Za-z0-9._@:/-]|\\\\x[0-9A-Fa-f][0-9A-Fa-f])+\" ct mark set " mark " meta mark set " mark " accept$" { printf "\n    %s", $0 }' /run/l2tp-vps-bypass.rules)
  fi
}
# mark_rules：带直连标记 BYPASS 的包（排除端口的连接，或程序自己设置了 mark 0x24682）的放行和地址伪装。
#   不管有没有排除端口都生成，见上方说明。
mark_rules() {
  # 本机程序连接时先按隧道表选了隧道地址当源地址，改走原生网卡后要换成原生 IP，否则回包回不来。
  #   源地址本来就是原生 IP 的（程序自己绑定了某个原生 IP）不改，保留程序选的那个 IP。
  v4=$(addresses "$STATE/native-v4.txt" '^[0-9.]+$'); [ -n "$v4" ] || v4=$NATIVE_IP
  v6=$(addresses "$STATE/native-v6.txt" '^[0-9A-Fa-f:]+$')
  bypass_nat="
    oifname \"$NATIVE_IF\" meta mark $BYPASS ip saddr != { $v4 } masquerade"
  if [ -n "$v6" ]; then
    bypass_nat="$bypass_nat
    oifname \"$NATIVE_IF\" meta mark $BYPASS ip6 saddr != { $v6 } masquerade"
  else
    bypass_nat="$bypass_nat
    oifname \"$NATIVE_IF\" meta mark $BYPASS meta nfproto ipv6 masquerade"
  fi
  bypass_accept="
    oifname \"$NATIVE_IF\" meta mark $BYPASS accept"
}
# bypass_scan：找出正在监听排除端口的程序，判断能不能把这个程序的全部出站改走原生网络。
# 每行输出一条，字段用 | 分隔：
#   ok|cgroup 路径|端口                可以按程序排除
#   skip|cgroup 路径|端口|原因          不能按程序排除（这些端口本身的进出仍然不走 L2TP）
#   none||原因                          整台机器都不支持按程序排除
# 只接受独立的系统服务（systemd 的 system.slice 下、或 OpenRC 的服务），不接受 SSH 会话里直接运行的程序：
# 否则同一个会话里的其他命令（包括本脚本自己）也会被带出 L2TP。
bypass_scan() {
  cgroot >/dev/null || { echo 'none||系统没有 cgroup v2（常见于很老的系统或 OpenVZ）'; return 0; }
  command -v ss >/dev/null 2>&1 || { echo 'none||缺少 ss 命令（iproute2）'; return 0; }
  range=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo '32768 60999')
  ss -lntup 2>/dev/null | awk -v ports="$(port_list ,)" -v range="$range" -v init="$INIT" '
    function inset(p,   i) { for (i = 1; i <= np; i++) if (p >= lo[i] && p <= hi[i]) return 1; return 0 }
    # 进程所属的服务：取 cgroup 路径里第一个 .service/.scope（OpenRC 取第一层），
    # 这样服务自己再分出来的子 cgroup 也算同一个服务。
    function cgroup(pid,   f, line, path, n, seg, i, up) {
      if (pid in cg) return cg[pid]
      f = "/proc/" pid "/cgroup"; path = ""
      while ((getline line < f) > 0) if (substr(line, 1, 3) == "0::") path = substr(line, 4)
      close(f)
      n = split(path, seg, "/"); up = ""
      if (init != "systemd" && n >= 2 && seg[2] != "") path = "/" seg[2]
      else for (i = 2; i <= n; i++) { up = up "/" seg[i]; if (seg[i] ~ /\.(service|scope)$/) { path = up; break } }
      cg[pid] = path; return path
    }
    # 返回空字符串表示这个 cgroup 可以排除，否则返回不能排除的原因。
    function refuse(p,   name) {
      if (init == "systemd") {
        if (p !~ /^\/system\.slice\/./) return "程序不是独立的系统服务（例如在 SSH 会话里直接运行）"
      } else {
        name = substr(p, 2); sub(/\/.*/, "", name); sub(/^openrc\./, "", name)
        if (name !~ /^[A-Za-z0-9._@-]+$/ || system("test -f /etc/init.d/" name) != 0) return "程序不是独立的 OpenRC 服务"
      }
      # systemd 会把服务名里的特殊字符写成 \x2d 这样的转义（例如模板服务 hysteria-node@3 所在的
      # system-hysteria\x2dnode.slice），这种转义也要接受；除此之外的反斜杠、引号、空格一律拒绝。
      if (p !~ /^\/([A-Za-z0-9._@:\/-]|\\x[0-9A-Fa-f][0-9A-Fa-f])+$/) return "服务名里有不支持的字符"
      if (p ~ /\/(docker|containerd)\.service(\/|$)/ || name ~ /^(docker|containerd)$/) return "Docker 网桥模式的容器无法按程序排除，请改用 host 网络模式"
      if (p ~ /\/(ssh|sshd|dropbear|cron|crond|xl2tpd|l2tp-vps|l2tp-vps-guard|l2tp-vps-watch)\.service(\/|$)/ || p ~ /\/(sshd|ssh|serial-getty|getty)@/) return "这是系统关键服务"
      if (name ~ /^(sshd|dropbear|crond|cron|local|xl2tpd|l2tp-vps|l2tp-vps-guard|l2tp-vps-watch)$/) return "这是系统关键服务"
      return ""
    }
    BEGIN {
      np = split(ports, r, ",")
      for (i = 1; i <= np; i++) { if (split(r[i], x, "-") == 2) { lo[i] = x[1] + 0; hi[i] = x[2] + 0 } else { lo[i] = r[i] + 0; hi[i] = lo[i] } }
      split(range, e, " "); elo = e[1] + 0; ehi = e[2] + 0
    }
    $1 == "tcp" || $1 == "udp" {
      port = $5; sub(/.*:/, "", port); port += 0; rest = $0
      # 只在本机内部监听（127.0.0.1、::1）的端口，外面连不进来，不可能是对外的节点，比如 xray 的 API、
      # sing-box 的 clash_api、3x-ui 内部用的端口。几乎每个节点程序都有一个，不能因为它就拒绝按程序排除。
      addr = $5; sub(/:[^:]*$/, "", addr)
      loop = (addr ~ /^127\./ || addr ~ /^\[::1\]/ || addr ~ /^\[::ffff:127\./ || addr ~ /%lo$/)
      while (match(rest, /pid=[0-9]+/)) {
        pid = substr(rest, RSTART + 4, RLENGTH - 4); rest = substr(rest, RSTART + RLENGTH)
        path = cgroup(pid); if (path == "") continue
        key = path SUBSEP port
        if (inset(port)) { if (!(key in mine)) { mine[key] = 1; want[path] = want[path] " " port } }
        # 同一程序的其他对外端口：TCP 监听都算；UDP 只算临时端口范围以外的
        # （临时端口范围内的 UDP 多半是程序自己向外发起连接用的随机端口，不是对外服务）；只听本机的不算。
        else if (!loop && ($1 == "tcp" || port < elo || port > ehi) && !(($1 SUBSEP key) in seen)) {
          seen[$1 SUBSEP key] = 1; other[path] = other[path] " " $1 "/" port
        }
      }
    }
    END {
      for (path in want) {
        why = refuse(path)
        if (why == "" && other[path] != "") why = "这个程序还在用其他端口：" substr(other[path], 2)
        if (why == "") print "ok|" path "|" substr(want[path], 2)
        else print "skip|" path "|" substr(want[path], 2) "|" why
      }
    }'
}
# cgroot：输出 cgroup v2 的挂载位置。新系统在 /sys/fs/cgroup；Debian 10/Ubuntu 20.04 等较老系统
#   是"混合模式"，v2 挂在 /sys/fs/cgroup/unified。两处都没有就返回失败。
cgroot() {
  for dir in /sys/fs/cgroup /sys/fs/cgroup/unified; do
    [ -f "$dir/cgroup.controllers" ] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}
# ipt_bypass 路径...：按程序排除的兼容做法，给老内核/低配服务器用。
#   nftables 要内核 5.13+ 才能按 cgroup 匹配；iptables 的 cgroup 模块在内核 4.5 起就有，混合模式也能用。
#   只用自己的链 L2TP_VPS_BYPASS（mangle 表，从 OUTPUT 跳进来），给这些服务发起的连接打 BYPASS 标记，
#   后面的路由、防火墙放行、地址伪装和 nftables 方式完全一样。
#   不带参数就是清空并撤掉这条链。输出 iptables 也装不上的路径（没装 iptables、或内核缺模块）。
ipt_bypass() {
  # 没用过 iptables 方式（大多数新系统）就什么都不碰：只运行 iptables 命令也可能让系统多出一张空表。
  [ "$#" != 0 ] || [ -f /run/l2tp-vps-bypass.ipt ] || return 0
  [ "$#" = 0 ] || touch /run/l2tp-vps-bypass.ipt
  for tool in iptables ip6tables; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      [ "$tool" != iptables ] || [ "$#" = 0 ] || printf '%s\n' "$@"
      continue
    fi
    if [ "$#" = 0 ]; then
      "$tool" -w -t mangle -D OUTPUT -j L2TP_VPS_BYPASS 2>/dev/null || true
      "$tool" -w -t mangle -F L2TP_VPS_BYPASS 2>/dev/null || true
      "$tool" -w -t mangle -X L2TP_VPS_BYPASS 2>/dev/null || true
      continue
    fi
    if ! { "$tool" -w -t mangle -N L2TP_VPS_BYPASS 2>/dev/null || "$tool" -w -t mangle -F L2TP_VPS_BYPASS 2>/dev/null; } ||
       ! { "$tool" -w -t mangle -C OUTPUT -j L2TP_VPS_BYPASS 2>/dev/null || "$tool" -w -t mangle -I OUTPUT 1 -j L2TP_VPS_BYPASS 2>/dev/null; }; then
      [ "$tool" != iptables ] || printf '%s\n' "$@"
      continue
    fi
    for path in "$@"; do
      "$tool" -w -t mangle -A L2TP_VPS_BYPASS -m conntrack --ctdir ORIGINAL -m cgroup --path "${path#/}" -j CONNMARK --set-mark "$BYPASS" 2>/dev/null ||
        { [ "$tool" = iptables ] && printf '%s\n' "$path"; }
    done
    # 整条连接都按排除处理：已打过标记的连接，之后每个包都打上 BYPASS（和 nftables 方式的 ct mark 一样）。
    "$tool" -w -t mangle -A L2TP_VPS_BYPASS -m conntrack --ctdir ORIGINAL -m connmark --mark "$BYPASS" -j MARK --set-mark "$BYPASS" 2>/dev/null || true
  done
  [ "$#" != 0 ] || rm -f /run/l2tp-vps-bypass.ipt
}
# bypass_refresh [force]：按 bypass_scan 的结果重写 l2tp_bypass_cg 链。巡检每 3 秒调用一次。
#   nft 写规则时会把 cgroup 路径换成一个编号；服务重启后编号会变，所以连同编号一起比较，变了就重写。
#   结果记在 /run/l2tp-vps-bypass.status，供 status/ports 显示。
#   完整扫描要用 ss -p，它得翻遍所有进程打开的文件，连接多的节点机上每 3 秒做一次很耗 CPU。
#   所以先用便宜的 listen_sig 看监听端口有没有变化，没变就直接跳过（服务重启会换新的监听，照样能发现）。
bypass_refresh() {
  if ! bypass_on; then
    rm -f /run/l2tp-vps-bypass.status /run/l2tp-vps-bypass.sig /run/l2tp-vps-bypass.rules /run/l2tp-vps-bypass.lsig
    ipt_bypass
    return 0
  fi
  lsig=$(listen_sig)
  if [ "${1:-}" != force ] && [ -n "$lsig" ] && [ -f /run/l2tp-vps-bypass.sig ] &&
     [ "$lsig" = "$(cat /run/l2tp-vps-bypass.lsig 2>/dev/null)" ]; then
    return 0
  fi
  scan=$(bypass_scan)
  sig=$(printf '%s\n' "$scan" | awk -F'|' '$1 == "ok" {print $2}' | while IFS= read -r path; do
    printf '%s %s\n' "$path" "$(ls -di "$(cgroot)$path" 2>/dev/null | awk '{print $1}')"
  done)
  # 扫描结果本身也算进去：新启动的服务被拒绝、拒绝原因变了时，按程序排除的规则虽然不用改，
  # 但 status/ports 显示的结果要跟着更新，否则会一直显示"没有程序在监听"这样的旧信息。
  sig="$sig
$scan"
  if [ "${1:-}" != force ] && [ -f /run/l2tp-vps-bypass.sig ] && [ "$sig" = "$(cat /run/l2tp-vps-bypass.sig)" ]; then
    printf '%s\n' "$lsig" > /run/l2tp-vps-bypass.lsig
    return 0
  fi
  # 先尝试一次性整体替换；失败（比如某个服务恰好退出了）就逐条添加，加不上的记为失败。
  batch="flush chain inet l2tp_vps l2tp_bypass_cg"
  rules=$(printf '%s\n' "$scan" | awk -F'|' -v mark="$BYPASS" '$1 == "ok" {
    p = substr($2, 2); level = split(p, parts, "/")
    printf "socket cgroupv2 level %d \"%s\" ct mark set %s meta mark set %s accept\n", level, p, mark, mark }')
  failed=; good=$rules
  if ! { printf '%s\n' "$batch"; printf '%s\n' "$rules" | awk 'NF {print "add rule inet l2tp_vps l2tp_bypass_cg " $0}'; } | nft -f - 2>/dev/null; then
    printf '%s\n' "$batch" | nft -f - 2>/dev/null || return 0
    good=
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if printf 'add rule inet l2tp_vps l2tp_bypass_cg %s\n' "$line" | nft -f - 2>/dev/null; then
        good="$good
$line"
      else
        path=${line#*\"}; failed="$failed /${path%%\"*}"
      fi
    done <<EOF
$rules
EOF
  fi
  # 记下成功装上的规则：guard 重写防火墙时把它们一起写进去，见 bypass_rules。
  printf '%s\n' "$good" > /run/l2tp-vps-bypass.rules
  # nftables 装不上的（内核低于 5.13 或 nftables 太旧），改用 iptables 的 cgroup 模块（内核 4.5 起就有）。
  # shellcheck disable=SC2086
  still=$(ipt_bypass $failed)
  {
    printf '%s\n' "$scan"
    for path in $still; do printf 'fail|%s\n' "$path"; done
    reserve_ok || echo 'noreserve||'
  } > /run/l2tp-vps-bypass.status
  printf '%s\n' "$sig" > /run/l2tp-vps-bypass.sig
  printf '%s\n' "$lsig" > /run/l2tp-vps-bypass.lsig
}
# listen_sig：列出和排除端口有关的监听（协议、地址端口、socket 编号），排好序。不带 -p，很便宜。
#   临时端口范围内、又不是排除端口的 UDP 不算：那多半是节点自己向外发起连接用的随机端口，换得很勤，
#   算进来的话几乎每次都要做完整扫描（bypass_scan 也不把它们当作对外服务）。
listen_sig() {
  command -v ss >/dev/null 2>&1 || return 0
  range=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo '32768 60999')
  ss -lntue 2>/dev/null | awk -v ports="$(port_list ,)" -v range="$range" '
    function inset(p,   i) { for (i = 1; i <= np; i++) if (p >= lo[i] && p <= hi[i]) return 1; return 0 }
    BEGIN {
      np = split(ports, r, ",")
      for (i = 1; i <= np; i++) { if (split(r[i], x, "-") == 2) { lo[i] = x[1] + 0; hi[i] = x[2] + 0 } else { lo[i] = r[i] + 0; hi[i] = lo[i] } }
      split(range, e, " "); elo = e[1] + 0; ehi = e[2] + 0
    }
    $1 == "tcp" || $1 == "udp" {
      port = $5; sub(/.*:/, "", port); port += 0
      if ($1 == "udp" && port >= elo && port <= ehi && !inset(port)) next
      ino = ""; for (i = 6; i <= NF; i++) if ($i ~ /^ino:/) ino = $i
      print $1, $5, ino
    }' | sort
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
  # 普通新连接即使选中这条备用路由，也会被上面 output（本机）或 forward（容器等转发）防火墙拒绝，所以不会漏。
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
  #    8906 带直连标记（BYPASS）的包查主路由表：排除端口的连接，或程序自己设置了 mark 0x24682
  #    8907 源端口是排除端口的包查主路由表（见 bypass_sport_rule），只在排除端口已保留时存在
  #    8911 IPv6 链路本地/组播地址查主表（邻居发现要用原生网卡）
  #    8915 主路由表里的具体网段（Docker 网桥、内网）优先，但忽略主表的默认路由
  #    8920 其余所有流量查隧道表 24680 → 默认出口是 l2tp-aa
  #    8930 blackhole 兜底，理论上不会走到这里
  # 先装好回包标记，再删旧版规则，保证切换过程中已有的 SSH 不会被送进隧道。
  # 网卡名里的点（如 VLAN 网卡 eth0.100）在 sysctl 键名里要写成 /，否则设置不到这张网卡上。
  for key in all default "$(printf '%s' "$NATIVE_IF" | tr . /)"; do
    sysctl -w "net.ipv4.conf.$key.rp_filter=0" >/dev/null 2>&1 || true
  done
  # 排除端口先加进内核保留端口（失败也继续，只是不启用按源端口排除），再一次性装防火墙。
  bypass_reserve >/dev/null 2>&1 || true
  if ! render_firewall | nft -f - 2>/dev/null; then
    # 多半是某个排除的服务刚好停了、它的 cgroup 已不存在：不带按程序排除的规则再装一次（这次出错会照常报错）。
    BYPASS_NO_CG=1 render_firewall | nft -f -
  fi
  copy_link_routes
  ip -4 route replace prohibit default metric 42700 table "$TABLE"
  install_native_fallback -4
  rule -4 8900 "uidrange $FETCH_UID-$FETCH_UID lookup main" uidrange "$FETCH_UID-$FETCH_UID" table main
  # 8904 排在维护账号规则之后、旧版残留的 8910 规则之前。
  rule -4 8904 "fwmark $TUNMARK lookup $TABLE" fwmark "$TUNMARK" table "$TABLE"
  rule -4 8905 "fwmark $MARK lookup main" fwmark "$MARK" table main
  bypass_rule -4
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
    bypass_rule -6
    # IPv6 邻居发现（相当于 IPv4 的 ARP）必须走原生网卡，普通 IPv6 仍然被挡住。
    rule -6 8911 'to fe80::/10 lookup main' to fe80::/10 table main
    rule -6 8911 'to ff02::/16 lookup main' to ff02::/16 table main
    rule -6 8915 "lookup main suppress_prefixlength 0" table main suppress_prefixlength 0
    rule -6 8920 "from all lookup $TABLE" table "$TABLE"
    rule -6 8930 "blackhole" blackhole
  fi
  drop_legacy_source_rules
  # 防火墙表刚被整体重写，按程序排除的规则要重新填。
  bypass_refresh force >/dev/null 2>&1 || true
}
# bypass_rule 4或6：8906（直连标记查主路由表）一直都加，不管有没有排除端口（见排除端口一节的说明）；
#   再按排除端口增删 8907。
bypass_rule() {
  rule "$1" 8906 "fwmark $BYPASS lookup main" fwmark "$BYPASS" table main
  bypass_sport_rule "$1"
}
# bypass_sport_rule 4或6 [release]：8907 让源端口是排除端口的包从一开始就查主路由表。
#   为什么需要：8906 只认防火墙打的标记，可程序选路（TCP 回 SYN-ACK、UDP 发包）发生在打标记之前，
#   当时查的是隧道表，选中的是 l2tp-aa：连接按隧道的 MTU 1400 定 MSS、按隧道的 GSO 能力切包，
#   之后每个包都要被防火墙改标记、重新选路一次才转到原生网卡。排除端口上的网站和节点因此明显变慢。
#   有了这条规则，监听排除端口的程序回包时直接选中原生网卡，按原生 MTU 1500 收发，不再逐包重新选路。
#   只在排除端口已加进内核保留端口时启用（和第 2 层同一前提）：否则别的程序碰巧随机用到这个源端口时，
#   会被送去原生网卡、再被断线保护拒绝，连不上网。内核或 ip 命令太旧（4.17 以前）不支持 sport 时跳过，
#   退回到原来逐包重新选路的做法，功能不受影响。
bypass_sport_rule() {
  family=$1; keep=
  if [ "${2:-}" != release ] && bypass_on && reserve_ok; then keep=$(bypass_ports); fi
  ip "$family" rule show pref 8907 2>/dev/null | awk '/lookup main/ {for (i = 1; i < NF; i++) if ($i == "sport") print $(i + 1)}' | while IFS= read -r port; do
    printf '%s\n' "$keep" | grep -Fx -- "$port" >/dev/null || drop_rule "$family" pref 8907 sport "$port" table main
  done
  for port in $keep; do
    rule "$family" 8907 "sport $port lookup main" sport "$port" table main 2>/dev/null || true
  done
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
  ip -4 rule show pref 8906 | grep -q "fwmark $BYPASS" || return 0
  ! ipv6_on || ip -6 rule show pref 8906 | grep -q "fwmark $BYPASS" || return 0
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
    chmod 600 "$STATE/xl2tpd.conf.new"
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
    # 排除端口上的服务可能刚启动或重启过，每 3 秒检查一次，及时把它的出站改走原生网络。
    if [ -s "$STATE/bypass-ports" ] && [ ! -d /run/l2tp-vps-install.lock ]; then
      (load; bypass_refresh) >/dev/null 2>&1 || true
    fi
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
# drop_rule 4或6 条件...：删掉一条策略规则，有重复的也一起删掉。
#   巡检和安装可能同时补规则，偶尔会加出两条一模一样的；只删一次的话，卸载后还会剩一条把流量送进隧道表。
#   最多删 5 次，防止 ip 命令行为异常时死循环。
drop_rule() {
  family=$1; shift; tries=0
  while [ "$tries" -lt 5 ] && ip "$family" rule del "$@" 2>/dev/null; do tries=$((tries + 1)); done
}
remove_routes() {
  # remove_routes：删除本项目加的全部策略规则和隧道表路由。
  # 每条都写完整条件再删，绝不只按优先级删，避免误删别的软件恰好用同一优先级的规则。
  drop_rule -4 pref 8900 uidrange "$FETCH_UID-$FETCH_UID" table main
  drop_rule -4 pref 8904 fwmark "$TUNMARK" table "$TABLE"
  drop_rule -4 pref 8905 fwmark "$MARK" table main
  drop_rule -4 pref 8906 fwmark "$BYPASS" table main
  drop_legacy_source_rules
  drop_rule -4 pref 8915 table main suppress_prefixlength 0
  drop_rule -4 pref 8920 table "$TABLE"
  drop_rule -4 pref 8930 blackhole
  drop_rule -6 pref 8900 uidrange "$FETCH_UID-$FETCH_UID" table main
  drop_rule -6 pref 8904 fwmark "$TUNMARK" table "$TABLE"
  drop_rule -6 pref 8905 fwmark "$MARK" table main
  drop_rule -6 pref 8906 fwmark "$BYPASS" table main
  bypass_sport_rule -4 release
  bypass_sport_rule -6 release
  drop_rule -6 pref 8911 to fe80::/10 table main
  drop_rule -6 pref 8911 to ff02::/16 table main
  drop_rule -6 pref 8915 table main suppress_prefixlength 0
  drop_rule -6 pref 8920 table "$TABLE"
  drop_rule -6 pref 8930 blackhole
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
  # 撤掉本项目加的内核保留端口；排除端口的设置本身保留，重新安装后继续生效。
  bypass_reserve release >/dev/null 2>&1 || true
  ipt_bypass >/dev/null 2>&1 || true
  rm -f /run/l2tp-vps-bypass.status /run/l2tp-vps-bypass.sig /run/l2tp-vps-bypass.rules /run/l2tp-vps-bypass.lsig
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
# bypass_show：用大白话显示排除端口，以及每个端口现在是怎么生效的。
bypass_show() {
  if ! bypass_on; then
    echo '不走 L2TP 的端口：无'
    echo '  高级：程序给某个出站设置 mark 149122（0x24682，如 WireGuard 的 fwmark），这个出站走 VPS 原生 IP、不经过 L2TP。'
    return 0
  fi
  printf '不走 L2TP 的端口：%s\n' "$(port_list ' ')"
  if [ -f "$STATE/disabled" ]; then echo '  （L2TP 已关闭，整台 VPS 现在都用原生 IP；重新运行安装命令后按上面的端口排除）'; return 0; fi
  if reserve_ok; then
    echo '  · 连进这些端口的连接、从这些端口发起的连接：全部走 VPS 原生 IP，不经过 L2TP'
  else
    echo '  · 连进这些端口的连接：走 VPS 原生 IP（端口太多或内核不允许保留端口，所以不按源端口排除）'
  fi
  if [ ! -f /run/l2tp-vps-bypass.status ]; then echo '  · 按程序排除：巡检服务没在运行，暂无结果'; return 0; fi
  awk -F'|' -v ports="$(port_list ' ')" '
    function name(p) { sub(/.*\//, "", p); return p }
    $1 == "none" { print "  · 按程序排除不可用：" $3 "。只排除端口本身的进出，节点转发的出站仍走 L2TP" }
    $1 == "ok" { n = split($3, q, " "); for (i = 1; i <= n; i++) seen[q[i]] = 1
      print "  · 端口 " $3 "：服务 " name($2) " 的全部出站都走 VPS 原生 IP" }
    $1 == "skip" { n = split($3, q, " "); for (i = 1; i <= n; i++) seen[q[i]] = 1
      print "  · 端口 " $3 "：服务 " name($2) " 只排除了端口本身的进出，它转发的出站仍走 L2TP"
      print "      原因：" $4
      print "      办法：把这个节点单独做成一个只用排除端口的服务，或在节点里给它的出站设置 mark 149122" }
    $1 == "fail" { print "  · 服务 " name($2) "：按程序排除没装上（需要内核 5.13+ 和 nftables 1.0+，或者装了 iptables 且内核 4.5+），只排除端口本身的进出" }
    END { n = split(ports, q, " ")
      for (i = 1; i <= n; i++) if (q[i] !~ /-/ && !(q[i] in seen)) print "  · 端口 " q[i] "：现在没有程序在监听（服务启动后 3 秒内自动识别；节点若跑在 Docker 网桥模式里，这里看不到它，它的出站仍走 L2TP，请改用 host 网络）" }' /run/l2tp-vps-bypass.status
  echo '  高级：节点程序给某个出站设置 mark 149122（0x24682），这个出站也走 VPS 原生 IP。'
}
# ports：查看或修改不走 L2TP 的端口，立即生效，不用重装。
#   sudo l2tp-vps ports                 查看；在终端里运行时可以接着输入新的端口
#   sudo l2tp-vps ports 1112 2000-2010  设置（替换原来的）
#   sudo l2tp-vps ports 0               清空
ports_cmd() {
  if [ "$#" = 0 ]; then
    bypass_show
    [ -t 0 ] || return 0
    printf '输入新的端口替换（多个用空格、逗号或顿号分隔，支持 2000-2010；回车不修改，0 表示清空）: '
    IFS= read -r input || input=
    [ -n "$input" ] || return 0
  else
    input="$*"
  fi
  case "$input" in
    0|none|无) new=;;
    *)
      if ! new=$(normalize_ports "$input" 2>/dev/null) || [ -z "$new" ]; then
        bad=$(normalize_ports "$input" 2>&1 >/dev/null || true)
        [ -z "$bad" ] || fatal "\"$bad\" 不是有效端口：端口只能是 1-65535 的数字，范围写成 2000-2010 这样。没有做任何修改"
        fatal "端口格式不对：${input}（只能填 1-65535 的数字，或 2000-2010 这样的范围）"
      fi;;
  esac
  [ ! -d /run/l2tp-vps-install.lock ] || fatal '安装/升级正在进行，请等它结束后再改'
  if [ -n "$new" ]; then
    printf '%s\n' "$new" > "$STATE/bypass-ports.new"
    chmod 600 "$STATE/bypass-ports.new"
    mv "$STATE/bypass-ports.new" "$STATE/bypass-ports"
  else
    rm -f "$STATE/bypass-ports"
  fi
  if [ -f "$STATE/disabled" ]; then
    echo '已保存。L2TP 现在是关闭状态（执行过 recover），重新运行安装命令后生效。'
    return 0
  fi
  [ -z "$new" ] || ensure_iptables
  guard
  echo '已生效：'
  bypass_show
}
# ensure_iptables：内核低于 5.13、或 nftables 低于 1.0 时，nftables 不能按程序排除，要靠 iptables（见 ipt_bypass）。
#   安装时如果没设排除端口就不会装它，之后用 ports 命令才设置的话，节点出站会一直走 L2TP，所以这里补装。
#   装不上也继续，只是退回到"只排除端口本身的进出"。
ensure_iptables() {
  command -v iptables >/dev/null 2>&1 && return 0
  uname -r | awk -F'[.-]' '{exit !($1 < 5 || ($1 == 5 && $2 < 13))}' ||
    nft --version 2>/dev/null | awk '{v = $2; sub(/^v/, "", v); split(v, a, "."); exit !(a[1] + 0 < 1)}' || return 0
  echo '内核或 nftables 版本较老，按程序排除需要 iptables，正在安装……'
  if [ "$INIT" = openrc ]; then
    apk add --no-cache iptables ip6tables >/dev/null 2>&1 || echo '没能安装 iptables：只排除端口本身的进出'
  else
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y iptables >/dev/null 2>&1 || echo '没能安装 iptables：只排除端口本身的进出'
  fi
}
# status：显示版本、隧道地址、隧道路由表、策略规则和防火墙。
status() {
  printf '版本：'; cat "$STATE/installed-version" 2>/dev/null || echo '未完成安装'
  printf '隧道：'; ip -4 -o addr show dev "$PEER" 2>/dev/null || true
  printf '出口路由：\n'; ip -4 route show table "$TABLE" 2>/dev/null || true
  printf '策略规则：\n'
  ip -4 rule show pref 8905 2>/dev/null || true
  ip -4 rule show pref 8906 2>/dev/null || true
  ip -4 rule show pref 8920 2>/dev/null || true
  ip -4 rule show pref 8930 2>/dev/null || true
  printf '防火墙：\n'; nft list table inet l2tp_vps 2>/dev/null || true
  bypass_show
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
  ports) ports_cmd "$@";;
  *) fatal '用法：l2tp-vps status | ports | update | rollback | recover | uninstall';;
esac
