#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本
# 版本: Final v2.9
# 更新日志 (v2.9):
# - [修复] 更新 Reality 密钥对的解析逻辑，以兼容新版 Xray-core 中
#   'xray x25519' 命令可能发生的输出格式变更，增强脚本健壮性。
# ==============================================================================
# v2.8: 对 'check_xray_status' 函数进行加固，解决服务初启时序问题
# v2.7: 根据用户建议，调整双协议安装模式下的提问顺序及整体排版
# v2.6: 对所有交互式 'read' 命令进行加固，防止在 'set -e' 模式下因输入中断导致脚本意外退出
# v2.5: 优化了配置信息输出的排版，使其更紧凑清晰
# v2.4: 恢复了在 v2.3 版本中意外被删除的详细配置信息输出
# v2.3: 重构安装/卸载流程, 增加密钥生成验证, 增强更新检查及服务重启逻辑
# v2.2: 修复了在未安装Xray时，调用jq读取不存在的配置文件导致脚本退出的问题
# v2.1: 修复了在无参数启动时因'set -u'导致的 "unbound variable" 错误
# v2.0: 修复菜单选项颠倒BUG, 增强健壮性/IP获取/非交互模式, 优化代码实践
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="Final v2.9"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
xray_status_info=""
is_quiet=false

# --- 辅助函数 ---
error() { echo -e "\n$red[✖] $1$none\n" >&2; }
info() { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[!] $1$none\n"; }
success() { [[ "$is_quiet" = false ]] && echo -e "\n$green[✔] $1$none\n"; }

spinner() {
    local pid="$1"
    local spinstr='|/-\'
    if [[ "$is_quiet" = true ]]; then
        wait "$pid"
        return
    fi
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ "$(id -u)" != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl) &> /dev/null &
        spinner $!
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
            error "依赖 (jq/curl) 自动安装失败。请手动运行 'apt update && apt install -y jq curl' 后重试。"
            exit 1
        fi
        success "依赖已成功安装。"
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" || ! -x "$xray_binary_path" ]]; then
        xray_status_info=" Xray 状态: ${red}未安装${none}"
        return
    fi

    local xray_version
    xray_version=$("$xray_binary_path" version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
    
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then
        service_status="${green}运行中${none}"
    else
        service_status="${yellow}未运行${none}"
    fi
    
    xray_status_info=" Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}


# --- 核心配置生成函数 ---
generate_ss_key() {
    openssl rand -base64 16
}

build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" private_key="$4" public_key="$5" shortid="20220701"
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "vless", "settings": {"clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": ($domain + ":443"), "xver": 0, "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid]}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]} }'
}

build_ss_inbound() {
    local port="$1" password="$2"
    jq -n --argjson port "$port" --arg password "$password" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "shadowsocks", "settings": {"method": "2022-blake3-aes-128-gcm", "password": $password} }'
}

write_config() {
    local inbounds_json="$1"
    jq -n --argjson inbounds "$inbounds_json" \
    '{
      "log": {"loglevel": "warning"},
      "inbounds": $inbounds,
      "outbounds": [
        {
          "protocol": "freedom",
          "settings": {
            "domainStrategy": "UseIPv4v6"
          }
        }
      ]
    }' > "$xray_config_path"
}

execute_official_script() {
    local args="$1"
    local script_content
    script_content=$(curl -L "$xray_install_script_url")
    if [[ -z "$script_content" ]]; then
        error "下载 Xray 官方安装脚本失败！请检查网络连接。"
        return 1
    fi
    
    bash -c "$script_content" @ $args &> /dev/null &
    spinner $!
    if ! wait $!; then
        return 1
    fi
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    if ! execute_official_script "install"; then
        error "Xray 核心安装失败！"
        return 1
    fi
    
    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    if ! execute_official_script "install-geodata"; then
        error "Geo-data 更新失败！"
        info "这通常不影响核心功能，您可以稍后手动更新。"
    fi
    
    success "Xray 核心及数据文件已准备就绪。"
}


# --- 输入验证函数 ---
is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]
}

# --- 菜单功能函数 ---
draw_divider() {
    printf "%0.s─" {1..48}
    printf "\n"
}

