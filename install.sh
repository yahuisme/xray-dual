#!/bin/bash

# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本
# Version: Final

# --- 脚本设置 ---
set -e
set -o pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="Final"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly subscription_file_path=~/xray_subscription_info.txt

# --- 颜色定义 ---
readonly red='\e[91m'
readonly green='\e[92m'
readonly yellow='\e[93m'
readonly magenta='\e[95m'
readonly cyan='\e[96m'
readonly none='\e[0m'

# --- 辅助函数 ---
error() { echo -e "\n$red$1$none\n"; }
info() { echo -e "\n$yellow$1$none\n"; }
success() { echo -e "\n$green$1$none\n"; }

spinner() {
    local pid=$1; local spinstr='|/-\-'
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}; printf " [%c]  " "$spinstr";
        local spinstr=$temp${spinstr%"$temp"}; sleep 0.1; printf "\r";
    done; printf "    \r";
}

install_dependencies() {
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        if apt-get update && apt-get install -y jq curl; then
            success "依赖安装成功。"
        else
            error "依赖安装失败。请手动执行 'apt-get update && apt-get install -y jq curl' 后再试。"
            exit 1
        fi
    fi
}

# 【全新强化版】检测逻辑
pre_check() {
    [[ $(id -u) != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    
    # 我们使用更直接、更简单的 grep 命令，专门查找您系统中已被证实的 "ID=debian" 或 "ID=ubuntu" 行
    if ! grep -q -e "ID=debian" -e "ID=ubuntu" /etc/os-release; then
        error "错误: 脚本检测到您的系统不是 Debian 或 Ubuntu。请检查 /etc/os-release 文件。"
        exit 1
    fi
    
    install_dependencies
}

get_xray_status_info() {
    if [[ ! -f "$xray_binary_path" ]]; then
        echo -e "  Xray 状态: ${red}未安装${none}"
        return
    fi
    local xray_version
    xray_version=$($xray_binary_path version | head -n 1 | awk '{print $2}')
    local service_status
    if systemctl is-active --quiet xray; then
        service_status="${green}运行中${none}"
    else
        service_status="${yellow}未运行${none}"
    fi
    echo -e "  Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

# --- 核心构建与安装函数 ---
generate_ss_key() {
    openssl rand -base64 16
}

build_vless_inbound() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 shortid="20250825"
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "vless", "settings": {"clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": ($domain + ":443"), "xver": 0, "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid]}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]} }'
}

build_ss_inbound() {
    local port=$1 password=$2
    jq -n --argjson port "$port" --arg password "$password" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "shadowsocks", "settings": {"method": "2022-blake3-aes-128-gcm", "password": $password} }'
}

write_config() {
    local inbounds_json=$1
    jq -n --argjson inbounds "$inbounds_json" \
    '{
      "log": {"loglevel": "warning"},
      "inbounds": $inbounds,
      "outbounds": [ { "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } } ]
    }' > "$xray_config_path"
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    (bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install) &> /dev/null &
    spinner $!; if ! wait $!; then error "Xray 核心安装失败！请检查网络连接。"; return 1; fi
    info "正在更新 GeoIP 和 GeoSite 数据文件...";
    (bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata) &> /dev/null &
    spinner $!; wait $!
    return 0
}

# --- 输入验证与获取 ---
is_valid_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]
}

is_valid_domain() {
    local domain=$1
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ && "$domain" != *--* ]]
}

prompt_for_vless_config() {
    local default_port=${1:-443}
    local default_domain=${2:-"learn.microsoft.com"}
    local vless_port vless_uuid vless_domain

    while true; do
        read -p "$(echo -e "请输入 VLESS 端口 (默认: ${cyan}${default_port}${none}): ")" vless_port
        vless_port=${vless_port:-$default_port}
        if is_valid_port "$vless_port"; then break; else error "端口无效，请输入一个1-65535之间的数字。"; fi
    done
    
    read -p "$(echo -e "请输入UUID (留空将自动生成): ")" vless_uuid
    vless_uuid=${vless_uuid:-$(cat /proc/sys/kernel/random/uuid)}
    info "已为您生成/设置UUID: ${cyan}${vless_uuid}${none}"
    
    while true; do
        read -p "$(echo -e "请输入SNI域名 (默认: ${cyan}${default_domain}${none}): ")" vless_domain
        vless_domain=${vless_domain:-$default_domain}
        if is_valid_domain "$vless_domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    
    echo "$vless_port $vless_uuid $vless_domain"
}

