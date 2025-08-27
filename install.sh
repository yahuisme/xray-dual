#!/bin/bash

# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本
# 版本: Final
# 支持: Debian/Ubuntu 及其衍生系统

# ----------------------- 全局常量 -----------------------
SCRIPT_VERSION="Final"
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BINARY_PATH="/usr/local/bin/xray"

# ----------------------- 颜色定义 -----------------------
RED='\e[91m'
GREEN='\e[92m'
YELLOW='\e[93m'
MAGENTA='\e[95m'
CYAN='\e[96m'
NONE='\e[0m'

# ----------------------- 全局变量 -----------------------
xray_status_info=""

# ----------------------- 通用工具函数 -----------------------
# 输出错误信息
error() {
    echo -e "\n${RED}${1}${NONE}\n"
}

# 输出提示信息
info() {
    echo -e "\n${YELLOW}${1}${NONE}\n"
}

# 输出成功信息
success() {
    echo -e "\n${GREEN}${1}${NONE}\n"
}

# 显示加载动画
spinner() {
    local pid=$1
    local spinstr='|/-\-'
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

# 检查运行环境
pre_check() {
    [[ $(id -u) != 0 ]] && error "错误: 必须以 root 用户身份运行此脚本" && exit 1
    if [[ ! -f /etc/debian_version ]]; then
        error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统"
        exit 1
    fi
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失依赖 (jq/curl)，正在尝试自动安装..."
        apt-get update && apt-get install -y jq curl &>/dev/null || {
            error "依赖安装失败，请手动安装 jq 和 curl"
            exit 1
        }
    fi
}

# 检查 Xray 状态
check_xray_status() {
    if [[ ! -f "$XRAY_BINARY_PATH" ]]; then
        xray_status_info="  Xray 状态: ${RED}未安装${NONE}"
        return
    fi
    local xray_version=$("$XRAY_BINARY_PATH" version | head -n 1 | awk '{print $2}')
    local service_status
    systemctl is-active --quiet xray && service_status="${GREEN}运行中${NONE}" || service_status="${YELLOW}未运行${NONE}"
    xray_status_info="  Xray 状态: ${GREEN}已安装${NONE} | ${service_status} | 版本: ${CYAN}${xray_version}${NONE}"
}

# ----------------------- 配置生成函数 -----------------------
# 生成 Shadowsocks 密钥
generate_ss_key() {
    openssl rand -base64 16
}

# 构建 VLESS-Reality 配置
build_vless_inbound() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 shortid="20220701"
    jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg domain "$domain" \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg shortid "$shortid" \
        '{
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": ($domain + ":443"),
                    "xver": 0,
                    "serverNames": [$domain],
                    "privateKey": $private_key,
                    "publicKey": $public_key,
                    "shortIds": [$shortid]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }'
}

# 构建 Shadowsocks 配置
build_ss_inbound() {
    local port=$1 password=$2
    jq -n \
        --argjson port "$port" \
        --arg password "$password" \
        '{
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "shadowsocks",
            "settings": {
                "method": "2022-blake3-aes-128-gcm",
                "password": $password
            }
        }'
}

# 写入 Xray 配置文件
write_config() {
    local inbounds_json=$1
    jq -n \
        --argjson inbounds "$inbounds_json" \
        '{
            "log": {"loglevel": "warning"},
            "inbounds": $inbounds,
            "outbounds": [{
                "protocol": "freedom",
                "settings": {"domainStrategy": "UseIPv4"}
            }]
        }' > "$XRAY_CONFIG_PATH"
}

# ----------------------- 安装相关函数 -----------------------
# 安装 Xray 核心
run_core_install() {
    info "正在下载并安装 Xray 核心..."
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &>/dev/null &
    spinner $!
    if ! wait $!; then
        error "Xray 核心安装失败，请检查网络连接"
        return 1
    fi
    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata &>/dev/null &
    spinner $!
    wait $!
}

# 安装 VLESS-Reality
run_install_vless() {
    local port=$1 uuid=$2 domain=$3
    run_core_install || exit 1
    info "正在生成 Reality 密钥对..."
    local key_pair=$("$XRAY_BINARY_PATH" x25519)
    local private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    local vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    write_config "[$vless_inbound]"
    restart_xray || exit 1
    success "VLESS-Reality 安装成功！"
    view_all_info
}

