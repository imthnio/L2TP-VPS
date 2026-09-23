# L2TP+VPS

在 Debian、Ubuntu 或 Alpine VPS 上连接 A&A L2TP，并建立 VLESS 节点。安装完成后，**这台 VPS 的普通 IPv4 出站流量**（例如 `curl`、软件更新和节点转发）走 A&A 的出口 IP。IPv6 只有在 L2TP 隧道获得可用的公网 IPv6 时才走隧道；否则普通 IPv6 出站被阻断。

L2TP 接入服务器本身的流量，以及从 VPS 原生 IP 进入的 SSH、VLESS 等连接的回包，必须继续使用 VPS 原生线路。这是保持隧道和管理入口可用的必要例外。因此不能把“所有网络包”理解为连这些包也改走 A&A。

## 一行安装

在**目标 VPS 的 SSH 终端**运行下面一整行。请先确认旧 VPS 已停止使用同一条 A&A L2TP 连接，并保留 VPS 提供商的网页控制台，以便网络配置异常时恢复。

```sh
curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 -o /tmp/l2tp-vps-install.sh https://raw.githubusercontent.com/imthnio/L2TP-VPS/main/install.sh && if [ "$(id -u)" -eq 0 ]; then sh /tmp/l2tp-vps-install.sh; else sudo sh /tmp/l2tp-vps-install.sh; fi
```

脚本需要交互输入，因此先下载再运行。不要用 `curl ... | sudo sh`，那样脚本通常读不到你在终端输入的账号和选项。

## 安装时输入

1. A&A L2TP 服务器地址、线路用户名和密码。
2. VLESS 端口（1–65535，且未被占用）。
3. 传输方式：TCP + REALITY（默认）或 WebSocket。
4. 如果选择 REALITY，选择目标网站。

脚本自动生成 UUID，并在成功拨号、验证普通 IPv4 出口后输出 `vless://` 链接。目标 VPS 需要独立公网 IPv4、PPP 内核支持，以及运行中的 systemd（Debian/Ubuntu）或 OpenRC（Alpine）。云平台安全组仍需放行所选 TCP 端口。

## 路由与断线保护

安装器在策略路由表中保留禁止默认路由。L2TP 接通时增加优先级更高的 PPP 默认路由；隧道断开或 PPP 接口意外消失时，普通出站会被阻断，不会自动回落到 VPS 原生出口。原生 IP 的管理连接回包和到 A&A 接入服务器的流量保留原生路径。

A&A 接入服务器域名会在安装时解析并固定为 IPv4，以便断线后拨号不依赖被保护规则阻断的 DNS。如果 A&A 以后更改该接入点的 IP，且旧隧道已经断开，请从 A&A 获取新的接入点 IPv4，在 VPS 提供商的网页控制台中重新运行安装器并直接填写这个 IPv4；断线保护启用时，域名解析也可能被阻断。安装器会备份覆盖前的 `/etc/xl2tpd/xl2tpd.conf` 和 `/etc/ppp/chap-secrets` 到 `/etc/l2tp-vless/`。

安装器会在配置完成后**自动运行三项检查**，逐行用中文解释结果：

1. 查询整台 VPS 的普通 IPv4 公网出口，并显示查到的地址（应与 A&A 出口 IPv4 一致）。
2. 显示 A&A 路由表，分别标注 PPP 隧道默认路由、断线时阻止回落的禁止路由，以及接入服务器使用的原生线路。
3. 显示出站策略规则，标注原生 IP 管理连接回包、普通流量走 A&A 路由表等规则。

如果公网出口仍是 VPS 原生 IP，或关键路由和规则缺失，安装器会报错，不会显示“安装完成”。这属于脚本在目标 VPS 上的自动检查；公网 IP 的实际归属仍可在 A&A 控制页核对。没有实机安装前，不能把静态脚本检查当作部署成功。