draw_menu_header() {
    clear
    echo -e "${cyan} Xray VLESS-Reality & Shadowsocks-2022 管理脚本${none}"
    echo -e "${yellow} Version: ${SCRIPT_VERSION}${none}"
    draw_divider
    check_xray_status
    echo -e "${xray_status_info}"
    draw_divider
}

press_any_key_to_continue() {
    echo ""
    read -n 1 -s -r -p " 按任意键返回主菜单..." || true
}

install_menu() {
    local vless_exists="" ss_exists=""
    if [[ -f "$xray_config_path" ]]; then
        vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
        ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    fi
    
    draw_menu_header
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "您已安装 VLESS-Reality + Shadowsocks-2022 双协议。"
        info "如需修改，请使用主菜单的“修改配置”选项。\n 如需重装，请先“卸载”后，再重新“安装”。"
        return
    elif [[ -n "$vless_exists" && -z "$ss_exists" ]]; then
        info "检测到您已安装 VLESS-Reality"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 Shadowsocks-2022 (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 VLESS-Reality"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) add_ss_to_vless ;; 2) install_vless_only ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -z "$vless_exists" && -n "$ss_exists" ]]; then
        info "检测到您已安装 Shadowsocks-2022"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 VLESS-Reality (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) add_vless_to_ss ;; 2) install_ss_only ;; 0) return ;; *) error "无效选项。" ;; esac
    else
        clean_install_menu
    fi
}

clean_install_menu() {
    draw_menu_header
    echo -e "${cyan} 请选择要安装的协议类型${none}"
    draw_divider
    printf "  ${green}%-2s${none} %-35s\n" "1." "仅 VLESS-Reality"
    printf "  ${cyan}%-2s${none} %-35s\n" "2." "仅 Shadowsocks-2022"
    printf "  ${yellow}%-2s${none} %-35s\n" "3." "VLESS-Reality + Shadowsocks-2022 (双协议)"
    draw_divider
    printf "  ${magenta}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider
    read -p " 请输入选项 [0-3]: " choice || true
    case "$choice" in 1) install_vless_only ;; 2) install_ss_only ;; 3) install_dual ;; 0) return ;; *) error "无效选项。" ;; esac
}

add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    local vless_inbound vless_port default_ss_port ss_port ss_password ss_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    vless_port=$(echo "$vless_inbound" | jq -r '.port')
    default_ss_port=$([[ "$vless_port" == "443" ]] && echo "8388" || echo "$((vless_port + 1))")
    
    while true; do
        read -p "$(echo -e " -> 请输入 Shadowsocks 端口 (默认: ${cyan}${default_ss_port}${none}): ")" ss_port || true
        [[ -z "$ss_port" ]] && ss_port=$default_ss_port
        if is_valid_port "$ss_port"; then break; else error "端口无效，请输入1-65535之间的数字。"; fi
    done
    info "Shadowsocks 端口将使用: ${cyan}${ss_port}${none}"
    
    read -p "$(echo -e " -> 请输入 Shadowsocks 密钥 (留空将自动生成): ")" ss_password || true
    if [[ -z "$ss_password" ]]; then
        ss_password=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${ss_password}${none}"
    fi
    
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    restart_xray
    success "追加安装成功！"
    view_all_info
}

add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    local ss_inbound ss_port default_vless_port vless_port vless_uuid vless_domain key_pair private_key public_key vless_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    ss_port=$(echo "$ss_inbound" | jq -r '.port')
    default_vless_port=$([[ "$ss_port" == "8388" ]] && echo "443" || echo "$((ss_port - 1))")
    
    while true; do
        read -p "$(echo -e " -> 请输入 VLESS 端口 (默认: ${cyan}${default_vless_port}${none}): ")" vless_port || true
        [[ -z "$vless_port" ]] && vless_port=$default_vless_port
        if is_valid_port "$vless_port"; then break; else error "端口无效，请输入1-65535之间的数字。"; fi
    done
    info "VLESS 端口将使用: ${cyan}${vless_port}${none}"

    read -p "$(echo -e " -> 请输入UUID (留空将自动生成): ")" vless_uuid || true
    if [[ -z "$vless_uuid" ]]; then
        vless_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${vless_uuid}${none}"
    fi
    
    while true; do
        read -p "$(echo -e " -> 请输入SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" vless_domain || true
        [[ -z "$vless_domain" ]] && vless_domain="learn.microsoft.com"
        if is_valid_domain "$vless_domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    info "SNI 域名将使用: ${cyan}${vless_domain}${none}"

    info "正在生成 Reality 密钥对..."
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk -F': ' '/Private key/ {print $2}')
    public_key=$(echo "$key_pair" | awk -F': ' '/Public key/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi
    
    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    write_config "[$vless_inbound, $ss_inbound]"
    restart_xray
    success "追加安装成功！"
    view_all_info
}

