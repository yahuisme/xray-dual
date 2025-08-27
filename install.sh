#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality & Shadowsocks-2022 多功能管理脚本
# 版本: Final
# 描述: 简化 Xray VLESS-Reality 和 Shadowsocks-2022 协议的安装、配置和管理。
# ==============================================================================

# ------------------------------------------------------------------------------
# 全局常量 & 变量定义
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="Final"
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY_PATH="/usr/local/bin/xray"

# 颜色定义
readonly red='\e[91m'
readonly green='\e[92m'
readonly yellow='\e[93m'
readonly magenta='\e[95m'
readonly cyan='\e[96m'
readonly none='\e[0m'

# 全局变量
xray_status_info=""

# ------------------------------------------------------------------------------
# 辅助函数
# ------------------------------------------------------------------------------

# 错误信息输出
error() {
    printf "\n%b错误: %s%b\n\n" "$red" "$1" "$none"
}

# 提示信息输出
info() {
    printf "\n%b%s%b\n\n" "$yellow" "$1" "$none"
}

# 成功信息输出
success() {
    printf "\n%b%s%b\n\n" "$green" "$1" "$none"
}

# 进程等待动画
spinner() {
    local pid=$1
    local spinstr='|/-\'
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "${spinstr}"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

# 预检环境，检查root权限和依赖
pre_check() {
    if [[ $(id -u) -ne 0 ]]; then
        error "您必须以root用户身份运行此脚本"
        exit 1
    fi
    
    if [ ! -f /etc/debian_version ]; then
        error "此脚本仅支持 Debian/Ubuntu 及其衍生系统。"
        exit 1
    fi
    
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (apt-get update && apt-get install -y jq curl) &> /dev/null
    fi
}

# 检查 Xray 服务的状态
check_xray_status() {
    if [[ ! -f "$XRAY_BINARY_PATH" ]]; then
        xray_status_info="  Xray 状态: ${red}未安装${none}"
        return
    fi
    
    local xray_version=$("$XRAY_BINARY_PATH" version | head -n 1 | awk '{print $2}')
    local service_status
    
    if systemctl is-active --quiet xray; then
        service_status="${green}运行中${none}"
    else
        service_status="${yellow}未运行${none}"
    fi
    
    xray_status_info="  Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

# 验证端口号是否有效
is_valid_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 验证域名格式是否有效
is_valid_domain() {
    local domain=$1
    # 简单的域名正则验证
    if [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 核心安装与配置函数
# ------------------------------------------------------------------------------

# 生成 Shadowsocks-2022 密钥
generate_ss_key() {
    openssl rand -base64 16
}

# 构建 VLESS 入站配置 JSON
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

# 构建 Shadowsocks-2022 入站配置 JSON
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

# 写入配置文件
write_config() {
    local inbounds_json=$1
    jq -n \
        --argjson inbounds "$inbounds_json" \
    '{
        "log": {"loglevel": "warning"},
        "inbounds": $inbounds,
        "outbounds": [
            {
                "protocol": "freedom",
                "settings": {
                    "domainStrategy": "UseIPv4"
                }
            }
        ]
    }' > "$XRAY_CONFIG_PATH"
}

# 下载并安装 Xray 核心和 Geo 数据
run_core_install() {
    info "正在下载并安装 Xray 核心..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &> /dev/null &
    spinner $!; if ! wait $!; then
        error "Xray 核心安装失败！请检查网络连接。"
        return 1
    fi
    info "正在更新 GeoIP 和 GeoSite 数据文件...";
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata &> /dev/null &
    spinner $!
    wait $!
}

# 重启 Xray 服务
restart_xray() {
    if [[ ! -f "$XRAY_BINARY_PATH" ]]; then
        error "错误: Xray 未安装。"
        return 1
    fi
    info "正在重启 Xray 服务..."
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
        return 0
    else
        error "服务启动失败, 请查看日志。"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 主菜单功能函数
# ------------------------------------------------------------------------------

# 安装菜单
install_menu() {
    local vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    local ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    
    clear
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "您已安装 VLESS-Reality + Shadowsocks-2022 双协议。"
        info "如需修改，请使用主菜单的“修改配置”选项。\n如需重装，请先“卸载”后，再重新“安装”。"
        return
    elif [[ -n "$vless_exists" ]]; then
        info "检测到您已安装 VLESS-Reality"
        printf "---------------------------------------------\n"
        printf "%b  请选择下一步操作%b\n" "$cyan" "$none"
        printf "---------------------------------------------\n"
        printf "  %b%-2s%b %-35s\n" "$yellow" "1." "$none" "追加安装 Shadowsocks-2022 (组成双协议)"
        printf "  %b%-2s%b %-35s\n" "$red" "2." "$none" "覆盖重装 VLESS-Reality"
        printf "---------------------------------------------\n"
        printf "  %b%-2s%b %-35s\n" "$green" "0." "$none" "返回主菜单"
        printf "---------------------------------------------\n"
        read -p "请输入选项 [0-2]: " choice
        case $choice in
            1) add_ss_to_vless ;;
            2) install_vless_only ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
    elif [[ -n "$ss_exists" ]]; then
        info "检测到您已安装 Shadowsocks-2022"
        printf "---------------------------------------------\n"
        printf "%b  请选择下一步操作%b\n" "$cyan" "$none"
        printf "---------------------------------------------\n"
        printf "  %b%-2s%b %-35s\n" "$yellow" "1." "$none" "追加安装 VLESS-Reality (组成双协议)"
        printf "  %b%-2s%b %-35s\n" "$red" "2." "$none" "覆盖重装 Shadowsocks-2022"
        printf "---------------------------------------------\n"
        printf "  %b%-2s%b %-35s\n" "$green" "0." "$none" "返回主菜单"
        printf "---------------------------------------------\n"
        read -p "请输入选项 [0-2]: " choice
        case $choice in
            1) add_vless_to_ss ;;
            2) install_ss_only ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
    else  
        clean_install_menu
    fi
}