prompt_for_ss_config() {
    local default_port=${1:-8388}
    local ss_port ss_password
    
    while true; do
        read -p "$(echo -e "请输入 Shadowsocks 端口 (默认: ${cyan}${default_port}${none}): ")" ss_port
        ss_port=${ss_port:-$default_port}
        if is_valid_port "$ss_port"; then break; else error "端口无效，请输入一个1-65535之间的数字。"; fi
    done
    
    read -p "$(echo -e "请输入 Shadowsocks 密钥 (留空将自动生成): ")" ss_password
    if [[ -z "$ss_password" ]]; then
        ss_password=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${ss_password}${none}"
    fi
    
    echo "$ss_port $ss_password"
}

# --- 菜单功能函数 ---
install_menu() {
    if [[ ! -f "$xray_config_path" ]]; then
        clean_install_menu
        return
    fi

    local vless_exists
    vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    local ss_exists
    ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    
    clear
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "您已安装 VLESS-Reality + Shadowsocks-2022 双协议。"
        info "如需修改，请使用主菜单的“修改配置”选项。\n如需重装，请先“卸载”后，再重新“安装”。"
        return
    elif [[ -n "$vless_exists" && -z "$ss_exists" ]]; then
        info "检测到您已安装 VLESS-Reality"
        echo "---------------------------------------------"; echo -e "$cyan  请选择下一步操作$none"; echo "---------------------------------------------";
        printf "  ${yellow}%-2s${none} %-35s\n" "1." "追加安装 Shadowsocks-2022 (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 VLESS-Reality"
        echo "---------------------------------------------"; printf "  ${green}%-2s${none} %-35s\n" "0." "返回主菜单"; echo "---------------------------------------------";
        read -p "请输入选项 [0-2]: " choice
        case $choice in 1) add_ss_to_vless ;; 2) install_vless_only ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -z "$vless_exists" && -n "$ss_exists" ]]; then
        info "检测到您已安装 Shadowsocks-2022"
        echo "---------------------------------------------"; echo -e "$cyan  请选择下一步操作$none"; echo "---------------------------------------------";
        printf "  ${yellow}%-2s${none} %-35s\n" "1." "追加安装 VLESS-Reality (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 Shadowsocks-2022"
        echo "---------------------------------------------"; printf "  ${green}%-2s${none} %-35s\n" "0." "返回主菜单"; echo "---------------------------------------------";
        read -p "请输入选项 [0-2]: " choice
        case $choice in 1) add_vless_to_ss ;; 2) install_ss_only ;; 0) return ;; *) error "无效选项。" ;; esac
    else  
        clean_install_menu
    fi
}

clean_install_menu() {
    clear; echo "---------------------------------------------"; echo -e "$cyan  请选择安装类型$none"; echo "---------------------------------------------";
    printf "  ${green}%-2s${none} %-35s\n" "1." "VLESS-Reality"; printf "  ${cyan}%-2s${none} %-35s\n" "2." "Shadowsocks-2022"; printf "  ${yellow}%-2s${none} %-35s\n" "3." "VLESS-Reality + Shadowsocks-2022 (双协议)";
    echo "---------------------------------------------"; printf "  ${green}%-2s${none} %-35s\n" "0." "返回主菜单"; echo "---------------------------------------------";
    read -p "请输入选项 [0-3]: " choice
    case $choice in 1) install_vless_only ;; 2) install_ss_only ;; 3) install_dual ;; 0) return ;; *) error "无效选项。" ;; esac
}

add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    local vless_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    local vless_port
    vless_port=$(echo "$vless_inbound" | jq -r '.port')
    local default_ss_port=$((vless_port == 443 ? 8388 : vless_port + 1))
    
    local ss_port ss_password
    read -r ss_port ss_password <<< "$(prompt_for_ss_config "$default_ss_port")"
    
    local ss_inbound
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    restart_xray
    success "追加安装成功！"; view_all_info
}

