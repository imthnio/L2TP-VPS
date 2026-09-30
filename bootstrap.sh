#!/bin/sh
# L2TP-VPS bootstrap: resolve main once, then fetch only that immutable commit.
set -eu
umask 077
if [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null 2>&1 || { echo '需要 root 权限：本机没有 sudo，请先 su - 切换到 root 再运行' >&2; exit 1; }
  exec sudo sh "$0" "$@"
fi
tmp=$(mktemp -d /tmp/l2tp-bootstrap.XXXXXXXX)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fetch() {
  url=$1; dest=$2
  if [ -x /usr/local/sbin/l2tp-vps ] && [ -f /etc/l2tp-vless/v2-owned ]; then
    /usr/local/sbin/l2tp-vps fetch "$url" "$dest" && return 0
  fi
  curl -4 --noproxy '*' --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 10 --max-time 60 --retry 1 -o "$dest" "$url" && return 0
  # v1 permitted native source addresses. This fallback only downloads this repo;
  # it does not remove the old fail-closed rules or open ordinary app traffic.
  nic=$(ip -4 route show default table main | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
  addr=$(ip -4 -o addr show dev "$nic" scope global | awk 'NR==1{split($4,a,"/");print a[1]}')
  [ -n "$addr" ] || return 1
  host=${url#https://}; host=${host%%/*}
  dns=$(curl -4 --noproxy '*' --interface "$addr" -fsS --connect-timeout 10 --max-time 20 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$host&type=A") || return 1
  resolved=$(printf '%s' "$dns" | tr ',' '\n' | sed -n 's/.*"data":[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1)
  [ -n "$resolved" ] || return 1
  curl -4 --noproxy '*' --interface "$addr" --resolve "$host:443:$resolved" --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 10 --max-time 60 --retry 1 -o "$dest" "$url"
}
fetch "https://api.github.com/repos/imthnio/L2TP-VPS/commits/main?cb=$(date +%s)" "$tmp/commit.json" || { echo '无法确认最新版本（网络错误或 GitHub API 限流），未安装缓存旧版' >&2; exit 1; }
commit=$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$tmp/commit.json" | head -1)
[ "${#commit}" = 40 ] || { echo 'GitHub 未返回有效提交' >&2; exit 1; }
case "$commit" in *[!0-9a-f]*) exit 1;; esac
for file in install.sh SHA256SUMS; do
  fetch "https://raw.githubusercontent.com/imthnio/L2TP-VPS/$commit/$file" "$tmp/$file" ||
    fetch "https://cdn.jsdelivr.net/gh/imthnio/L2TP-VPS@$commit/$file" "$tmp/$file" || exit 1
done
expected=$(awk '$2=="install.sh" {print $1}' "$tmp/SHA256SUMS")
[ "${#expected}" = 64 ] || exit 1
actual=$(sha256sum "$tmp/install.sh" | awk '{print $1}')
[ "$expected" = "$actual" ] || { echo '下载校验失败，没有执行' >&2; exit 1; }
sh -n "$tmp/install.sh"
printf '已验证最新提交：%s\n' "$commit"
sh "$tmp/install.sh" "$@"
