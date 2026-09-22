# L2TP+VPS

L2TP利用VPS搭建节点一键脚本：出站默认走 L2TP 隧道，出口 IP 是L2TP的出口IP地址。

## 一行安装

```sh
curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 \
  https://raw.githubusercontent.com/imthnio/L2TP-VPS/main/install.sh | sudo sh
```

## 安装时会问什么

第一阶段（先问，输完就开始装依赖、拨号）：
- L2TP 服务器地址（IP 或域名）
- L2TP 用户名
- L2TP 密码（输入不回显）

第二阶段（拨号完成后，配置节点）：
- 端口（手动输入纯数字，无默认值；输错或被占用会提示重输）
- 传输方式：1) TCP + REALITY（默认，推荐） 2) WebSocket 明文
- REALITY 目标网站 12 选 1（默认 `www.samsung.com`）

UUID 自动生成，不用输入。装完输出 `vless://` 链接。

## 断网保护（重点）

L2TP 一断（比如忘记续费、账号过期），出站直接被丢弃——节点断网，绝不会落到 VPS 的 IP 上。隧道恢复后自动恢复，不用重跑脚本。

整台 VPS 的默认路由不动（不然 L2TP 一断你连 SSH 都上不去）；L2TP 服务器本身有主机路由走原始网关，避免隧道自环；ppp0 上对 TCP 做 MSS 钳制，防 PMTU 黑洞。

节点信息保存在 `/etc/l2tp-vless/node.txt`，随时可以 `cat` 查看。
