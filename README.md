## 一行安装 / 升级

**已经安装过也运行下面同一条命令，自动保留账号，不需要先卸载。** 升级会重拨 L2TP，经过隧道的连接会短暂中断。请保留服务商的网页控制台。

在**目标 VPS 的 SSH 终端**复制整行运行。首次安装询问服务器、用户名、密码；升级复用已有配置。

```sh
if [ -f /usr/local/sbin/l2tp-vps ]; then if [ "$(id -u)" = 0 ]; then /usr/local/sbin/l2tp-vps update; else sudo /usr/local/sbin/l2tp-vps update; fi; else (set -eu; d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; u="https://raw.githubusercontent.com/imthnio/L2TP-VPS/main/bootstrap.sh?cb=$(date +%s)"; if ! curl -4 --noproxy '*' -fsSL --connect-timeout 10 --max-time 45 "$u" -o "$d/start.sh"; then n=$(ip -4 route show default table main | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}'); a=$(ip -4 -o addr show dev "$n" scope global | awk 'NR==1{split($4,a,"/");print a[1]}'); j=$(curl -4 --noproxy '*' --interface "$a" -fsS --max-time 20 -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=raw.githubusercontent.com&type=A'); r=$(printf '%s' "$j" | tr ',' '\n' | sed -n 's/.*"data":[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1); [ -n "$r" ]; curl -4 --noproxy '*' --interface "$a" --resolve "raw.githubusercontent.com:443:$r" -fsSL --max-time 60 "$u" -o "$d/start.sh"; fi; sh -n "$d/start.sh"; sh "$d/start.sh"); fi
```

## 赞赏支持

如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)