# 安装 Shadowsocks-2022
run_install_ss() {
    local port=$1 password=$2
    run_core_install || exit 1
    local ss_inbound=$(build_ss_inbound "$port" "$password")
    write_config "[$ss_inbound]"
    restart_xray || exit 1
    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

# 安装双协议
run_install_dual() {
    local vless_port=$1 vless_uuid=$2 vless_domain=$3 ss_port=$4 ss_password=$5
    run_core_install || exit 1
    info "正在生成 Reality 密钥对..."
    local key_pair=$("$XRAY_BINARY_PATH" x25519)
    local private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    local vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    local ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    restart_xray || exit 1
    success "双协议安装成功！"
    view_all_info
}

# ----------------------- 输入验证函数 -----------------------
# 验证端口号
is_valid_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# 验证域名格式
is_valid_domain() {
    local domain=$1
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]
}

# ----------------------- 菜单功能函数 -----------------------
# 主安装菜单
install_menu() {
    local vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    local ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH" 2>/dev/null)

    clear
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "已安装 VLESS-Reality + Shadowsocks-2022 双协议"
        info "如需修改，请使用“修改配置”选项\n如需重装，请先“卸载”后重新“安装”"
        return
    elif [[ -n "$vless_exists" && -z "$ss_exists" ]]; then
        info "检测到已安装 VLESS-Reality"
        echo "---------------------------------------------"
        echo -e "${CYAN}  请选择下一步操作${NONE}"
        echo "---------------------------------------------"
        printf "  ${YELLOW}%-2s${NONE} %-35s\n" "1." "追加安装 Shadowsocks-2022 (组成双协议)"
        printf "  ${RED}%-2s${NONE} %-35s\n" "2." "覆盖重装 VLESS-Reality"
        printf "  ${GREEN}%-2s${NONE} %-35s\n" "0." "返回主菜单"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-2]: " choice
        case $choice in
            1) add_ss_to_vless ;;
            2) install_vless_only ;;
            0) return ;;
            *) error "无效选项" ;;
        esac
    elif [[ -z "$vless_exists" && -n "$ss_exists" ]]; then
        info "检测到已安装 Shadowsocks-2022"
        echo "---------------------------------------------"
        echo -e "${CYAN}  请选择下一步操作${NONE}"
        echo "---------------------------------------------"
        printf "  ${YELLOW}%-2s${NONE} %-35s\n" "1." "追加安装 VLESS-Reality (组成双协议)"
        printf "  ${RED}%-2s${NONE} %-35s\n" "2." "覆盖重装 Shadowsocks-2022"
        printf "  ${GREEN}%-2s${NONE} %-35s\n" "0." "返回主菜单"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-2]: " choice
        case $choice in
            1) add_vless_to_ss ;;
            2) install_ss_only ;;
            0) return ;;
            *) error "无效选项" ;;
        esac
    else
        clean_install_menu
    fi
}

# 全新安装菜单
clean_install_menu() {
    clear
    echo "---------------------------------------------"
    echo -e "${CYAN}  请选择安装类型${NONE}"
    echo "---------------------------------------------"
    printf "  ${GREEN}%-2s${NONE} %-35s\n" "1." "VLESS-Reality"
    printf "  ${CYAN}%-2s${NONE} %-35s\n" "2." "Shadowsocks-2022"
    printf "  ${YELLOW}%-2s${NONE} %-35s\n" "3." "VLESS-Reality + Shadowsocks-2022 (双协议)"
    printf "  ${GREEN}%-2s${NONE} %-35s\n" "0." "返回主菜单"
    echo "---------------------------------------------"
    read -p "请输入选项 [0-3]: " choice
    case $choice in
        1) install_vless_only ;;
        2) install_ss_only ;;
        3) install_dual ;;
        0) return ;;
        *) error "无效选项" ;;
    esac
}

# 追加 Shadowsocks 到 VLESS
add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH")
    local vless_port=$(echo "$vless_inbound" | jq -r '.port')
    local default_ss_port=$([[ "$vless_port" == "443" ]] && echo 8388 || echo $((vless_port + 1)))

    local ss_port
    while true; do
        read -p "请输入 Shadowsocks 端口 (默认: ${CYAN}${default_ss_port}${NONE}): " ss_port
        [[ -z "$ss_port" ]] && ss_port=$default_ss_port && break
        is_valid_port "$ss_port" && break || error "端口无效，请输入 1-65535 之间的数字"
    done
    info "Shadowsocks 端口: ${CYAN}${ss_port}${NONE}"
    read -p "请输入 Shadowsocks 密钥 (留空自动生成): " ss_password
    [[ -z "$ss_password" ]] && ss_password=$(generate_ss_key) && info "已生成随机密钥: ${CYAN}${ss_password}${NONE}"
    local ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    restart_xray || return
    success "追加安装成功！"
    view_all_info
}

