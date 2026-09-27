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
mkdir /run/l2tp-vps-install.lock 2>/dev/null || fatal '另一个安装/升级正在进行；若上次被强制终止，请重启后重试'
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
    apt-get -o DPkg::Lock::Timeout=120 update
    apt-get -o DPkg::Lock::Timeout=120 install -y curl ca-certificates iproute2 nftables xl2tpd ppp dnsutils
    unset DEBIAN_FRONTEND
  fi
fi
for binary in curl ip nft xl2tpd pppd su nslookup timeout; do command -v "$binary" >/dev/null || fatal "缺少 $binary"; done
modprobe ppp_generic 2>/dev/null || true
[ -c /dev/ppp ] || mknod /dev/ppp c 108 0 2>/dev/null || true
[ -c /dev/ppp ] || fatal 'VPS 不支持 PPP；需由商家启用 /dev/ppp'
# Reserve only an unused namespace on first migration; never flush somebody else's table.
if [ ! -f "$STATE/v2-owned" ]; then
  for family in -4 -6; do
    [ -z "$(ip "$family" route show table 24680 2>/dev/null)" ] || fatal '路由表 24680 已被其他软件使用'
    for pref in 8900 8904 8905 8910 8911 8920 8930; do
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
@@RUNTIME@@
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
