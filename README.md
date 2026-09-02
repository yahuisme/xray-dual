# xray-dual

一键安装和管理 Xray 的 VLESS-Reality 与 Shadowsocks-2022。

当前版本：`v26.09.02`

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

`--type` 可选：`vless`、`ss`、`dual`。

常用参数：

- `--vless-port <端口>`
- `--uuid <UUID>`
- `--sni <域名>`
- `--ss-port <端口>`
- `--ss-pass <密钥>`

未填写 UUID 或 SS 密钥时会自动生成。

## 文件

- 配置：`/usr/local/etc/xray/config.json`
- 备份：`/usr/local/etc/xray/config.json.bak`
- 订阅信息：`/root/xray_subscription_info.txt`

## 测试

```bash
bash -n install.sh
bash test_regressions.sh
```