# 纯净安装菜单
clean_install_menu() {
    clear
    printf "---------------------------------------------\n"
    printf "%b  请选择安装类型%b\n" "$cyan" "$none"
    printf "---------------------------------------------\n"
    printf "  %b%-2s%b %-35s\n" "$green" "1." "$none" "VLESS-Reality"
    printf "  %b%-2s%b %-35s\n" "$cyan" "2." "$none" "Shadowsocks-2022"
    printf "  %b%-2s%b %-35s\n" "$yellow" "3." "$none" "VLESS-Reality + Shadowsocks-2022 (双协议)"
    printf "---------------------------------------------\n"
    printf "  %b%-2s%b %-35s\n" "$green" "0." "$none" "返回主菜单"
    printf "---------------------------------------------\n"
    read -p "请输入选项 [0-3]: " choice
    case $choice in
        1) install_vless_only ;;
        2) install_ss_only ;;
        3) install_dual ;;
        0) return ;;
        *) error "无效选项。" ;;
    esac
}

# 追加 Shadowsocks-2022 到现有配置
add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH")
    local vless_port=$(echo "$vless_inbound" | jq -r '.port')
    local default_ss_port=$((vless_port == "443" ? 8388 : vless_port + 1))
    
    local ss_port
    while true; do
        read -p "$(printf "请输入 Shadowsocks 端口 (默认: %b%s%b): " "$cyan" "$default_ss_port" "$none")" ss_port
        if [[ -z "$ss_port" ]]; then
            ss_port=$default_ss_port
            break
        fi
        if is_valid_port "$ss_port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done
    
    info "Shadowsocks 端口将使用: ${cyan}${ss_port}${none}"
    
    local ss_password
    read -p "$(printf "请输入 Shadowsocks 密钥 (留空将自动生成): ")" ss_password
    if [[ -z "$ss_password" ]]; then
        ss_password=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${ss_password}${none}"
    fi
    
    local ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    if restart_xray; then
        success "追加安装成功！"
        view_all_info
    fi
}

