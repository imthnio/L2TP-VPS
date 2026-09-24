# L2TP+VPS

在 Debian、Ubuntu 或 Alpine VPS 上连接 A&A L2TP，让整台 VPS 的普通出站流量走隧道。安装完成后，**这台 VPS 的普通 IPv4 出站流量**（例如 `curl`、软件更新）走 A&A 的出口 IP。IPv6 只有在 L2TP 隧道获得可用的公网 IPv6 时才走隧道；否则普通 IPv6 出站被阻断。

L2TP 接入服务器本身的流量，以及从 VPS 原生 IP 进入的 SSH 等连接的回包，必须继续使用 VPS 原生线路。这是保持隧道和管理入口可用的必要例外。因此不能把“所有网络包”理解为连这些包也改走 A&A。

## 一行安装

在**目标 VPS 的 SSH 终端**运行下面一整行。请先确认旧 VPS 已停止使用同一条 A&A L2TP 连接，并保留 VPS 提供商的网页控制台，以便网络配置异常时恢复。

```sh
_dl_ok=""; _cb="$(date +%s)"; for _m in "https://raw.githubusercontent.com/imthnio/L2TP-VPS/main/install.sh?cb=${_cb}" "https://cdn.jsdelivr.net/gh/imthnio/L2TP-VPS@main/install.sh" "https://gh-proxy.com/https://raw.githubusercontent.com/imthnio/L2TP-VPS/main/install.sh"; do curl -fsSL --connect-timeout 15 --max-time 60 --retry 2 -o /tmp/l2tp-vps-install.sh "$_m" 2>/dev/null && case "$(head -c 9 /tmp/l2tp-vps-install.sh 2>/dev/null)" in "#"*"bin/sh") _dl_ok=1;; esac; [ -n "$_dl_ok" ] && break; done; if [ -n "$_dl_ok" ]; then if [ "$(id -u)" -eq 0 ]; then sh /tmp/l2tp-vps-install.sh; else sudo sh /tmp/l2tp-vps-install.sh; fi; else echo "安装脚本下载失败：直连和镜像都连不上，请检查 VPS 网络后重试"; fi
```

直连失败时会自动换 jsdelivr / gh-proxy 镜像重试。脚本需要交互输入，因此先下载再运行。不要用 `curl ... | sudo sh`，那样脚本通常读不到你在终端输入的账号和选项。

## 安装时输入

只问 A&A L2TP 服务器地址、线路用户名和密码。

脚本在成功拨号、验证普通 IPv4 出口走 A&A 后显示结果。目标 VPS 需要独立公网 IPv4、PPP 内核支持，以及运行中的 systemd（Debian/Ubuntu）或 OpenRC（Alpine）。

## 删除

在 VPS 上运行 `shanchu`，删除脚本安装的一切（L2TP 拨号、策略路由、相关文件和软件包）。

## 赞赏支持
如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕  
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)
