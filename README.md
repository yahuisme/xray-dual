# xray-dual
一键安装和管理基于 Xray 核心的 VLESS-reality 和 Shadowsocks-2022 双协议脚本

## 功能特点

* **最新协议支持**：完整支持 **VLESS-Reality-PQE（抗量子加密）** 及 **Shadowsocks-2022**两种主流配置。

* **安装选项灵活**：支持单独安装任一协议，或一键部署 VLESS + SS **双协议共存**模式。

* **菜单界面直观**：通过清晰、交互式的菜单完成所有操作，**无需手动编辑**。

* **自动生成分享链接**：安装或修改后，自动生成 VLESS 和 SS 协议的**分享链接**，方便一键导入客户端。

* **全功能管理**：集成了安装、更新、卸载、修改配置、重启服务、查看日志等所有常用管理功能。

* **强大的自动化支持**：支持完整的**非交互式命令行模式**，可通过参数实现全自动静默安装与部署。

* **健壮性与稳定性**：在 Shell 严格模式 (`set -euo pipefail`) 下编写，对网络错误、用户输入和服务状态异常进行了全面的加固，确保运行稳定。

## 一键脚本
```
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh)
```

## 无交互安装双协议
```
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh) install --type dual --vless-port 12345 --uuid 'd0f6a483-51b3-44eb-94b6-1f5fc9272c81' --sni www.sega.com --pqe --ss-port 23456 --ss-pass 'X3Z7Cp6YoxFvjD1dS+Gy4w=='
```

以上无交互脚本均可以自行修改端口、UUID、网址和 ss-2022 密钥。