install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain
    while true; do
        read -p "$(echo -e " -> 请输入 VLESS 端口 (默认: ${cyan}443${none}): ")" port || true
        [[ -z "$port" ]] && port=443
        if is_valid_port "$port"; then break; else error "端口无效，请输入1-65535之间的数字。"; fi
    done
    
    read -p "$(echo -e " -> 请输入UUID (留空将自动生成): ")" uuid || true
    if [[ -z "$uuid" ]]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${uuid}${none}"
    fi
    
    while true; do
        read -p "$(echo -e " -> 请输入SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" domain || true
        [[ -z "$domain" ]] && domain="learn.microsoft.com"
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    
    run_install_vless "$port" "$uuid" "$domain"
}

install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password
    while true; do
        read -p "$(echo -e " -> 请输入 Shadowsocks 端口 (默认: ${cyan}8388${none}): ")" port || true
        [[ -z "$port" ]] && port=8388
        if is_valid_port "$port"; then break; else error "端口无效，请输入1-65535之间的数字。"; fi
    done

    read -p "$(echo -e " -> 请输入 Shadowsocks 密钥 (留空将自动生成): ")" password || true
    if [[ -z "$password" ]]; then
        password=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${password}${none}"
    fi
    
    run_install_ss "$port" "$password"
}

install_dual() {
    info "开始配置双协议 (VLESS-Reality + Shadowsocks-2022)..."
    local vless_port vless_uuid vless_domain ss_port ss_password

    while true; do
        read -p "$(echo -e " -> 请输入 VLESS 端口 (默认: ${cyan}443${none}): ")" vless_port || true
        [[ -z "$vless_port" ]] && vless_port=443
        if is_valid_port "$vless_port"; then break; else error "端口无效，请输入1-65535之间的数字。"; fi
    done
    
    if [[ "$vless_port" == "443" ]]; then
        while true; do
            read -p "$(echo -e " -> 请输入 Shadowsocks 端口 (默认: ${cyan}8388${none}): ")" ss_port || true
            [[ -z "$ss_port" ]] && ss_port=8388
            if is_valid_port "$ss_port"; then break; else error "端口无效，请输入1-65535之间的数字。"; fi
        done
    else
        ss_port=$((vless_port + 1))
        info "VLESS 端口设置为: ${cyan}${vless_port}${none}, Shadowsocks 端口将自动设置为: ${cyan}${ss_port}${none}"
    fi
    
    read -p "$(echo -e " -> 请输入 VLESS UUID (留空将自动生成): ")" vless_uuid || true
    if [[ -z "$vless_uuid" ]]; then
        vless_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${vless_uuid}${none}"
    fi

    read -p "$(echo -e " -> 请输入 Shadowsocks 密钥 (留空将自动生成): ")" ss_password || true
    if [[ -z "$ss_password" ]]; then
        ss_password=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${ss_password}${none}"
    fi

    while true; do
        read -p "$(echo -e " -> 请输入 VLESS SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" vless_domain || true
        [[ -z "$vless_domain" ]] && vless_domain="learn.microsoft.com"
        if is_valid_domain "$vless_domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done

    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在检查最新版本..."
    local current_version latest_version
    current_version=$("$xray_binary_path" version | head -n 1 | awk '{print $2}')
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//' || echo "")
    
    if [[ -z "$latest_version" ]]; then error "获取最新版本号失败，请检查网络或稍后重试。" && return; fi
    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"
    
    if [[ "$current_version" == "$latest_version" ]]; then
        success "您的 Xray 已是最新版本。" && return
    fi
    
    info "发现新版本，开始更新..."
    run_core_install
    restart_xray
    success "Xray 更新成功！"
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    read -p "$(echo -e "${yellow}您确定要卸载 Xray 吗？这将删除所有配置！[Y/n]: ${none}")" confirm || true
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        info "操作已取消。"
        return
    fi
    info "正在卸载 Xray..."
    if ! execute_official_script "remove --purge"; then
        error "Xray 卸载失败！"
        return 1
    fi
    rm -f ~/xray_subscription_info.txt
    success "Xray 已成功卸载。"
}