# 追加 VLESS 到 Shadowsocks
add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH")
    local ss_port=$(echo "$ss_inbound" | jq -r '.port')
    local default_vless_port=$([[ "$ss_port" == "8388" ]] && echo 443 || echo $((ss_port - 1)))

    local vless_port
    while true; do
        read -p "请输入 VLESS 端口 (默认: ${CYAN}${default_vless_port}${NONE}): " vless_port
        [[ -z "$vless_port" ]] && vless_port=$default_vless_port && break
        is_valid_port "$vless_port" && break || error "端口无效，请输入 1-65535 之间的数字"
    done
    info "VLESS 端口: ${CYAN}${vless_port}${NONE}"
    read -p "请输入 UUID (留空自动生成): " vless_uuid
    [[ -z "$vless_uuid" ]] && vless_uuid=$(cat /proc/sys/kernel/random/uuid) && info "已生成随机 UUID: ${CYAN}${vless_uuid}${NONE}"
    local vless_domain
    while true; do
        read -p "请输入 SNI 域名 (默认: ${CYAN}learn.microsoft.com${NONE}): " vless_domain
        [[ -z "$vless_domain" ]] && vless_domain="learn.microsoft.com" && break
        is_valid_domain "$vless_domain" && break || error "域名格式无效，请重新输入"
    done
    info "正在生成 Reality 密钥对..."
    local key_pair=$("$XRAY_BINARY_PATH" x25519)
    local private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    local vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    write_config "[$vless_inbound, $ss_inbound]"
    restart_xray || return
    success "追加安装成功！"
    view_all_info
}

# 安装 VLESS-Reality
install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain
    while true; do
        read -p "请输入 VLESS 端口 (默认: ${CYAN}443${NONE}): " port
        [[ -z "$port" ]] && port=443 && break
        is_valid_port "$port" && break || error "端口无效，请输入 1-65535 之间的数字"
    done
    read -p "请输入 UUID (留空自动生成): " uuid
    [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid) && info "已生成随机 UUID: ${CYAN}${uuid}${NONE}"
    while true; do
        read -p "请输入 SNI 域名 (默认: ${CYAN}learn.microsoft.com${NONE}): " domain
        [[ -z "$domain" ]] && domain="learn.microsoft.com" && break
        is_valid_domain "$domain" && break || error "域名格式无效，请重新输入"
    done
    run_install_vless "$port" "$uuid" "$domain"
}

# 安装 Shadowsocks-2022
install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password
    while true; do
        read -p "请输入 Shadowsocks 端口 (默认: ${CYAN}8388${NONE}): " port
        [[ -z "$port" ]] && port=8388 && break
        is_valid_port "$port" && break || error "端口无效，请输入 1-65535 之间的数字"
    done
    read -p "请输入 Shadowsocks 密钥 (留空自动生成): " password
    [[ -z "$password" ]] && password=$(generate_ss_key) && info "已生成随机密钥: ${CYAN}${password}${NONE}"
    run_install_ss "$port" "$password"
}

# 安装双协议
install_dual() {
    info "开始配置双协议..."
    local vless_port vless_uuid vless_domain ss_port ss_password
    while true; do
        read -p "请输入 VLESS 端口 (默认: ${CYAN}443${NONE}): " vless_port
        [[ -z "$vless_port" ]] && vless_port=443 && break
        is_valid_port "$vless_port" && break || error "端口无效，请输入 1-65535 之间的数字"
    done
    if [[ "$vless_port" == "443" ]]; then
        while true; do
            read -p "请输入 Shadowsocks 端口 (默认: ${CYAN}8388${NONE}): " ss_port
            [[ -z "$ss_port" ]] && ss_port=8388 && break
            is_valid_port "$ss_port" && break || error "端口无效，请输入 1-65535 之间的数字"
        done
    else
        ss_port=$((vless_port + 1))
        info "VLESS 端口: ${CYAN}${vless_port}${NONE}"
        info "Shadowsocks 端口: ${CYAN}${ss_port}${NONE}"
    fi
    read -p "请输入 UUID (留空自动生成): " vless_uuid
    [[ -z "$vless_uuid" ]] && vless_uuid=$(cat /proc/sys/kernel/random/uuid) && info "已生成随机 UUID: ${CYAN}${vless_uuid}${NONE}"
    while true; do
        read -p "请输入 SNI 域名 (默认: ${CYAN}learn.microsoft.com${NONE}): " vless_domain
        [[ -z "$vless_domain" ]] && vless_domain="learn.microsoft.com" && break
        is_valid_domain "$vless_domain" && break || error "域名格式无效，请重新输入"
    done
    read -p "请输入 Shadowsocks 密钥 (留空自动生成): " ss_password
    [[ -z "$ss_password" ]] && ss_password=$(generate_ss_key) && info "已生成随机密钥: ${CYAN}${ss_password}${NONE}"
    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
}