# 追加 VLESS-Reality 到现有配置
add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH")
    local ss_port=$(echo "$ss_inbound" | jq -r '.port')
    local default_vless_port=$((ss_port == "8388" ? 443 : ss_port - 1))
    
    local vless_port
    while true; do
        read -p "$(printf "请输入 VLESS 端口 (默认: %b%s%b): " "$cyan" "$default_vless_port" "$none")" vless_port
        if [[ -z "$vless_port" ]]; then
            vless_port=$default_vless_port
            break
        fi
        if is_valid_port "$vless_port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done
    
    info "VLESS 端口将使用: ${cyan}${vless_port}${none}"
    
    local vless_uuid
    read -p "$(printf "请输入UUID (留空将默认生成随机UUID): ")" vless_uuid
    if [[ -z "$vless_uuid" ]]; then
        vless_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${vless_uuid}${none}"
    fi
    
    local vless_domain
    while true; do
        read -p "$(printf "请输入SNI域名 (默认: %blearn.microsoft.com%b): " "$cyan" "$none")" vless_domain
        if [[ -z "$vless_domain" ]]; then
            vless_domain="learn.microsoft.com"
            break
        fi
        if is_valid_domain "$vless_domain"; then
            break
        else
            error "域名格式无效，请重新输入。"
        fi
    done
    
    info "正在生成 Reality 密钥对..."
    local key_pair=$("$XRAY_BINARY_PATH" x25519)
    local private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    
    local vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    write_config "[$vless_inbound, $ss_inbound]"
    if restart_xray; then
        success "追加安装成功！"
        view_all_info
    fi
}

# 仅安装 VLESS-Reality
install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain
    
    while true; do
        read -p "$(printf "请输入 VLESS 端口 (默认: %b443%b): " "$cyan" "$none")" port
        if [[ -z "$port" ]]; then
            port=443
            break
        fi
        if is_valid_port "$port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done
    
    read -p "$(printf "请输入UUID (留空将默认生成随机UUID): ")" uuid
    if [[ -z "$uuid" ]]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${uuid}${none}"
    fi
    
    while true; do
        read -p "$(printf "请输入SNI域名 (默认: %blearn.microsoft.com%b): " "$cyan" "$none")" domain
        if [[ -z "$domain" ]]; then
            domain="learn.microsoft.com"
            break
        fi
        if is_valid_domain "$domain"; then
            break
        else
            error "域名格式无效，请重新输入。"
        fi
    done
    
    run_install_vless "$port" "$uuid" "$domain"
}

# 仅安装 Shadowsocks-2022
install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password
    
    while true; do
        read -p "$(printf "请输入 Shadowsocks 端口 (默认: %b8388%b): " "$cyan" "$none")" port
        if [[ -z "$port" ]]; then
            port=8388
            break
        fi
        if is_valid_port "$port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done
    
    read -p "$(printf "请输入 Shadowsocks 密钥 (留空将自动生成): ")" password
    if [[ -z "$password" ]]; then
        password=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${password}${none}"
    fi
    
    run_install_ss "$port" "$password"
}

# 安装双协议
install_dual() {
    info "开始配置双协议..."
    local vless_port vless_uuid vless_domain ss_port ss_password
    
    while true; do
        read -p "$(printf "请输入 VLESS 端口 (留空使用默认: %b443%b): " "$cyan" "$none")" vless_port
        if [[ -z "$vless_port" ]]; then
            vless_port=443
            break
        fi
        if is_valid_port "$vless_port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done
    
    if [[ "$vless_port" == "443" ]]; then
        while true; do
            read -p "$(printf "请输入 Shadowsocks 端口 (留空使用默认: %b8388%b): " "$cyan" "$none")" ss_port
            if [[ -z "$ss_port" ]]; then
                ss_port=8388
                break
            fi
            if is_valid_port "$ss_port"; then
                break
            else
                error "端口无效，请输入一个1-65535之间的数字。"
            fi
        done
    else
        ss_port=$((vless_port + 1))
        info "VLESS 端口设置为: ${cyan}${vless_port}${none}"
        info "Shadowsocks 端口将自动设置为相邻的: ${cyan}${ss_port}${none}"
    fi
    
    read -p "$(printf "请输入UUID (留空将默认生成随机UUID): ")" vless_uuid
    if [[ -z "$vless_uuid" ]]; then
        vless_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${vless_uuid}${none}"
    fi
    
    while true; do
        read -p "$(printf "请输入SNI域名 (默认: %blearn.microsoft.com%b): " "$cyan" "$none")" vless_domain
        if [[ -z "$vless_domain" ]]; then
            vless_domain="learn.microsoft.com"
            break
        fi
        if is_valid_domain "$vless_domain"; then
            break
        else
            error "域名格式无效，请重新输入。"
        fi
    done
    
    read -p "$(printf "请输入 Shadowsocks 密钥 (留空将自动生成): ")" ss_password
    if [[ -z "$ss_password" ]]; then
        ss_password=$(generate_ss_key)
        info "已为您生成 Shadowsocks 随机密钥: ${cyan}${ss_password}${none}"
    fi
    
    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
}