modify_config_menu() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装。" && return; fi
    
    local vless_exists="" ss_exists=""
    if [[ -f "$xray_config_path" ]]; then
        vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
        ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    fi
    
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        draw_menu_header
        echo -e "${cyan} 请选择要修改的协议配置${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "VLESS-Reality"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) modify_vless_config ;; 2) modify_ss_config ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -n "$vless_exists" ]]; then
        modify_vless_config
    elif [[ -n "$ss_exists" ]]; then
        modify_ss_config
    else
        error "未找到可修改的协议配置。"
    fi
}

modify_vless_config() {
    info "开始修改 VLESS-Reality 配置..."
    local vless_inbound current_port current_uuid current_domain private_key public_key port uuid domain new_vless_inbound ss_inbound new_inbounds
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    current_port=$(echo "$vless_inbound" | jq -r '.port')
    current_uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
    current_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    private_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.privateKey')
    public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
    
    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port=$current_port
        if is_valid_port "$port"; then break; else error "端口无效，请输入1-65535之间的数字。"; fi
    done

    read -p "$(echo -e " -> 新UUID (当前: ${cyan}${current_uuid:0:8}...${none}, 留空不改): ")" uuid || true
    [[ -z "$uuid" ]] && uuid=$current_uuid
    
    while true; do
        read -p "$(echo -e " -> 新SNI域名 (当前: ${cyan}${current_domain}${none}, 留空不改): ")" domain || true
        [[ -z "$domain" ]] && domain=$current_domain
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    
    new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    new_inbounds="[$new_vless_inbound]"
    [[ -n "$ss_inbound" ]] && new_inbounds="[$new_vless_inbound, $ss_inbound]"
    
    write_config "$new_inbounds"
    restart_xray
    success "配置修改成功！"
    view_all_info
}

