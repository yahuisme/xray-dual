# xray-dual

一键安装和管理 Xray 的 VLESS-Reality 与 Shadowsocks-2022。

当前版本：`v26.09.11`

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh)
```

需要 Debian/Ubuntu 和 root 权限。

## 无交互安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh) install \
  --type dual --vless-port 12345 --sni www.sega.com --ss-port 23456
```

`--type` 必须指定：

- `vless`：VLESS-Reality，TLS 伪装，需支持 Reality 的客户端，无需自有域名或证书。
- `ss`：Shadowsocks-2022，预共享密钥，需支持 SS-2022 的客户端。
- `dual`：同时安装上述两种协议，使用独立端口，分别连接。

常用参数：

- `--vless-port <端口>`：默认 `443`。
- `--uuid <UUID>`：标准 UUID，未填写时随机生成。
- `--sni <域名>`：默认 `www.sega.com`，需为服务器可访问的 TLS 1.3 网站域名，不含协议或路径。
- `--ss-port <端口>`：默认 `8388`；双协议且 VLESS 端口非 `443` 时，默认使用 VLESS 端口加一。
- `--ss-pass <密钥>`：固定使用 `2022-blake3-aes-128-gcm`，密钥为 16 字节的标准 Base64（24 字符，以 `==` 结尾），未填写时随机生成。

修改配置时会展示当前值，留空保留；覆盖重装时 UUID 和 SS 密钥留空会重新随机生成。安装、追加和修改配置后会重启整个 Xray 服务，影响同一服务下的所有协议。

## 文件

- 配置：`/usr/local/etc/xray/config.json`
- 备份：`/usr/local/etc/xray/config.json.bak`
- 订阅信息：`/root/xray_subscription_info.txt`
- 服务日志：`journalctl -u xray`（菜单可实时查看）

## 行为与安全

- `--help` 和 `install --help` 无需 root；未知参数、缺少参数值返回退出码 2，帮助也不会忽略尾随错误参数。
- 交互输入遇到 EOF 会取消当前操作或退出菜单；卸载仅在输入 `y` / `Y` 后执行，会清除整个 Xray（所有协议）及配置、备份、订阅和日志，含自定义内容。
- 端口须为 1–65535 的十进制整数，不接受前导零。双协议端口不能相同；非交互双协议安装中 VLESS 使用 65535 时需显式指定 SS 端口，交互安装需改用低于 65535 的 VLESS 端口。
- 单协议重装只替换该协议，保留另一托管协议、自定义 inbound、DNS 等现有设置。
- 配置生成、写入或校验失败不会继续重启；配置启动失败仅使用本次操作备份恢复，不会误用旧 `.bak`。恢复失败会报告保留材料的位置。
- 更新前备份核心与 GeoIP/GeoSite，失败时按实际变化恢复文件及原运行/停止状态。官方安装器本身可能停止或启动服务，更新并非无中断操作；恢复失败会保留 `/var/tmp/xray-update.*` 供人工处理。
- Reality 公钥缺失时尝试通过现有核心从私钥推导；无法推导则明确失败，不生成损坏订阅。
- `NO_COLOR`、`TERM=dumb` 或任一输出流被重定向时使用纯文本输出。

## 静态检查

```bash
bash -n install.sh
shellcheck install.sh
git diff --check
```

运行安装和更新会修改系统；不要在生产主机上直接执行故障注入测试。