# 更新 Xray 核心
update_xray() {
    if [[ ! -f "$XRAY_BINARY_PATH" ]]; then
        error "错误: Xray 未安装。"
        return
    fi
    
    info "正在检查最新版本..."
    local current_version=$("$XRAY_BINARY_PATH" version | head -n 1 | awk '{print $2}')
    local latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//')
    
    if [[ -z "$latest_version" ]]; then
        error "获取最新版本号失败。"
        return
    fi
    
    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"
    
    if [[ "$current_version" == "$latest_version" ]]; then
        success "您的 Xray 已是最新版本。"
        return
    fi
    
    info "发现新版本，开始更新..."
    if run_core_install; then
        restart_xray && success "Xray 更新成功！"
    fi
}

# 卸载 Xray
uninstall_xray() {
    if [[ ! -f "$XRAY_BINARY_PATH" ]]; then
        error "错误: Xray 未安装。"
        return
    fi
    
    read -p "您确定要卸载 Xray 吗？[Y/n]: " confirm
    if [[ $confirm =~ ^[nN]$ ]]; then
        info "操作已取消。"
        return
    fi
    
    info "正在卸载 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge &> /dev/null &
    spinner $!
    wait $!
    rm -f ~/xray_subscription_info.txt
    success "Xray 已成功卸载。"
}

# 修改配置菜单
modify_config_menu() {
    if [[ ! -f "$XRAY_CONFIG_PATH" ]]; then
        error "错误: Xray 未安装。"
        return
    fi
    
    local vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    local ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        clear
        printf "---------------------------------------------\n"
        printf "%b  请选择要修改的配置%b\n" "$cyan" "$none"
        printf "---------------------------------------------\n"
        printf "  %b%-2s%b %-35s\n" "$green" "1." "$none" "VLESS-Reality"
        printf "  %b%-2s%b %-35s\n" "$cyan" "2." "$none" "Shadowsocks-2022"
        printf "---------------------------------------------\n"
        printf "  %b%-2s%b %-35s\n" "$green" "0." "$none" "返回主菜单"
        printf "---------------------------------------------\n"
        
        read -p "请输入选项 [0-2]: " choice
        case $choice in
            1) modify_vless_config ;;
            2) modify_ss_config ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
    elif [[ -n "$vless_exists" ]]; then
        modify_vless_config
    elif [[ -n "$ss_exists" ]]; then
        modify_ss_config
    else
        error "未找到可修改的协议配置。"
    fi
}

# 修改 VLESS-Reality 配置
modify_vless_config() {
    info "开始修改 VLESS-Reality 配置..."
    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH")
    local current_port=$(echo "$vless_inbound" | jq -r '.port')
    local current_uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
    local current_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    local private_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.privateKey')
    local public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
    
    local port uuid domain
    
    while true; do
        read -p "$(printf "端口 (当前: %b%s%b, 留空则不修改): " "$cyan" "$current_port" "$none")" port
        if [[ -z "$port" ]]; then
            port=$current_port
            info "端口未修改。"
            break
        fi
        if is_valid_port "$port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done
    
    read -p "$(printf "UUID (当前: %b%s%b, 留空则不修改): " "$cyan" "$current_uuid" "$none")" uuid
    if [[ -z "$uuid" ]]; then
        uuid=$current_uuid
        info "UUID 未修改。"
    fi
    
    while true; do
        read -p "$(printf "SNI域名 (当前: %b%s%b, 留空则不修改): " "$cyan" "$current_domain" "$none")" domain
        if [[ -z "$domain" ]]; then
            domain=$current_domain
            info "SNI域名未修改。"
            break
        fi
        if is_valid_domain "$domain"; then
            break
        else
            error "域名格式无效，请重新输入。"
        fi
    done
    
    local new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    local new_inbounds="[${new_vless_inbound}]"
    
    if [[ -n "$ss_inbound" ]]; then
        new_inbounds="[${new_vless_inbound}, ${ss_inbound}]"
    fi
    
    write_config "$new_inbounds"
    if restart_xray; then
        success "配置修改成功！"
        view_all_info
    fi
}