modify_ss_config() {
    info "开始修改 Shadowsocks-2022 配置..."
    local ss_inbound current_port current_password port password new_ss_inbound vless_inbound new_inbounds
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    current_port=$(echo "$ss_inbound" | jq -r '.port')
    current_password=$(echo "$ss_inbound" | jq -r '.settings.password')
    
    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port=$current_port
        if is_valid_port "$port"; then break; else error "端口无效，请输入1-65535之间的数字。"; fi
    done

    read -p "$(echo -e " -> 新密钥 (当前: ${cyan}${current_password}${none}, 留空不改): ")" password || true
    [[ -z "$password" ]] && password=$current_password
    
    new_ss_inbound=$(build_ss_inbound "$port" "$password")
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    new_inbounds="[$new_ss_inbound]"
    [[ -n "$vless_inbound" ]] && new_inbounds="[$vless_inbound, $new_ss_inbound]"
    
    write_config "$new_inbounds"
    restart_xray
    success "配置修改成功！"
    view_all_info
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return 1; fi
    info "正在重启 Xray 服务..."
    if ! systemctl restart xray; then
        error "尝试重启 Xray 服务失败！请使用“查看日志”功能检查具体错误。"
        return 1
    fi
    sleep 1
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
    else
        error "服务启动失败, 请使用“查看日志”功能检查错误。"
        return 1
    fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

view_all_info() {
    if [ ! -f "$xray_config_path" ]; then
        [[ "$is_quiet" = true ]] && return
        error "错误: 配置文件不存在。"
        return
    fi
    
    [[ "$is_quiet" = false ]] && clear && echo -e "${cyan} Xray 配置及订阅信息${none}" && draw_divider

    local ip
    ip=$(get_public_ip)
    if [[ -z "$ip" ]]; then
        [[ "$is_quiet" = false ]] && error "无法获取公网 IP 地址。"
        return 1
    fi
    local host
    host=$(hostname)
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
        
        if [[ -z "$public_key" ]]; then
            [[ "$is_quiet" = false ]] && error "VLESS配置不完整，可能已损坏。"
        else
            display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
            link_name_raw="$host X-reality"
            link_name_encoded=$(echo "$link_name_raw" | sed 's/ /%20/g')
            vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
            links_array+=("$vless_url")

            if [[ "$is_quiet" = false ]]; then
                echo -e "${green} [ VLESS-Reality 配置 ]${none}"
                printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
                printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
                printf "    %s: ${cyan}%s${none}\n" "UUID" "$uuid"
                printf "    %s: ${cyan}%s${none}\n" "流控" "xtls-rprx-vision"
                printf "    %s: ${cyan}%s${none}\n" "加密" "none"
                printf "    %s: ${cyan}%s${none}\n" "传输协议" "tcp"
                printf "    %s: ${cyan}%s${none}\n" "伪装类型" "none"
                printf "    %s: ${cyan}%s${none}\n" "安全类型" "reality"
                printf "    %s: ${cyan}%s${none}\n" "SNI" "$domain"
                printf "    %s: ${cyan}%s${none}\n" "指纹" "chrome"
                printf "    %s: ${cyan}%s${none}\n" "PublicKey" "${public_key:0:20}..."
                printf "    %s: ${cyan}%s${none}\n" "ShortId" "$shortid"
            fi
        fi
    fi

    local ss_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$ss_inbound" ]]; then
        local port method password link_name_raw user_info_base64 ss_url
        port=$(echo "$ss_inbound" | jq -r '.port')
        method=$(echo "$ss_inbound" | jq -r '.settings.method')
        password=$(echo "$ss_inbound" | jq -r '.settings.password')
        link_name_raw="$host X-ss2022"
        user_info_base64=$(echo -n "${method}:${password}" | base64 -w 0)
        ss_url="ss://${user_info_base64}@${ip}:${port}#${link_name_raw}"
        links_array+=("$ss_url")
        
        if [[ "$is_quiet" = false ]]; then
            echo ""
            echo -e "${green} [ Shadowsocks-2022 配置 ]${none}"
            printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
            printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
            printf "    %s: ${cyan}%s${none}\n" "加密方式" "$method"
            printf "    %s: ${cyan}%s${none}\n" "密码" "$password"
        fi
    fi

    if [ ${#links_array[@]} -gt 0 ]; then
        if [[ "$is_quiet" = true ]]; then
            printf "%s\n" "${links_array[@]}"
        else
            draw_divider
            printf "%s\n" "${links_array[@]}" > ~/xray_subscription_info.txt
            success "所有订阅链接已汇总保存到: ~/xray_subscription_info.txt"
            
            echo -e "\n${yellow} --- V2Ray / Clash 等客户端可直接导入以下链接 --- ${none}\n"
            for link in "${links_array[@]}"; do
                echo -e "${cyan}${link}${none}\n"
            done
            draw_divider
        fi
    elif [[ "$is_quiet" = false ]]; then
        info "当前未安装任何协议，无订阅信息可显示。"
    fi
}


# --- 核心安装逻辑函数 ---
run_install_vless() {
    local port="$1" uuid="$2" domain="$3"
    run_core_install || exit 1
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk -F': ' '/Private key/ {print $2}')
    public_key=$(echo "$key_pair" | awk -F': ' '/Public key/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    write_config "[$vless_inbound]"
    restart_xray
    success "VLESS-Reality 安装成功！"
    view_all_info
}

run_install_ss() {
    local port="$1" password="$2"
    run_core_install || exit 1
    local ss_inbound
    ss_inbound=$(build_ss_inbound "$port" "$password")
    write_config "[$ss_inbound]"
    restart_xray
    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

run_install_dual() {
    local vless_port="$1" vless_uuid="$2" vless_domain="$3" ss_port="$4" ss_password="$5"
    run_core_install || exit 1
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound ss_inbound
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk -F': ' '/Private key/ {print $2}')
    public_key=$(echo "$key_pair" | awk -F': ' '/Public key/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

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
        draw_menu_header
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 Xray (VLESS/Shadowsocks)"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "3." "卸载 Xray"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "4." "修改配置"
        printf "  ${cyan}%-2s${none} %-35s\n" "5." "重启 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "6." "查看 Xray 日志"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看订阅信息"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        draw_divider
        
        read -p " 请输入选项 [0-7]: " choice || true
        
        local needs_pause=true
        
        case "$choice" in
            1) install_menu ;;
            2) update_xray ;;
            3) uninstall_xray ;;
            4) modify_config_menu ;;
            5) restart_xray ;;
            6) view_xray_log; needs_pause=false ;;
            7) view_all_info ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项。请输入0到7之间的数字。" ;;
        esac
        
        if [ "$needs_pause" = true ]; then
            press_any_key_to_continue
        fi
    done
}