# ----------------------- 管理功能函数 -----------------------
# 更新 Xray
update_xray() {
    [[ ! -f "$XRAY_BINARY_PATH" ]] && error "错误: Xray 未安装" && return
    info "正在检查最新版本..."
    local current_version=$("$XRAY_BINARY_PATH" version | head -n 1 | awk '{print $2}')
    local latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//')
    [[ -z "$latest_version" ]] && error "获取最新版本号失败" && return
    info "当前版本: ${CYAN}${current_version}${NONE}，最新版本: ${CYAN}${latest_version}${NONE}"
    [[ "$current_version" == "$latest_version" ]] && success "Xray 已是最新版本" && return
    info "发现新版本，开始更新..."
    run_core_install && restart_xray && success "Xray 更新成功！"
}

# 卸载 Xray
uninstall_xray() {
    [[ ! -f "$XRAY_BINARY_PATH" ]] && error "错误: Xray 未安装" && return
    read -p "确定要卸载 Xray 吗？[Y/n]: " confirm
    [[ $confirm =~ ^[nN]$ ]] && info "操作已取消" && return
    info "正在卸载 Xray..."
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge &>/dev/null &
    spinner $!
    wait $!
    rm -f ~/xray_subscription_info.txt
    success "Xray 已成功卸载"
}

# 修改配置菜单
modify_config_menu() {
    [[ ! -f "$XRAY_CONFIG_PATH" ]] && error "错误: Xray 未安装" && return
    local vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH")
    local ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH")
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        clear
        echo "---------------------------------------------"
        echo -e "${CYAN}  请选择要修改的配置${NONE}"
        echo "---------------------------------------------"
        printf "  ${GREEN}%-2s${NONE} %-35s\n" "1." "VLESS-Reality"
        printf "  ${CYAN}%-2s${NONE} %-35s\n" "2." "Shadowsocks-2022"
        printf "  ${GREEN}%-2s${NONE} %-35s\n" "0." "返回主菜单"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-2]: " choice
        case $choice in
            1) modify_vless_config ;;
            2) modify_ss_config ;;
            0) return ;;
            *) error "无效选项" ;;
        esac
    elif [[ -n "$vless_exists" ]]; then
        modify_vless_config
    elif [[ -n "$ss_exists" ]]; then
        modify_ss_config
    else
        error "未找到可修改的协议配置"
    fi
}

# 修改 VLESS 配置
modify_vless_config() {
    info "开始修改 VLESS-Reality 配置..."
    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH")
    local current_port=$(echo "$vless_inbound" | jq -r '.port')
    local current_uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
    local current_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    local private_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.privateKey')
    local public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')

    local port
    while true; do
        read -p "端口 (当前: ${CYAN}${current_port}${NONE}, 留空不修改): " port
        [[ -z "$port" ]] && port=$current_port && info "端口未修改" && break
        is_valid_port "$port" && break || error "端口无效，请输入 1-65535 之间的数字"
    done
    read -p "UUID (当前: ${CYAN}${current_uuid}${NONE}, 留空不修改): " uuid
    [[ -z "$uuid" ]] && uuid=$current_uuid && info "UUID 未修改"
    local domain
    while true; do
        read -p "SNI 域名 (当前: ${CYAN}${current_domain}${NONE}, 留空不修改): " domain
        [[ -z "$domain" ]] && domain=$current_domain && info "SNI 域名未修改" && break
        is_valid_domain "$domain" && break || error "域名格式无效，请重新输入"
    done
    local new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH")
    local new_inbounds="[${new_vless_inbound}]"
    [[ -n "$ss_inbound" ]] && new_inbounds="[${new_vless_inbound}, ${ss_inbound}]"
    write_config "$new_inbounds"
    restart_xray || return
    success "配置修改成功！"
    view_all_info
}

