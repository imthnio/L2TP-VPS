# vless-l2tp

德国 VPS 一键脚本：xl2tpd 拨号 L2TP（英国）+ 搭建 VLESS 节点，VLESS 的出站流量经 L2TP 隧道出去，出口 IP 变成 L2TP 分配的英国 IP。

## 一行安装

```sh
curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 \
  https://raw.githubusercontent.com/imthnio/vless-l2tp/main/install.sh | sudo sh
```

## 安装时会问什么

第一阶段（先问，输完就开始装依赖、拨号）：
- L2TP 服务器地址（IP 或域名）
- L2TP 用户名
- L2TP 密码（输入不回显）

第二阶段（拨号完成后，配置节点）：
- VLESS 端口（手动输入纯数字，无默认值；输错或端口被占用会提示重输）
- 传输方式：1) TCP + REALITY（默认，推荐） 2) WebSocket 明文
- REALITY 目标网站 12 选 1（默认 `www.samsung.com`，另有 cisco / itunes.apple / python.org / amazon 系 / mozilla / lovelive-anime.jp / nvidia / riotcdn / awsstatic / amd 备选）/ WS 路径（默认 `/ws`）

UUID 自动生成，不用输入。装完输出的 `vless://` 链接里有。

无终端环境可用环境变量传入：必填 `L2TP_SERVER` `L2TP_USER` `L2TP_PASS` `VLESS_PORT`；
可选 `VLESS_UUID` `TRANSPORT=reality|ws` `REALITY_DEST` `WS_PATH`。

## 原理

- xl2tpd 作 L2TP 客户端拨号，拿到 `ppp0` 与英国 IP
- xray 出站用 `streamSettings.sockopt.mark=100` 给出站包打标记，策略路由 `fwmark 100 → table 100`，表里是 `default dev ppp0`（拨号成功/断开由 `/etc/ppp/ip-up.d` / `ip-down.d` 自动维护）
- L2TP 服务器本身加了主机路由走原始网关，避免隧道流量被策略路由吸走导致自环
- `ppp0` 上对 TCP 做 MSS 钳制，防 PMTU 黑洞
- 开机自动保路由 + 自动拨号；VLESS 端口自动放行（ufw / firewalld / iptables）

装完输出 `vless://` 链接（也存于 `/etc/l2tp-vless/client-link.txt`），并实测显示出口 IP。

## 注意

- 只支持纯 L2TP（无 IPsec）。如果你的服务商要求 IPsec PSK，提 issue 说明。
- VPS 内核须支持 PPP（KVM 一般没问题；OpenVZ / LXC 可能不行）。
- L2TP 服务器如果是域名且 IP 变了，重跑一遍脚本即可。
- 客户端连接的是德国 VPS 的 IP:端口；访问网站时的源 IP 才是英国 IP。