# 修改 Shadowsocks-2022 配置
modify_ss_config() {
    info "开始修改 Shadowsocks-2022 配置..."
    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH")
    local current_port=$(echo "$ss_inbound" | jq -r '.port')
    local current_password=$(echo "$ss_inbound" | jq -r '.settings.password')
    
    local port
    while true; do
        read -p "$(printf "端口 (当前: %b%s%b, 留空则不修改): " "$cyan" "$current_port" "$none")" port
        if [[ -z "$port" ]]; then
            port=$current_port
            info "端口未修改。"
            break
        fi
        if is_valid_port "$port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done
    
    read -p "$(printf "密钥 (留空保留当前密码): ")" password_input
    local new_password
    if [[ -z "$password_input" ]]; then
        new_password=$current_password
        info "密钥未修改。"
    else
        new_password=$password_input
        info "密钥已更新。"
    fi
    
    local new_ss_inbound=$(build_ss_inbound "$port" "$new_password")
    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    local new_inbounds="[${new_ss_inbound}]"
    
    if [[ -n "$vless_inbound" ]]; then
        new_inbounds="[${vless_inbound}, ${new_ss_inbound}]"
    fi
    
    write_config "$new_inbounds"
    if restart_xray; then
        success "配置修改成功！"
        view_all_info
    fi
}