# 修改 Shadowsocks 配置
modify_ss_config() {
    info "开始修改 Shadowsocks-2022 配置..."
    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH")
    local current_port=$(echo "$ss_inbound" | jq -r '.port')
    local current_password=$(echo "$ss_inbound" | jq -r '.settings.password')

    local port
    while true; do
        read -p "端口 (当前: ${CYAN}${current_port}${NONE}, 留空不修改): " port
        [[ -z "$port" ]] && port=$current_port && info "端口未修改" && break
        is_valid_port "$port" && break || error "端口无效，请输入 1-65535 之间的数字"
    done
    read -p "密钥 (留空保留当前): " password_input
    local new_password=$([[ -z "$password_input" ]] && echo "$current_password" || echo "$password_input")
    [[ -z "$password_input" ]] && info "密钥未修改" || info "密钥已更新"
    local new_ss_inbound=$(build_ss_inbound "$port" "$new_password")
    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH")
    local new_inbounds="[${new_ss_inbound}]"
    [[ -n "$vless_inbound" ]] && new_inbounds="[${vless_inbound}, ${new_ss_inbound}]"
    write_config "$new_inbounds"
    restart_xray || return
    success "配置修改成功！"
    view_all_info
}

# 重启 Xray 服务
restart_xray() {
    [[ ! -f "$XRAY_BINARY_PATH" ]] && error "错误: Xray 未安装" && return 1
    info "正在重启 Xray 服务..."
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray && success "Xray 服务已成功重启！" && return 0
    error "服务启动失败，请查看日志"
    return 1
}

# 查看 Xray 日志
view_xray_log() {
    [[ ! -f "$XRAY_BINARY_PATH" ]] && error "错误: Xray 未安装" && return
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出"
    journalctl -u xray -f --no-pager
}