add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    local ss_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    local ss_port
    ss_port=$(echo "$ss_inbound" | jq -r '.port')
    local default_vless_port=$((ss_port == 8388 ? 443 : ss_port - 1))
    
    local vless_port vless_uuid vless_domain
    read -r vless_port vless_uuid vless_domain <<< "$(prompt_for_vless_config "$default_vless_port")"
    
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key
    key_pair=$($xray_binary_path x25519)
    private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    
    local vless_inbound
    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    write_config "[$vless_inbound, $ss_inbound]"
    restart_xray
    success "追加安装成功！"; view_all_info
}

install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain
    read -r port uuid domain <<< "$(prompt_for_vless_config)"
    run_install_vless "$port" "$uuid" "$domain"
}

install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password
    read -r port password <<< "$(prompt_for_ss_config)"
    run_install_ss "$port" "$password"
}

install_dual() {
    info "开始配置双协议..."
    local vless_port vless_uuid vless_domain
    read -r vless_port vless_uuid vless_domain <<< "$(prompt_for_vless_config)"
    
    local ss_default_port=$((vless_port == 443 ? 8388 : vless_port + 1))
    info "VLESS 端口设置为: ${cyan}${vless_port}${none}, Shadowsocks 端口将推荐使用: ${cyan}${ss_default_port}${none}"
    
    local ss_port ss_password
    read -r ss_port ss_password <<< "$(prompt_for_ss_config "$ss_default_port")"
    
    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
}

update_xray() {
    [[ ! -f "$xray_binary_path" ]] && error "错误: Xray 未安装。" && return
    info "正在检查最新版本..."
    local current_version
    current_version=$($xray_binary_path version | head -n 1 | awk '{print $2}')
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//')
    
    if [[ -z "$latest_version" ]]; then error "获取最新版本号失败。" && return; fi
    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"
    if [[ "$current_version" == "$latest_version" ]]; then
        success "您的 Xray 已是最新版本。" && return
    fi
    
    info "发现新版本，开始更新..."
    run_core_install && restart_xray && success "Xray 更新成功！"
}

uninstall_xray() {
    [[ ! -f "$xray_binary_path" ]] && error "错误: Xray 未安装。" && return
    read -p "您确定要卸载 Xray 吗？所有配置文件将被删除！ [Y/n]: " confirm
    if [[ $confirm =~ ^[nN]$ ]]; then
        info "操作已取消。"
        return
    fi
    info "正在卸载 Xray..."
    (bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge) &> /dev/null &
    spinner $!
    wait $!
    rm -f "$subscription_file_path"
    success "Xray 已成功卸载。"
}

modify_config_menu() {
    [[ ! -f "$xray_config_path" ]] && error "错误: Xray 未安装。" && return
    local vless_exists
    vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    local ss_exists
    ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        clear; echo "---------------------------------------------"; echo -e "$cyan  请选择要修改的配置$none"; echo "---------------------------------------------"; printf "  ${green}%-2s${none} %-35s\n" "1." "VLESS-Reality"; printf "  ${cyan}%-2s${none} %-35s\n" "2." "Shadowsocks-2022"; echo "---------------------------------------------"; printf "  ${green}%-2s${none} %-35s\n" "0." "返回主菜单"; echo "---------------------------------------------";
        read -p "请输入选项 [0-2]: " choice
        case $choice in 1) modify_vless_config ;; 2) modify_ss_config ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -n "$vless_exists" ]]; then modify_vless_config
    elif [[ -n "$ss_exists" ]]; then modify_ss_config
    else error "未找到可修改的协议配置。"; fi
}

