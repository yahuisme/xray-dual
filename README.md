# xray-dual
一键安装和管理基于 Xray 核心的 VLESS-reality 和 Shadowsocks-2022 双协议脚本

## 交互安装
```
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh)
```

## 无交互安装 VLESS-reality 单协议
```
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh) vless 12345 d0f6a483-51b3-44eb-94b6-1f5fc9272c81 www.sega.com
```

## 无交互安装 Shadowsocks-2022 单协议
```
bash <(curl -sL https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh) ss 12345 X3Z7Cp6YoxFvjD1dS+Gy4w==
```

## 无交互安装双协议
```
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-dual/main/install.sh) dual 12345 d0f6a483-51b3-44eb-94b6-1f5fc9272c81 www.sega.com X3Z7Cp6YoxFvjD1dS+Gy4w==
```

以上无交互脚本均可以自行修改端口、UUID、网址和 ss-2022 密钥。
