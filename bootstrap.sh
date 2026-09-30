#!/bin/sh
# L2TP-VPS 下载入口（README 里的一行命令会先下载并运行它）。
# 做三件事：
#   1. 问 GitHub API：main 分支现在最新的提交编号是多少（40 位十六进制）。
#   2. 只从这个固定编号下载 install.sh 和 SHA256SUMS（先试 GitHub，失败再试 jsDelivr 镜像的同一提交），
#      不用可能被缓存成旧版的 main 地址。
#   3. 核对 install.sh 的 SHA256 校验值，一致才运行；不一致说明文件损坏或被篡改，直接退出。
set -eu
umask 077
# 不是 root 就用 sudo 重新运行自己。
if [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null 2>&1 || { echo '需要 root 权限：本机没有 sudo，请先 su - 切换到 root 再运行' >&2; exit 1; }
  exec sudo sh "$0" "$@"
fi
tmp=$(mktemp -d /tmp/l2tp-bootstrap.XXXXXXXX)
# 临时目录在脚本退出时自动删除。
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# fetch 网址 保存路径：下载一个文件。
#   已装新版：交给 l2tp-vps fetch，用维护账号走原生网络下载（隧道断开也能升级）。
#   否则直接用 curl 下载；再不行（旧版的断线保护挡住了），就绑定原生 IP，
#   先用 1.1.1.1 的 HTTPS DNS 查出域名的 IP，再指定这个 IP 下载。
fetch() {
  url=$1; dest=$2
  if [ -x /usr/local/sbin/l2tp-vps ] && [ -f /etc/l2tp-vless/v2-owned ]; then
    /usr/local/sbin/l2tp-vps fetch "$url" "$dest" && return 0
  fi
  curl -4 --noproxy '*' --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 10 --max-time 60 --retry 1 -o "$dest" "$url" && return 0
  # 旧版（v1）允许"绑定原生 IP"的连接直接出去。这里只借这个口子下载本仓库的文件，
  # 不会删除旧版的保护规则，也不会给普通程序开口子。
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
# 从 SHA256SUMS 里取出 install.sh 的正确校验值，和实际下载的文件对比。
expected=$(awk '$2=="install.sh" {print $1}' "$tmp/SHA256SUMS")
[ "${#expected}" = 64 ] || exit 1
actual=$(sha256sum "$tmp/install.sh" | awk '{print $1}')
[ "$expected" = "$actual" ] || { echo '下载校验失败，没有执行' >&2; exit 1; }
# sh -n 只检查语法不执行，防止下载到一半的文件被运行。
sh -n "$tmp/install.sh"
printf '已验证最新提交：%s\n' "$commit"
sh "$tmp/install.sh" "$@"