modify_vless_config() {
    info "开始修改 VLESS-Reality 配置..."
    local vless_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    local current_port current_uuid current_domain private_key public_key
    current_port=$(echo "$vless_inbound" | jq -r '.port')
    current_uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
    current_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    private_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.privateKey')
    public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
    
    local port
    while true; do
        read -p "$(echo -e "端口 (当前: ${cyan}${current_port}${none}, 留空则不修改): ")" port
        if [[ -z "$port" ]]; then port=$current_port; info "端口未修改。"; break; fi
        if is_valid_port "$port"; then break; else error "端口无效，请输入一个1-65535之间的数字。"; fi
    done
    local uuid
    read -p "$(echo -e "UUID (当前: ${cyan}${current_uuid}${none}, 留空则不修改): ")" uuid
    if [[ -z "$uuid" ]]; then uuid=$current_uuid; info "UUID 未修改。"; fi
    
    local domain
    while true; do
        read -p "$(echo -e "SNI域名 (当前: ${cyan}${current_domain}${none}, 留空则不修改): ")" domain
        if [[ -z "$domain" ]]; then domain=$current_domain; info "SNI域名未修改。"; break; fi
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    local new_vless_inbound ss_inbound new_inbounds
    new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    new_inbounds="[${new_vless_inbound}]"; [[ -n "$ss_inbound" ]] && new_inbounds="[${new_vless_inbound}, ${ss_inbound}]"
    write_config "$new_inbounds"
    restart_xray
    success "配置修改成功！"; view_all_info
}

modify_ss_config() {
    info "开始修改 Shadowsocks-2022 配置..."
    local ss_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    local current_port current_password
    current_port=$(echo "$ss_inbound" | jq -r '.port')
    current_password=$(echo "$ss_inbound" | jq -r '.settings.password')
    
    local port
    while true; do
        read -p "$(echo -e "端口 (当前: ${cyan}${current_port}${none}, 留空则不修改): ")" port
        if [[ -z "$port" ]]; then port=$current_port; info "端口未修改。"; break; fi
        if is_valid_port "$port"; then break; else error "端口无效，请输入一个1-65535之间的数字。"; fi
    done
    local password_input new_password
    read -p "$(echo -e "密钥 (留空保留当前密码): ")" password_input
    if [[ -z "$password_input" ]]; then new_password=$current_password; info "密钥未修改。"; else new_password=$password_input; info "密钥已更新。"; fi
    local new_ss_inbound vless_inbound new_inbounds
    new_ss_inbound=$(build_ss_inbound "$port" "$new_password")
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    new_inbounds="[${new_ss_inbound}]"; [[ -n "$vless_inbound" ]] && new_inbounds="[${vless_inbound}, ${new_ss_inbound}]"
    write_config "$new_inbounds"
    restart_xray
    success "配置修改成功！"; view_all_info
}

restart_xray() {
    [[ ! -f "$xray_binary_path" ]] && error "错误: Xray 未安装。" && return 1
    info "正在重启 Xray 服务..."
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
        return 0
    else
        error "服务启动失败, 请使用 '查看 Xray 日志' 功能检查错误。"
        return 1
    fi
}