# 查看 Xray 实时日志
view_xray_log() {
    if [[ ! -f "$XRAY_BINARY_PATH" ]]; then
        error "错误: Xray 未安装。"
        return
    fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

# 查看并生成所有订阅信息
view_all_info() {
    if [ ! -f "$XRAY_CONFIG_PATH" ]; then
        error "错误: 配置文件不存在。"
        return
    fi
    
    info "正在从配置文件生成订阅信息..."
    local ip=$(curl -4s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$' || curl -6s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$')
    local host=$(hostname)
    local links_array=()
    
    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    if [[ -n "$vless_inbound" ]]; then
        local uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
        local port=$(echo "$vless_inbound" | jq -r '.port')
        local domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        local public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        local shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        
        if [[ -z "$public_key" ]]; then
            error "VLESS配置不完整，请重新安装。"
            return
        fi
        
        local display_ip=$ip
        if [[ "$ip" =~ ":" ]]; then
            display_ip="[$ip]"
        fi
        
        local link_name_raw="$host X-reality"
        local link_name_encoded=$(echo "$link_name_raw" | sed 's/ /%20/g')
        local vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
        links_array+=("$vless_url")
        
        printf "----------------------------------------------------------------\n"
        printf "%b --- VLESS-Reality 订阅信息 --- %b\n" "$green" "$none"
        printf "%b 名称:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$link_name_raw" "$none"
        printf "%b 地址:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$ip" "$none"
        printf "%b 端口:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$port" "$none"
        printf "%b UUID:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$uuid" "$none"
        printf "%b 流控:%b %b%s%b\n" "$yellow" "$none" "$cyan" "xtls-rprx-vision" "$none"
        printf "%b 指纹:%b %b%s%b\n" "$yellow" "$none" "$cyan" "chrome" "$none"
        printf "%b SNI:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$domain" "$none"
        printf "%b 公钥:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$public_key" "$none"
        printf "%b ShortId:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$shortid" "$none"
    fi
    
    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$XRAY_CONFIG_PATH" 2>/dev/null)
    if [[ -n "$ss_inbound" ]]; then
        local port=$(echo "$ss_inbound" | jq -r '.port')
        local method=$(echo "$ss_inbound" | jq -r '.settings.method')
        local password=$(echo "$ss_inbound" | jq -r '.settings.password')
        
        local link_name_raw="$host X-ss2022"
        local user_info_raw="$method:$password"
        local user_info_base64=$(echo -n "$user_info_raw" | base64 -w 0)
        local ss_url="ss://${user_info_base64}@$ip:$port#${link_name_raw}"
        links_array+=("$ss_url")
        
        printf "----------------------------------------------------------------\n"
        printf "%b --- Shadowsocks-2022 订阅信息 --- %b\n" "$green" "$none"
        printf "%b 名称:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$link_name_raw" "$none"
        printf "%b 地址:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$ip" "$none"
        printf "%b 端口:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$port" "$none"
        printf "%b 加密:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$method" "$none"
        printf "%b 密钥:%b %b%s%b\n" "$yellow" "$none" "$cyan" "$password" "$none"
    fi
    
    if [ ${#links_array[@]} -gt 0 ]; then
        printf "%s\n" "${links_array[@]}" > ~/xray_subscription_info.txt
        printf "----------------------------------------------------------------\n"
        printf "%b 所有链接已汇总保存到 ~/xray_subscription_info.txt %b\n" "$green" "$none"
        printf "\n%b--- 汇总订阅链接 (方便一次性复制) ---%b\n" "$cyan" "$none"
        
        local first=true
        for link in "${links_array[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                echo
            fi
            printf "%b%s%b\n" "$cyan" "$link" "$none"
        done
        printf "----------------------------------------------------------------\n"
    fi
}

# ------------------------------------------------------------------------------
# 核心逻辑安装函数
# ------------------------------------------------------------------------------

# 执行 VLESS-Reality 安装
run_install_vless() {
    local port=$1 uuid=$2 domain=$3
    run_core_install || exit 1
    
    info "正在生成 Reality 密钥对..."
    local key_pair=$("$XRAY_BINARY_PATH" x25519)
    local private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    
    local vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    write_config "[$vless_inbound]"
    if restart_xray; then
        success "VLESS-Reality 安装成功！"
        view_all_info
    fi
}

# 执行 Shadowsocks-2022 安装
run_install_ss() {
    local port=$1 password=$2
    run_core_install || exit 1
    
    local ss_inbound=$(build_ss_inbound "$port" "$password")
    write_config "[$ss_inbound]"
    if restart_xray; then
        success "Shadowsocks-2022 安装成功！"
        view_all_info
    fi
}

# 执行双协议安装
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
    if restart_xray; then
        success "双协议安装成功！"
        view_all_info
    fi
}

# ------------------------------------------------------------------------------
# 主菜单与非交互式模式分发
# ------------------------------------------------------------------------------

# 主菜单入口
main_menu() {
    while true; do
        clear
        printf "%b Xray 多功能管理脚本%b\n" "$cyan" "$none"
        printf "---------------------------------------------\n"
        check_xray_status
        printf "%b\n" "$xray_status_info"
        printf "---------------------------------------------\n"
        printf "  %b%-2s%b %-35s\n" "$green" "1." "$none" "安装 Xray"
        printf "  %b%-2s%b %-35s\n" "$cyan" "2." "$none" "更新 Xray"
        printf "  %b%-2s%b %-35s\n" "$red" "3." "$none" "卸载 Xray"
        printf "  %b%-2s%b %-35s\n" "$cyan" "4." "$none" "重启 Xray"
        printf "  %b%-2s%b %-35s\n" "$yellow" "5." "$none" "修改配置"
        printf "  %b%-2s%b %-35s\n" "$magenta" "6." "$none" "查看 Xray 日志"
        printf "  %b%-2s%b %-35s\n" "$cyan" "7." "$none" "查看订阅信息"
        printf "---------------------------------------------\n"
        printf "  %b%-2s%b %-35s\n" "$green" "0." "$none" "退出脚本"
        printf "---------------------------------------------\n"
        
        read -p "请输入选项 [0-7]: " choice
        
        if ! [[ "$choice" =~ ^[0-7]$ ]]; then
            error "无效选项。请选择0到7之间的数字。"
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
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项。" ;;
        esac
        
        read -p "按 Enter 键返回主菜单..."
    done
}

# 非交互式模式处理
non_interactive_dispatcher() {
    local mode=$1
    shift
    
    case "$mode" in
        vless)
            if ! is_valid_port "$1" || ! is_valid_domain "$3"; then
                error "参数无效。请检查端口或域名格式。"
                exit 1
            fi
            run_install_vless "$@"
            ;;
        ss)
            if ! is_valid_port "$1"; then
                error "端口参数无效。"
                exit 1
            fi
            run_install_ss "$@"
            ;;
        dual)
            local vless_port=$1
            local vless_uuid=$2
            local vless_domain=$3
            local ss_password=$4
            local ss_port
            
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$vless_domain"; then
                error "参数无效。请检查VLESS端口或域名格式。"
                exit 1
            fi
            
            if [[ "$vless_port" == "443" ]]; then
                ss_port=8388
            else
                ss_port=$((vless_port + 1))
            fi
            
            if [[ -z "$ss_password" ]]; then
                ss_password=$(generate_ss_key)
            fi
            
            run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
            ;;
        *)
            main_menu
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 脚本主入口
# ------------------------------------------------------------------------------
pre_check
non_interactive_dispatcher "$@"
