# xray-dual

一键安装和管理 Xray 的 **VLESS-Reality、Shadowsocks-2022 或双协议**。

## 使用

需要 **Debian/Ubuntu、root、Bash、curl、systemd**；在交互终端运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh)
```

选择 `1` 安装，再选择协议；完成后将输出的链接导入支持对应协议的客户端。

- **VLESS-Reality**：TLS 伪装，默认端口 `443`、SNI `www.sega.com`；客户端须支持 REALITY + Vision，无需自有域名或证书。
- **SS-2022**：默认端口 `8388`，使用 `2022-blake3-aes-128-gcm`；客户端须支持此算法。
- **双协议**：同时安装，使用不同端口，分别连接。

UUID、SS 密钥留空随机生成。SNI 须为服务器可访问、支持 TLS 1.3 的目标域名（443），不含协议或路径。请在服务器防火墙和云安全组放行 **VLESS 的 TCP 端口、SS 的 TCP/UDP 端口**。

## 管理

再次运行上方命令，按菜单更新、修改/追加协议、重启、卸载或查看订阅与日志。

- 配置：`/usr/local/etc/xray/config.json`；备份：同路径加 `.bak`。
- 订阅：`/root/xray_subscription_info.txt`，含连接凭据，请勿公开。
- 状态：`systemctl status xray`；日志：`journalctl -u xray -n 50 --no-pager`。
- 修改留空保留当前值；重装 UUID、SS 密钥留空会重新生成，REALITY 重装也会换密钥，须重新导入客户端。
- 单协议重装保留另一托管协议及其他自定义配置；双协议重装重配两个协议。安装、追加和修改会重启整个 Xray，更新也可能中断连接。
- **卸载清除整个 Xray、所有协议、配置、订阅和日志，含自定义内容；输入 `y` / `Y` 确认，回车取消。**

<details>
<summary>无交互安装与参数</summary>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh) install --type dual --vless-port 12345 --sni www.sega.com --ss-port 23456
```

- `--type` 必填：`vless`、`ss` 或 `dual`。
- `--vless-port` 默认 `443`，`--ss-port` 默认 `8388`；双协议且 VLESS 端口非 `443` 时，SS 默认使用 VLESS 端口加一。端口不能相同；VLESS 为 `65535` 时须显式指定 SS 端口。
- `--uuid`、`--ss-pass` 不填随机生成；手填 SS 密钥须为 16 字节的标准 Base64（24 字符，以 `==` 结尾）。
- `--sni` 默认 `www.sega.com`。在首次命令末尾加 `install --help` 查看完整参数。

</details>

失败时脚本尝试回滚；未完成时保留报出的 `config.json.rollback.*` 或 `/var/tmp/xray-transaction.*`，人工恢复并核对服务状态后再重试。重新运行不会自动接续恢复，勿删除备份绕过错误。
