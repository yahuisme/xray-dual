# xray-dual

一键安装和管理 Xray 的 VLESS-Reality 与 Shadowsocks-2022。

当前版本：`v26.09.27`

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
- 端口须为 1–65535 的十进制整数，不接受前导零。安装、追加和修改均拒绝托管协议与保留 inbound 的同端口冲突（含端口范围）；端口探测失败会停止操作。非交互双协议安装中 VLESS 使用 65535 时需显式指定 SS 端口，交互安装需改用低于 65535 的 VLESS 端口。
- 单协议重装只替换该协议，保留另一托管协议、自定义 inbound、DNS 等现有设置。
- 配置生成、写入或校验失败不会继续重启；配置启动失败仅使用本次操作备份恢复，不会误用旧 `.bak`。恢复失败会报告保留材料的位置。
- 安装、重装和更新前备份核心、GeoIP/GeoSite、配置与服务定义；失败时恢复文件权限及原运行/停止状态。已有主单元时保留服务及 drop-in，主单元缺失而存在残留时拒绝覆盖。官方安装器可能重启服务，操作并非无中断；恢复失败会保留 `/var/tmp/xray-transaction.*`，同一菜单会阻止覆盖恢复基准。
- 新协议在 IPv6 可用时默认使用 `::` 原生双栈监听，IPv6 禁用时使用 `0.0.0.0`；修改/重装保留原监听地址。重启检查同一真实核心 MainPID 在有限时间内保持稳定，不等同于外网连通性验证。
- SS-2022 订阅按 SIP002 对算法与密钥分别进行百分号编码。卸载支持仅配置或仅 drop-in 的残留，独立核对残留进程的可执行文件路径后发送 TERM；检查或停止失败时保留文件。
- Reality 公钥缺失时尝试通过现有核心从私钥推导；无法推导则明确失败，不生成损坏订阅。
- `NO_COLOR`、`TERM=dumb` 或任一输出流被重定向时使用纯文本输出。

## 静态检查

```bash
bash -n install.sh
shellcheck install.sh
git diff --check
python3 tests/regression.py
```

隔离回归只提取函数，服务、进程及网络均使用 mock，临时文件位于 `TMPDIR`。可选设置 `XRAY_TEST_BINARY` 指向可信官方核心（仅密钥生成和 `run -test`），`PINNED_INSTALLER` 指向 SHA256 校验匹配的固定官方脚本（只提取 main 并 mock 所有副作用）。

运行安装和更新会修改系统；不要在生产主机上直接执行故障注入测试。
