## 一行安装 / 升级

**已经安装过也运行下面同一条命令，自动保留账号，不需要先卸载。** 升级会重拨 L2TP，经过隧道的连接会短暂中断。请保留服务商的网页控制台。

在**目标 VPS 的 SSH 终端**复制整行运行。首次安装询问服务器、用户名、密码；升级复用已有配置。

```sh
if [ -f /usr/local/sbin/l2tp-vps ]; then if [ "$(id -u)" = 0 ]; then /usr/local/sbin/l2tp-vps update; else sudo /usr/local/sbin/l2tp-vps update; fi; else (set -eu; d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; u="https://raw.githubusercontent.com/imthnio/L2TP-VPS/main/bootstrap.sh?cb=$(date +%s)"; if ! curl -4 --noproxy '*' -fsSL --connect-timeout 10 --max-time 45 "$u" -o "$d/start.sh"; then n=$(ip -4 route show default table main | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}'); a=$(ip -4 -o addr show dev "$n" scope global | awk 'NR==1{split($4,a,"/");print a[1]}'); j=$(curl -4 --noproxy '*' --interface "$a" -fsS --max-time 20 -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=raw.githubusercontent.com&type=A'); r=$(printf '%s' "$j" | tr ',' '\n' | sed -n 's/.*"data":[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1); [ -n "$r" ]; curl -4 --noproxy '*' --interface "$a" --resolve "raw.githubusercontent.com:443:$r" -fsSL --max-time 60 "$u" -o "$d/start.sh"; fi; sh -n "$d/start.sh"; sh "$d/start.sh"); fi
```

下载入口先确认 GitHub `main` 的最新提交，再从该提交下载并校验安装器。GitHub Raw 失败时尝试 **同一个提交** 的 jsDelivr 文件，不使用可能过期的 `@main` 镜像。GitHub API 限流（同一 IP 每小时 60 次，共享 IP 的 NAT 机器容易碰到）时，改用 git 引用列表确认同一个 `main` 提交；都不可达才明确报错，不把缓存旧版冒充最新版本。

旧版保存的安装命令仍能在成功下载最新 `install.sh` 后进行升级。但旧命令的镜像可能缓存旧版，建议以后使用上面的新命令。

## 已安装机器的升级行为

- 自动读取并保留服务器、用户名、密码；包含引号、反斜杠和空格的旧密码也按原格式解析。
- 改动前保存 root 专用备份，路径为 `/etc/l2tp-vless/backups/`。
- 使用独立的 `l2tp-vps` 服务和配置。隧道网卡名是 `l2tp-aa`，这只是本机接口名，不表示接入商是哪一家。不再覆写共享 PPP 密码文件。旧版迁移会先验证旧配置确实属于本项目，再停止旧连接、恢复此前的共享配置备份。
- 拨号或出口验证失败时，不标记升级成功，也不会自动放开普通出站。提前安装的恢复命令可离线使用。
- 新版提供独立的维护下载账号，仅允许原生 DNS/HTTPS。普通应用即使绑定原生 IP，也不能借此绕过保护；隧道断开时仍可下载更新。

旧版只保存了服务器 **IP**，没有保存用户输入的域名，升级不能凭空恢复原域名，因此默认保留旧 IP。如果接入点是域名，希望断线后继续解析这个域名，升级时显式指定：

```sh
sudo env L2TP_SERVER=你的接入域名 /usr/local/sbin/l2tp-vps update
```

日常升级不需要带环境变量。要更换账号时再传入 `L2TP_USER` 和 `L2TP_PASS`。

## 常用命令

| 操作 | 命令 |
|---|---|
| 升级到最新版本，保留账号 | `sudo l2tp-vps update` |
| 查看版本、接口、路由和防火墙 | `sudo l2tp-vps status` |
| 恢复 VPS 原生上网 | `sudo l2tp-vps recover` |
| 离线回滚到上一次成功的新版安装快照 | `sudo l2tp-vps rollback` |
| 卸载本项目的连接和保护 | `sudo shanchu` |

`recover` 会停止本项目的服务、移除自有保护规则并恢复原 DNS。**执行后流量使用 VPS 原生出口，断线保护关闭。** 重新运行安装命令即可启用隧道。

`shanchu` 不会终止其他 PPP 连接、不清空其他路由表、不卸载共享软件包。为防止丢失账号，凭据和备份仍保留在 `/etc/l2tp-vless/`，仅 root 可读。第一次从旧版迁移没有可离线重装的新版快照，此时使用 `recover`；之后的新版升级支持 `rollback`。

## 系统要求和范围

- Debian / Ubuntu 使用运行中的 systemd；Alpine 使用 OpenRC。需要 PPP、nftables 和修改路由的权限。受限 LXC/OpenVZ 容器不保证具备这些能力。
- VPS 需要独立公网 IPv4 和正常的原生默认路由。脚本不配置 NAT 商家的端口映射。
- 本机上新开的连接都从 L2TP 出去，包括在这台机器上搭建的节点向外访问网络的流量。节点即使绑定了 VPS 原来的公网地址，发出去之前也会再选一次路，进入隧道，并把出口地址换成隧道地址。
- 从网卡外面连进来的连接，例如 SSH 和节点端口，回应仍从 VPS 原来的地址发出。客户端里填写的服务器地址继续用 VPS 原来的地址。
- 隧道没拨上时，这些出站会被拒绝，不会改回 VPS 自己的地址。
- 跑在 Docker 网桥里的容器（以及 WireGuard 等在本机转发的客户端）：隧道在线时经 L2TP 出去，映射端口的回包仍走 VPS 原地址，本机也能直接访问容器；但隧道断开时它们**不受断线保护**，会从 VPS 原地址出去。需要严格保护的节点请用 host 网络模式直接跑在本机。
- IPv6 在专用 PPP 接口确实拥有全局地址后才启用隧道路由，否则普通 IPv6 阻断，避免从 VPS 原地址漏出去。脚本不自动申请 DHCPv6-PD 前缀。
- 为避免原生 DNS 在断线后泄漏，本机解析使用 `1.1.1.1` / `9.9.9.9` 并经过隧道；维护下载单独使用原生线路。原 `/etc/resolv.conf` 会备份，恢复/卸载时还原。自定义内网 DNS、搜索域或依赖网络管理器重写 DNS 的机器需要先评估适用性。
- 本脚本只拨 **不带 IPsec 的 L2TP**（UDP 1701），认证用 CHAP，不用明文 PAP。接入商可以是任何提供这种 L2TP 的服务商。服务端如果强制 IPsec，或只接受 PAP，本脚本不会连接。L2TP 本身不加密，应用应继续使用 HTTPS 等端到端加密。
- 有的服务商把隧道地址做成内网地址再做 NAT，公网出口可以和 PPP 地址不同。安装成功看这三件事：出站走隧道网卡、源地址是隧道地址、公网出口不是 VPS 原生地址。

## 开发与验证

`install.sh` 是可单独下载运行的完整安装器，由 `src/install.sh` 和 `src/runtime.sh` 构建。修改源码后运行：

```sh
python3 tools/build.py
python3 tests/test_runtime.py
python3 tests/test_lifecycle.py
shellcheck -S warning install.sh bootstrap.sh src/runtime.sh
sudo python3 tests/test_netns.py
```

Linux 网络测试只操作新建的独立 network namespace，验证真实内核路由、原生 IPv4/IPv6 出站拦截、管理回包、维护下载 UID、接口意外消失及精确清理。它不等于在 Debian、Ubuntu、Alpine 三种真实 VPS 上完成拨号验收。

## 赞赏支持

如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)