# --- 非交互式安装逻辑 ---
non_interactive_usage() {
    cat << 'EOF'

非交互式安装用法:
  ./$(basename "$0") install --type <vless|ss|dual> [选项...]

  通用选项:
    --type <type>      安装类型 (必须: vless, ss, dual)
    --quiet            静默模式, 成功后只输出订阅链接

  VLESS 选项:
    --vless-port <p>   VLESS 端口 (默认: 443)
    --uuid <uuid>      UUID (默认: 随机生成)
    --sni <domain>     SNI 域名 (默认: learn.microsoft.com)

  Shadowsocks 选项:
    --ss-port <p>      Shadowsocks 端口 (默认: 8388)
    --ss-pass <pass>   Shadowsocks 密码 (默认: 随机生成)

  示例:
    # 安装 VLESS (使用默认值)
    ./$(basename "$0") install --type vless

    # 安静地安装双协议并指定 VLESS 端口和 UUID，并将链接保存到文件
    ./$(basename "$0") install --type dual --vless-port 2053 --uuid 'your-uuid-here' --quiet > links.txt
EOF
}

non_interactive_dispatcher() {
    if [[ $# -eq 0 || "$1" != "install" ]]; then
        main_menu
        return
    fi
    shift

    local type="" vless_port="" uuid="" sni="" ss_port="" ss_pass=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) type="$2"; shift 2 ;;
            --vless-port) vless_port="$2"; shift 2 ;;
            --uuid) uuid="$2"; shift 2 ;;
            --sni) sni="$2"; shift 2 ;;
            --ss-port) ss_port="$2"; shift 2 ;;
            --ss-pass) ss_pass="$2"; shift 2 ;;
            --quiet) is_quiet=true; shift ;;
            *) error "未知参数: $1"; non_interactive_usage; exit 1 ;;
        esac
    done

    case "$type" in
        vless)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$sni"; then
                error "VLESS 参数无效。请检查端口或SNI域名。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装 VLESS..."
            run_install_vless "$vless_port" "$uuid" "$sni"
            ;;
        ss)
            [[ -z "$ss_port" ]] && ss_port=8388
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            if ! is_valid_port "$ss_port"; then
                error "Shadowsocks 参数无效。请检查端口。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装 Shadowsocks..."
            run_install_ss "$ss_port" "$ss_pass"
            ;;
        dual)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            if [[ -z "$ss_port" ]]; then
                if [[ "$vless_port" == "443" ]]; then ss_port=8388; else ss_port=$((vless_port + 1)); fi
            fi
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$sni" || ! is_valid_port "$ss_port"; then
                error "双协议参数无效。请检查端口或SNI域名。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装双协议..."
            run_install_dual "$vless_port" "$uuid" "$sni" "$ss_port" "$ss_pass"
            ;;
        *)
            error "必须通过 --type 指定安装类型 (vless|ss|dual)"
            non_interactive_usage
            exit 1
            ;;
    esac
}

# --- 脚本主入口 ---
main() {
    pre_check
    non_interactive_dispatcher "$@"
}

main "$@"