# 查看订阅信息
view_all_info() {
    [[ ! -f "$XRAY_CONFIG_PATH" ]] && error "错误: 配置文件不存在" && return
    info "正在从配置文件生成订阅信息..."
    local ip=$(curl -4s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$' || curl -6s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$')
    local host=$(hostname)
    local links_array=()

    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH")
    if [[ -n "$vless_inbound" ]]; then
        local uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
        local port=$(echo "$vless_inbound" | jq -r '.port')
        local domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        local public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        local shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        [[ -z "$public_key" ]] && error "VLESS 配置不完整，请重新安装" && return
        local display_ip=$([[ $ip =~ ":" ]] && echo "[$ip]" || echo "$ip")
        local link_name_raw="$host X-reality"
        local link_name_encoded=$(echo "$link_name_raw" | sed 's/ /%20/g')
        local vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
        links_array+=("$vless_url")
        echo "----------------------------------------------------------------"
        echo -e "${GREEN} --- VLESS-Reality 订阅信息 --- ${NONE}"
        echo -e "${YELLOW} 名称: ${CYAN}${link_name_raw}${NONE}"
        echo -e "${YELLOW} 地址: ${CYAN}${ip}${NONE}"
        echo -e "${YELLOW} 端口: ${CYAN}${port}${NONE}"
        echo -e "${YELLOW} UUID: ${CYAN}${uuid}${NONE}"
        echo -e "${YELLOW} 流控: ${CYAN}xtls-rprx-vision${NONE}"
        echo -e "${YELLOW} 指纹: ${CYAN}chrome${NONE}"
        echo -e "${YELLOW} SNI: ${CYAN}${domain}${NONE}"
        echo -e "${YELLOW} 公钥: ${CYAN}${public_key}${NONE}"
        echo -e "${YELLOW} ShortId: ${CYAN}${shortid}${NONE}"
    fi

    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH")
    if [[ -n "$ss_inbound" ]]; then
        local port=$(echo "$ss_inbound" | jq -r '.port')
        local method=$(echo "$ss_inbound" | jq -r '.settings.method')
        local password=$(echo "$ss_inbound" | jq -r '.settings.password')
        local link_name_raw="$host X-ss2022"
        local user_info_raw="$method:$password"
        local user_info_base64=$(echo -n "$user_info_raw" | base64 -w 0)
        local ss_url="ss://${user_info_base64}@${ip}:${port}#${link_name_raw}"
        links_array+=("$ss_url")
        echo "----------------------------------------------------------------"
        echo -e "${GREEN} --- Shadowsocks-2022 订阅信息 --- ${NONE}"
        echo -e "${YELLOW} 名称: ${CYAN}${link_name_raw}${NONE}"
        echo -e "${YELLOW} 地址: ${CYAN}${ip}${NONE}"
        echo -e "${YELLOW} 端口: ${CYAN}${port}${NONE}"
        echo -e "${YELLOW} 加密: ${CYAN}${method}${NONE}"
        echo -e "${YELLOW} 密钥: ${CYAN}${password}${NONE}"
    fi

    if [[ ${#links_array[@]} -gt 0 ]]; then
        printf "%s\n" "${links_array[@]}" > ~/xray_subscription_info.txt
        echo "----------------------------------------------------------------"
        echo -e "${GREEN} 所有链接已保存到 ~/xray_subscription_info.txt ${NONE}"
        echo -e "\n${CYAN}--- 汇总订阅链接 ---${NONE}\n"
        local first=true
        for link in "${links_array[@]}"; do
            [[ "$first" = true ]] && first=false || echo
            echo -e "${CYAN}${link}${NONE}"
        done
        echo "----------------------------------------------------------------"
    fi
}

# ----------------------- 主菜单 -----------------------
main_menu() {
    while true; do
        clear
        echo -e "${CYAN} Xray 多功能管理脚本${NONE}"
        echo "---------------------------------------------"
        check_xray_status
        echo -e "${xray_status_info}"
        echo "---------------------------------------------"
        printf "  ${GREEN}%-2s${NONE} %-35s\n" "1." "安装 Xray"
        printf "  ${CYAN}%-2s${NONE} %-35s\n" "2." "更新 Xray"
        printf "  ${RED}%-2s${NONE} %-35s\n" "3." "卸载 Xray"
        printf "  ${CYAN}%-2s${NONE} %-35s\n" "4." "重启 Xray"
        printf "  ${YELLOW}%-2s${NONE} %-35s\n" "5." "修改配置"
        printf "  ${MAGENTA}%-2s${NONE} %-35s\n" "6." "查看 Xray 日志"
        printf "  ${CYAN}%-2s${NONE} %-35s\n" "7." "查看订阅信息"
        printf "  ${GREEN}%-2s${NONE} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-7]: " choice
        if ! [[ "$choice" =~ ^[0-7]$ ]]; then
            error "无效选项，请选择 0-7 之间的数字"
            read -p "按 Enter 键继续..."
            continue
        fi
        case $choice in
            1) install_menu ;;
            2) update_xray ;;
            3) uninstall_xray ;;
            4) restart_xray ;;
            5) modify_config_menu ;;
            6) view_xray_log ;;
            7) view_all_info ;;
            0) success "感谢使用！" && exit 0 ;;
            *) error "无效选项" ;;
        esac
        read -p "按 Enter 键返回主菜单..."
    done
}

# ----------------------- 非交互式调度 -----------------------
non_interactive_dispatcher() {
    is_numeric() { [[ "$1" =~ ^[0-9]+$ ]]; }
    if is_valid_port "$1" && [[ -n "$2" ]] && is_valid_domain "$3"; then
        run_install_vless "$1" "$2" "$3"
        exit 0
    fi
    local mode=$1
    shift
    case "$mode" in
        vless)
            is_valid_port "$1" && is_valid_domain "$3" || { error "参数无效，请检查端口或域名格式" && exit 1; }
            run_install_vless "$@"
            ;;
        ss)
            is_valid_port "$1" || { error "端口参数无效" && exit 1; }
            run_install_ss "$@"
            ;;
        dual)
            local vless_port=$1 vless_uuid=$2 vless_domain=$3 ss_password=$4 ss_port
            is_valid_port "$vless_port" && is_valid_domain "$vless_domain" || { error "参数无效，请检查 VLESS 端口或域名格式" && exit 1; }
            [[ "$vless_port" == "443" ]] && ss_port=8388 || ss_port=$((vless_port + 1))
            [[ -z "$ss_password" ]] && ss_password=$(generate_ss_key)
            run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
            ;;
        *) main_menu ;;
    esac
}

# ----------------------- 脚本入口 -----------------------
pre_check
non_interactive_dispatcher "$@"