view_xray_log() {
    [[ ! -f "$xray_binary_path" ]] && error "错误: Xray 未安装。" && return
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

view_all_info() {
    [[ ! -f "$xray_config_path" ]] && error "错误: 配置文件不存在。" && return
    info "正在从配置文件生成订阅信息..."
    
    local ip
    ip=$(curl -s4 https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*') || \
    ip=$(curl -s6 https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*')
    
    local links_array=()
    
    local vless_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$vless_inbound" ]]; then
        local uuid port domain public_key shortid display_ip link_name_raw link_name_encoded vless_url
        uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
        port=$(echo "$vless_inbound" | jq -r '.port')
        domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
        link_name_raw="$(hostname) X-reality"
        link_name_encoded=$(echo "$link_name_raw" | sed 's/ /%20/g')
        vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
        links_array+=("$vless_url")
        
        echo "----------------------------------------------------------------"; echo -e "$green --- VLESS-Reality 订阅信息 --- $none";
        echo -e "$yellow 名称: $cyan$link_name_raw$none"; echo -e "$yellow 地址: $cyan$ip$none"; echo -e "$yellow 端口: $cyan$port$none"; echo -e "$yellow UUID: $cyan$uuid$none"
        echo -e "$yellow 流控: $cyan"xtls-rprx-vision"$none"; echo -e "$yellow 指纹: $cyan"chrome"$none"; echo -e "$yellow SNI: $cyan$domain$none"; echo -e "$yellow 公钥: $cyan$public_key$none"; echo -e "$yellow ShortId: $cyan$shortid$none"
    fi
    
    local ss_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$ss_inbound" ]]; then
        local port method password user_info_base64 link_name_raw ss_url
        port=$(echo "$ss_inbound" | jq -r '.port')
        method=$(echo "$ss_inbound" | jq -r '.settings.method')
        password=$(echo "$ss_inbound" | jq -r '.settings.password')
        user_info_base64=$(echo -n "$method:$password" | base64 -w 0)
        link_name_raw="$(hostname) X-ss2022"
        ss_url="ss://${user_info_base64}@$ip:$port#${link_name_raw}"
        links_array+=("$ss_url")

        echo "----------------------------------------------------------------"; echo -e "$green --- Shadowsocks-2022 订阅信息 --- $none";
        echo -e "$yellow 名称: $cyan$link_name_raw$none"; echo -e "$yellow 地址: $cyan$ip$none"; echo -e "$yellow 端口: $cyan$port$none"; echo -e "$yellow 加密: $cyan$method$none"
        echo -e "$yellow 密钥: $cyan$password$none"
    fi

    if [ ${#links_array[@]} -gt 0 ]; then
        printf "%s\n" "${links_array[@]}" > "$subscription_file_path"
        echo "----------------------------------------------------------------"; echo -e "$green 所有链接已汇总保存到 $subscription_file_path $none";
        echo -e "\n$cyan--- 汇总订阅链接 (方便一次性复制) ---$none\n"
        printf "%s\n\n" "${links_array[@]}"
        echo "----------------------------------------------------------------";
    fi
}

# --- 核心安装流程 ---
run_install_vless() {
    local port=$1 uuid=$2 domain=$3
    run_core_install
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound
    key_pair=$($xray_binary_path x25519)
    private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    write_config "[$vless_inbound]"
    restart_xray
    success "VLESS-Reality 安装成功！"
    view_all_info
}

run_install_ss() {
    local port=$1 password=$2
    run_core_install
    local ss_inbound
    ss_inbound=$(build_ss_inbound "$port" "$password")
    write_config "[$ss_inbound]"
    restart_xray
    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

run_install_dual() {
    local vless_port=$1 vless_uuid=$2 vless_domain=$3 ss_port=$4 ss_password=$5
    run_core_install
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound ss_inbound
    key_pair=$($xray_binary_path x25519)
    private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    restart_xray
    success "双协议安装成功！"
    view_all_info
}

# --- 主菜单与脚本入口 ---
main_menu() {
    while true; do
        clear
        echo -e "$cyan Xray 多功能管理脚本$none"
        echo "---------------------------------------------"
        echo -e "$(get_xray_status_info)"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/管理 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "3." "卸载 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "4." "重启 Xray"
        printf "  ${yellow}%-2s${none} %-35s\n" "5." "修改配置"
        printf "  ${magenta}%-2s${none} %-35s\n" "6." "查看 Xray 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "7." "查看订阅信息"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-7]: " choice
        
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

non_interactive_dispatcher() {
    local mode=$1; shift
    case "$mode" in
        vless)
            [[ $# -ne 3 ]] && error "VLESS模式需要3个参数: <端口> <UUID> <域名>" && exit 1
            is_valid_port "$1" || { error "端口 '$1' 无效"; exit 1; }
            is_valid_domain "$3" || { error "域名 '$3' 无效"; exit 1; }
            run_install_vless "$@"
            ;;
        ss)
            [[ $# -ne 2 ]] && error "Shadowsocks模式需要2个参数: <端口> <密码>" && exit 1
            is_valid_port "$1" || { error "端口 '$1' 无效"; exit 1; }
            run_install_ss "$@"
            ;;
        dual)
            [[ $# -ne 4 ]] && error "双协议模式需要4个参数: <VLESS端口> <UUID> <域名> <SS密码>" && exit 1
            is_valid_port "$1" || { error "VLESS端口 '$1' 无效"; exit 1; }
            is_valid_domain "$3" || { error "域名 '$3' 无效"; exit 1; }
            local vless_port=$1 vless_uuid=$2 vless_domain=$3 ss_password=$4
            local ss_port=$((vless_port == 443 ? 8388 : vless_port + 1))
            run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
            ;;
        *)
            main_menu
            ;;
    esac
}

# --- 脚本主入口 ---
pre_check
non_interactive_dispatcher "$@"
