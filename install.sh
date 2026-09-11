#!/bin/bash

# ==============================================================================
# Xray 双协议极简一键安装脚本 (VLESS-Reality & Shadowsocks-2022)
# 系统支持: Debian 10+ / Ubuntu 20.04+
# 版本: v26.09.11
# ==============================================================================

set -euo pipefail

# --- 全局常量定义 ---
readonly SCRIPT_VERSION="v26.09.11"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://raw.githubusercontent.com/XTLS/Xray-install/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh"
readonly xray_install_script_sha256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"

# --- 颜色定义 ---
# Use a shared palette only when both output channels are terminals.
# This also keeps read -p prompts (stderr) plain under redirection.
red='' green='' yellow='' magenta='' cyan='' none=''
if [[ -t 1 && -t 2 && ! -v NO_COLOR && ${TERM:-dumb} != dumb ]]; then
    red=$'\033[91m' green=$'\033[92m' yellow=$'\033[93m'
    magenta=$'\033[95m' cyan=$'\033[96m' none=$'\033[0m'
fi
readonly red green yellow magenta cyan none

# --- 全局变量 ---
xray_status_info=""
config_backup=""
config_written=false

# 中断时清理临时配置文件，避免残留
trap 'rm -f "${xray_config_path}".tmp.* 2>/dev/null || true' EXIT

# --- 辅助函数 ---
error() {
    printf '\n%b[✖] %s%b\n\n' "$red" "$1" "$none" >&2

    # 根据错误内容提供简单建议
    case "$1" in
        *"网络"*|*"下载"*)
            printf '%b\n' "$yellow提示: 检查网络连接或更换DNS$none" >&2 ;;
        *"权限"*|*"root"*)
            printf '%b\n' "$yellow提示: 请使用 sudo 运行脚本$none" >&2 ;;
        *"端口"*)
            printf '%b\n' "$yellow提示: 尝试使用其他端口号$none" >&2 ;;
    esac
}

info() { printf '\n%b[!] %b%b\n' "$yellow" "$1" "$none"; }
success() { printf '\n%b[✔] %b%b\n' "$green" "$1" "$none"; }
warning() { printf '\n%b[⚠] %b%b\n' "$yellow" "$1" "$none"; }

is_valid_ipv6() {
    local ip="$1" part rest count=0 compressed=false
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* && "$ip" != *:::* ]] || return 1
    [[ "$ip" != :* || "$ip" == ::* ]] || return 1
    [[ "$ip" != *: || "$ip" == *:: ]] || return 1
    if [[ "$ip" == *::* ]]; then
        compressed=true
        rest=${ip#*::}
        [[ "$rest" != *::* ]] || return 1
        ip=${ip/::/:}
        ip=${ip#:}; ip=${ip%:}
    else
        [[ "$ip" != :* && "$ip" != *: ]] || return 1
    fi
    while [[ -n "$ip" ]]; do
        part=${ip%%:*}
        [[ "$part" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        count=$((count + 1))
        [[ "$ip" == *:* ]] || break
        ip=${ip#*:}
    done
    if "$compressed"; then (( count < 8 )); else (( count == 8 )); fi
}

get_public_ip() {
    local ip url cache_file="/usr/local/etc/xray/.public-ip"
    # 缓存 1 天，避免每次查看配置都发起网络请求；公网 IP 变更后自动刷新
    if [[ -f "$cache_file" && -z "$(find "$cache_file" -mmin +1440 2>/dev/null)" ]]; then
        ip=$(<"$cache_file")
        [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return; }
    fi
    for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
        ip=$(curl -4s --connect-timeout 3 --max-time 5 "$url" 2>/dev/null || true)
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            # 校验每个八位组 0-255，避免异常响应进入客户端链接
            local valid=true octet
            IFS=. read -ra octets <<< "$ip"
            for octet in "${octets[@]}"; do
                [[ $((10#$octet)) -le 255 ]] || valid=false
            done
            if [[ "$valid" == true ]]; then
                # 首次安装时配置目录尚未创建；缓存失败不影响有效 IP 返回。
                { [[ -d "${cache_file%/*}" ]] && printf '%s\n' "$ip" 2>/dev/null > "$cache_file"; } || true
                printf '%s\n' "$ip"
                return
            fi
        fi
    done
    for url in https://api64.ipify.org https://ip.sb; do
        ip=$(curl -6s --connect-timeout 3 --max-time 5 "$url" 2>/dev/null || true)
        if [[ -n "$ip" ]] && is_valid_ipv6 "$ip"; then
            { [[ -d "${cache_file%/*}" ]] && printf '%s\n' "$ip" 2>/dev/null > "$cache_file"; } || true
            printf '%s\n' "$ip"
            return
        fi
    done
    return 1
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ "$(id -u)" != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null ||
       ! command -v ss &>/dev/null || ! command -v openssl &>/dev/null ||
       ! command -v sha256sum &>/dev/null; then
        info "检测到缺失依赖，正在尝试自动安装..."
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y jq curl iproute2 openssl coreutils >/dev/null 2>&1 || true
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null ||
           ! command -v ss &>/dev/null || ! command -v openssl &>/dev/null ||
           ! command -v sha256sum &>/dev/null; then
            error "依赖自动安装失败。请手动安装 jq curl iproute2 openssl coreutils 后重试。"
            exit 1
        fi
        success "依赖安装成功。"
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" || ! -x "$xray_binary_path" ]]; then
        xray_status_info=" Xray 状态: ${red}未安装${none}"
        return
    fi
    local version_output xray_version
    version_output=$("$xray_binary_path" version 2>/dev/null || true)
    xray_version=$(awk 'NR == 1 {print $2; exit}' <<< "$version_output")
    [[ -n "$xray_version" ]] || xray_version="未知"
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
    # Xray decodes the SS-2022 server key with standard padded Base64.
    openssl rand -base64 16 | tr -d '\n'
}

build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" private_key="$4" public_key="$5" shortid="20220701"
    is_valid_port "$port" && is_valid_uuid "$uuid" && is_valid_domain "$domain" || return 1
    [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ && "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" \
    '{ "tag": "xray-dual-vless", "listen": "0.0.0.0", "port": $port, "protocol": "vless", "settings": {"clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": ($domain + ":443"), "xver": 0, "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid]}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]} }'
}

build_ss_inbound() {
    local port="$1" password="$2"
    is_valid_port "$port" && validate_ss2022_password "$password" || return 1
    jq -n --argjson port "$port" --arg password "$password" \
    '{ "tag": "xray-dual-ss", "listen": "0.0.0.0", "port": $port, "protocol": "shadowsocks", "settings": {"method": "2022-blake3-aes-128-gcm", "password": $password} }'
}

generate_reality_keys() {
    local key_pair
    key_pair=$("$xray_binary_path" x25519) || return 1
    reality_private_key=$(awk '/PrivateKey:/ {print $2; exit}' <<<"$key_pair")
    reality_public_key=$(awk '/^Password( \(PublicKey\))?:/ {print $NF; exit}' <<<"$key_pair")
    [[ "$reality_private_key" =~ ^[A-Za-z0-9_-]{43}$ && "$reality_public_key" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

get_reality_public_key() {
    local inbound="$1" public private output
    public=$(jq -r '.streamSettings.realitySettings.publicKey // empty' <<< "$inbound") || return 1
    if [[ "$public" =~ ^[A-Za-z0-9_-]{43}$ ]]; then printf '%s\n' "$public"; return 0; fi
    private=$(jq -r '.streamSettings.realitySettings.privateKey // empty' <<< "$inbound") || return 1
    if [[ "$private" =~ ^[A-Za-z0-9_-]{43}$ ]] && output=$("$xray_binary_path" x25519 -i "$private" 2>/dev/null); then
        public=$(awk '/^Password( \(PublicKey\))?:/ {print $NF; exit}' <<< "$output")
        if [[ "$public" =~ ^[A-Za-z0-9_-]{43}$ ]]; then printf '%s\n' "$public"; return 0; fi
    fi
    error "Reality 公钥缺失且无法从私钥推导，未生成订阅。"
    return 1
}

get_managed_inbound() {
    local protocol="$1" config_file="${2:-$xray_config_path}" tag
    [[ -f "$config_file" ]] || return 0
    case "$protocol" in
        vless) tag="xray-dual-vless" ;;
        shadowsocks) tag="xray-dual-ss" ;;
        *) return 1 ;;
    esac
    jq -c --arg protocol "$protocol" --arg tag "$tag" 'first(.inbounds[]? | select(
        .tag == $tag or
        (.tag == null and .protocol == $protocol and .listen == "0.0.0.0" and
         (($protocol == "vless" and .settings.clients[0].flow == "xtls-rprx-vision" and .streamSettings.security == "reality" and .streamSettings.realitySettings.shortIds[0] == "20220701") or
          ($protocol == "shadowsocks" and .settings.method == "2022-blake3-aes-128-gcm")))
    ))' "$config_file" 2>/dev/null
}

normalize_version() {
    local version="$1"
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

render_config() {
    local existing_config="$1" inbounds_json="$2"
    jq -n --argjson inbounds "$inbounds_json" --argjson existing "$existing_config" '
    $existing
    | if ((.inbounds // []) | type) != "array" then error("inbounds must be an array") else . end
    | .inbounds = (((.inbounds // []) | map(select(
        .tag != "xray-dual-vless" and .tag != "xray-dual-ss" and
        ((.tag == null and .protocol == "vless" and .listen == "0.0.0.0" and .settings.clients[0].flow == "xtls-rprx-vision" and .streamSettings.security == "reality" and .streamSettings.realitySettings.shortIds[0] == "20220701") | not) and
        ((.tag == null and .protocol == "shadowsocks" and .listen == "0.0.0.0" and .settings.method == "2022-blake3-aes-128-gcm") | not)
    ))) + $inbounds)
    | .log = (.log // {"loglevel": "warning"})
    | .outbounds = (.outbounds // [{"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4v6"}}])'
}

write_config() {
    config_written=false
    config_backup=""
    local inbounds_json="$1"
    local config_content existing_config

    if [[ -f "$xray_config_path" ]]; then
        existing_config=$(<"$xray_config_path")
        if ! jq . >/dev/null 2>&1 <<<"$existing_config"; then
            error "现有 Xray 配置不是有效 JSON，已停止写入以避免覆盖。"
            return 1
        fi
    else
        existing_config='{}'
    fi

    # 只替换本脚本管理的 inbound，保留用户其它协议和顶层配置。
    if ! config_content=$(render_config "$existing_config" "$inbounds_json"); then
        error "现有配置结构无效，inbounds 必须是数组，已停止写入。"
        return 1
    fi

    if ! jq . >/dev/null 2>&1 <<<"$config_content"; then
        error "生成的配置文件格式错误！"
        return 1
    fi

    install -d -m 0755 "$(dirname "$xray_config_path")" || return 1
    local tmp_config
    tmp_config=$(mktemp "${xray_config_path}.tmp.XXXXXX.json") || return 1
    chmod 600 "$tmp_config" || return 1
    if ! printf '%s\n' "$config_content" > "$tmp_config"; then
        rm -f "$tmp_config"
        error "写入 Xray 配置文件失败！"
        return 1
    fi
    local test_log
    test_log=$(mktemp) || return 1
    if [[ -x "$xray_binary_path" ]] && ! "$xray_binary_path" run -test -config "$tmp_config" >"$test_log" 2>&1; then
        error "Xray 配置校验失败，未替换现有配置。"
        sed -n '1,40p' "$test_log" >&2 || true
        rm -f "$tmp_config" "$test_log"
        return 1
    fi
    rm -f "$test_log"

    local service_user service_group
    service_user=$(systemctl show xray -p User --value 2>/dev/null || true)
    [[ -n "$service_user" && "$service_user" != "-" ]] || service_user=nobody
    service_group=$(id -g -n "$service_user" 2>/dev/null || true)
    if [[ -n "$service_group" ]] && getent group "$service_group" >/dev/null; then
        if ! chown "root:$service_group" "$tmp_config" || ! chmod 640 "$tmp_config"; then
            rm -f "$tmp_config"
            error "设置 Xray 配置权限失败，未替换现有配置。"
            return 1
        fi
    elif ! chmod 600 "$tmp_config"; then
        rm -f "$tmp_config"
        error "设置 Xray 配置权限失败，未替换现有配置。"
        return 1
    fi

    # Each write owns its rollback material; never consume a previous .bak.
    if [[ -f "$xray_config_path" ]]; then
        config_backup=$(mktemp "${xray_config_path}.rollback.XXXXXX") || return 1
        if ! cp -p "$xray_config_path" "$config_backup"; then
            rm -f "$tmp_config" "$config_backup"
            config_backup=""
            return 1
        fi
        if ! cp -p "$config_backup" "${xray_config_path}.bak" || ! chmod 600 "${xray_config_path}.bak"; then
            rm -f "$tmp_config" "$config_backup"
            config_backup=""
            return 1
        fi
    fi
    if ! mv -f "$tmp_config" "$xray_config_path"; then
        rm -f "$tmp_config"
        [[ -z "$config_backup" ]] || rm -f "$config_backup"
        config_backup=""
        error "替换 Xray 配置失败，现有配置未改变。"
        return 1
    fi
    config_written=true
}

execute_official_script() {
    local script_file
    script_file=$(mktemp) || return 1

    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 120 "$xray_install_script_url" > "$script_file"; then
        error "下载 Xray 官方安装脚本失败或内容异常！请检查网络连接。"
        rm -f "$script_file"
        return 1
    fi
    if ! printf '%s  %s\n' "$xray_install_script_sha256" "$script_file" | sha256sum -c --status; then
        error "下载的 Xray 安装脚本校验失败，已拒绝执行。"
        rm -f "$script_file"
        return 1
    fi

    local result=0
    bash "$script_file" "$@" >/dev/null 2>&1 || result=$?
    rm -f "$script_file"
    if (( result != 0 )); then
        return 1
    fi
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    # --without-geodata: 官方 install 默认已含 geodata 下载，与下方
    # install-geodata 重复；统一由 install-geodata 负责，失败即终止。
    if ! execute_official_script "install" "--without-geodata" "$@"; then
        error "Xray 核心安装失败！"
        return 1
    fi

    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    if ! execute_official_script "install-geodata"; then
        error "Geo-data 更新失败！"
        error "GeoIP/GeoSite 是安装和更新所需的数据文件，已终止流程。"
        return 1
    fi

    success "Xray 核心及数据文件已准备就绪。"
}

# --- 输入验证与交互函数 (优化) ---
is_valid_port() {
    local port="$1"
    # 拒绝前导 0：避免 bash 八进制解析与 jq --argjson 非法数字
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 ))
}

is_port_available() {
    local port="$1"
    is_valid_port "$port" || return 1
    if ! command -v ss >/dev/null 2>&1; then
        error "缺少 ss 命令，无法检测端口占用。请安装 iproute2。"
        return 1
    fi

    # 检查端口是否被占用 (TCP/UDP; SS-2022 同时使用两者)
    if ss -tlpn 2>/dev/null | grep -q ":$port " || ss -ulpn 2>/dev/null | grep -q ":$port "; then
        warning "端口 $port 已被占用，建议选择其他端口"
        return 1
    fi
    return 0
}

# 端口可用，或与当前托管 inbound 端口相同（覆盖重装场景）
is_port_available_for() {
    local port="$1" protocol="$2" current
    is_valid_port "$port" || return 1
    current=$(get_managed_inbound "$protocol" 2>/dev/null | jq -r '.port // empty' 2>/dev/null) || return 1
    [[ -n "$current" && "$port" == "$current" ]] && return 0
    is_port_available "$port"
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

is_valid_uuid() {
    [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[1-5][[:xdigit:]]{3}-[89abAB][[:xdigit:]]{3}-[[:xdigit:]]{12}$ ]]
}

validate_ss2022_password() {
    local password="$1"
    # aes-128-gcm requires 16 bytes, represented by 24 standard Base64 chars.
    [[ "$password" =~ ^[A-Za-z0-9+/]{22}==$ ]]
}

validate_distinct_ports() {
    if ! is_valid_port "$1" || ! is_valid_port "$2"; then error "端口无效。"; return 1; fi
    [[ "$1" != "$2" ]] || { error "VLESS 和 Shadowsocks 不能使用相同端口。"; return 1; }
}

prompt_for_vless_config() {
    local -n p_port="$1" p_uuid="$2" p_sni="$3"
    local default_port="${4:-443}"

    while true; do
        read -r -p " -> VLESS 端口 (默认: ${cyan}${default_port}${none}): " p_port || return 1
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available_for "$p_port" vless; then break; fi
    done
    info "VLESS 端口将使用: ${cyan}${p_port}${none}"

    read -r -p " -> 请输入UUID (留空将自动生成): " p_uuid || return 1
    if [[ -z "$p_uuid" ]]; then
        p_uuid=$(< /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${p_uuid}${none}"
    elif ! is_valid_uuid "$p_uuid"; then
        error "UUID 格式无效，请重新运行安装并输入标准 UUID。"
        return 1
    fi

    info "SNI 填服务器可达的 TLS 1.3 域名，不含协议或路径；无需自有域名或证书。"
    while true; do
        read -r -p " -> Reality 目标域名/SNI (默认: ${cyan}www.sega.com${none}): " p_sni || return 1
        [[ -z "$p_sni" ]] && p_sni="www.sega.com"
        if is_valid_domain "$p_sni"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    info "SNI 域名将使用: ${cyan}${p_sni}${none}"
}

prompt_for_ss_config() {
    local -n p_port="$1" p_pass="$2"
    local default_port="${3:-8388}"

    while true; do
        read -r -p " -> SS 端口 (默认: ${cyan}${default_port}${none}): " p_port || return 1
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available_for "$p_port" shadowsocks; then break; fi
    done
    info "Shadowsocks 端口将使用: ${cyan}${p_port}${none}"

    info "加密方式: 2022-blake3-aes-128-gcm；密钥为 16 字节的标准 Base64（24 字符，以 == 结尾）。"
    read -r -p " -> SS 密钥 (留空随机生成): " p_pass || return 1
    if [[ -z "$p_pass" ]]; then
        p_pass=$(generate_ss_key) || return 1
        info "已生成 SS 密钥:"
        printf " %s\n" "$p_pass"
    elif ! validate_ss2022_password "$p_pass"; then
        error "SS-2022 密钥必须是 16 字节密钥对应的标准 Base64（24 个字符，通常以 == 结尾）。"
        return 1
    fi
}

# --- 菜单功能函数 ---
draw_divider() {
    printf '%s\n' "────────────────────────────────────"
}

draw_menu_header() {
    if [[ -n "$cyan" ]]; then clear 2>/dev/null || true; fi
    printf '%b\n' "${cyan} Xray Reality + SS-2022 管理脚本${none}"
    printf '%b\n' "${yellow} Version: ${SCRIPT_VERSION}${none}"
    draw_divider
    check_xray_status
    printf '%b\n' "${xray_status_info}"
    draw_divider
}

press_any_key_to_continue() {
    echo ""
    read -n 1 -s -r -p " 按任意键返回主菜单..." || return 1
}

install_menu() {
    local vless_exists="" ss_exists=""
    if [[ -f "$xray_config_path" ]]; then
        vless_exists=$(get_managed_inbound vless) || return 1
        ss_exists=$(get_managed_inbound shadowsocks) || return 1
    fi

    draw_menu_header
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "您已安装 VLESS-Reality + Shadowsocks-2022 双协议。"
        info '如需修改，请使用主菜单的“修改配置”选项。\n如需重装，请先“卸载”后，再重新“安装”。'
        return
    elif [[ -n "$vless_exists" && -z "$ss_exists" ]]; then
        info "检测到您已安装 VLESS-Reality"
        printf '%b\n' "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %s\n" "1." "添加 SS-2022 (保留 VLESS)"
        printf "  ${red}%-2s${none} %s\n" "2." "覆盖重装 VLESS-Reality"
        draw_divider
        printf "  ${yellow}%-2s${none} %s\n" "0." "返回主菜单"
        draw_divider
        read -r -p " 请输入选项 [0-2]: " choice || return 1
        case "$choice" in 1) add_ss_to_vless ;; 2) install_vless_only ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -z "$vless_exists" && -n "$ss_exists" ]]; then
        info "检测到您已安装 Shadowsocks-2022"
        printf '%b\n' "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %s\n" "1." "添加 VLESS-Reality (保留 SS)"
        printf "  ${red}%-2s${none} %s\n" "2." "覆盖重装 Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %s\n" "0." "返回主菜单"
        draw_divider
        read -r -p " 请输入选项 [0-2]: " choice || return 1
        case "$choice" in 1) add_vless_to_ss ;; 2) install_ss_only ;; 0) return ;; *) error "无效选项。" ;; esac
    else
        clean_install_menu
    fi
}

clean_install_menu() {
    draw_menu_header
    printf '%b\n' "${cyan} 请选择要安装的协议类型${none}"
    info "Reality 提供 TLS 伪装，SS-2022 使用预共享密钥；客户端须支持所选协议，双协议用独立端口分别连接。"
    draw_divider
    printf "  ${green}%-2s${none} %s\n" "1." "仅 VLESS-Reality"
    printf "  ${cyan}%-2s${none} %s\n" "2." "仅 Shadowsocks-2022"
    printf "  ${yellow}%-2s${none} %s\n" "3." "VLESS-Reality + SS-2022 双协议"
    draw_divider
    printf "  ${magenta}%-2s${none} %s\n" "0." "返回主菜单"
    draw_divider
    read -r -p " 请输入选项 [0-3]: " choice || return 1
    case "$choice" in 1) install_vless_only ;; 2) install_ss_only ;; 3) install_dual ;; 0) return ;; *) error "无效选项。" ;; esac
}

add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi
    local vless_inbound vless_port default_ss_port ss_port ss_password ss_inbound
    vless_inbound=$(get_managed_inbound vless) || return 1
    vless_port=$(jq -r '.port' <<< "$vless_inbound") || return 1
    is_valid_port "$vless_port" || { error "现有 VLESS 端口无效。"; return 1; }
    if [[ "$vless_port" -ge 65535 ]]; then
        error "VLESS 使用 65535 端口时无法自动分配 SS 端口，请手动修改配置或使用低于 65535 的端口。"
        return 1
    fi
    default_ss_port=$([[ "$vless_port" == "443" ]] && echo "8388" || echo "$((vless_port + 1))")

    prompt_for_ss_config ss_port ss_password "$default_ss_port" || return 1
    validate_distinct_ports "$vless_port" "$ss_port" || return 1

    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password") || return 1
    write_config "[$vless_inbound, $ss_inbound]" || return 1

    apply_config_and_restart || return 1

    success "追加安装成功！"
    view_all_info
}

add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi
    local ss_inbound ss_port default_vless_port vless_port vless_uuid vless_domain private_key public_key vless_inbound
    ss_inbound=$(get_managed_inbound shadowsocks) || return 1
    ss_port=$(jq -r '.port' <<<"$ss_inbound") || return 1
    is_valid_port "$ss_port" || { error "现有 SS 端口无效。"; return 1; }
    default_vless_port=$([[ "$ss_port" == "8388" || "$ss_port" -le 1 ]] && echo "443" || echo "$((ss_port - 1))")

    prompt_for_vless_config vless_port vless_uuid vless_domain "$default_vless_port" || return 1
    validate_distinct_ports "$vless_port" "$ss_port" || return 1

    info "正在生成 Reality 密钥对..."
    if ! generate_reality_keys; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        return 1
    fi
    private_key="$reality_private_key"
    public_key="$reality_public_key"
    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key") || return 1
    write_config "[$vless_inbound, $ss_inbound]" || return 1

    apply_config_and_restart || return 1

    success "追加安装成功！"
    view_all_info
}

install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain default_port
    default_port=$(get_managed_inbound vless 2>/dev/null | jq -r '.port // empty' 2>/dev/null) || return 1
    [[ -n "$default_port" ]] || default_port=443
    prompt_for_vless_config port uuid domain "$default_port" || return 1
    run_install_vless "$port" "$uuid" "$domain"
}

install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password default_port
    default_port=$(get_managed_inbound shadowsocks 2>/dev/null | jq -r '.port // empty' 2>/dev/null) || return 1
    [[ -n "$default_port" ]] || default_port=8388
    prompt_for_ss_config port password "$default_port" || return 1
    run_install_ss "$port" "$password"
}

install_dual() {
    info "开始配置双协议 (VLESS-Reality + Shadowsocks-2022)..."
    local vless_port vless_uuid vless_domain ss_port ss_password
    prompt_for_vless_config vless_port vless_uuid vless_domain || return 1

    local default_ss_port
    if [[ "$vless_port" == "443" ]]; then
        default_ss_port=8388
    elif [[ "$vless_port" -ge 65535 ]]; then
        error "VLESS 使用 65535 端口时无法自动分配 SS 端口，请使用低于 65535 的 VLESS 端口。"
        return 1
    else
        default_ss_port=$((vless_port + 1))
    fi

    prompt_for_ss_config ss_port ss_password "$default_ss_port" || return 1

    validate_distinct_ports "$vless_port" "$ss_port" || return 1

    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在检查最新版本..."
    local current_version latest_version
    current_version=$("$xray_binary_path" version 2>/dev/null | awk 'NR == 1 {print $2; exit}' || true)
    current_version=$(normalize_version "$current_version" || true)
    latest_version=$(curl --fail --silent --show-error --location --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | jq -er '.tag_name // empty' || true)
    latest_version=$(normalize_version "$latest_version" || true)
    if [[ -z "$current_version" || -z "$latest_version" ]]; then
        error "获取最新版本号失败，请检查网络或稍后重试。"
        return 1
    fi
    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"

    if [[ "$current_version" == "$latest_version" ]]; then
        success "您的 Xray 已是最新版本。"
        return 0
    fi

    # The pinned installer can stop/start Xray itself, including on failure.
    # Snapshot only the files it may replace; preserve the prior running state.
    local backup path index=0 failed=false was_active=false changed=false
    local paths=("$xray_binary_path" /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat)
    systemctl is-active --quiet xray && was_active=true
    backup=$(mktemp -d /var/tmp/xray-update.XXXXXX) || return 1
    for path in "${paths[@]}"; do
        if [[ -e "$path" ]]; then
            if ! cp -p "$path" "$backup/$index"; then
                rm -rf "$backup"
                error "更新前备份失败，未调用安装器。"
                return 1
            fi
        fi
        index=$((index + 1))
    done
    info "开始更新；官方安装器可能停止或启动服务。"
    # Keep existing units/drop-ins outside this file-only rollback transaction.
    run_core_install --no-update-service || failed=true
    if [[ "$failed" == false && -f "$xray_config_path" ]]; then
        "$xray_binary_path" run -test -config "$xray_config_path" || failed=true
    fi
    if [[ "$failed" == false ]]; then
        if "$was_active"; then
            restart_xray || failed=true
        else
            systemctl stop xray || failed=true
            if systemctl is-active --quiet xray; then failed=true; fi
        fi
    fi
    if [[ "$failed" == false ]]; then
        rm -rf "$backup"
        success "Xray 更新成功，已保持更新前的运行/停止状态。"
        return 0
    fi
    index=0
    for path in "${paths[@]}"; do
        if [[ -f "$backup/$index" ]]; then
            cmp -s "$backup/$index" "$path" || changed=true
        elif [[ -e "$path" ]]; then
            changed=true
        fi
        index=$((index + 1))
    done
    local restored=true active_now=false
    systemctl is-active --quiet xray && active_now=true
    if "$changed"; then
        systemctl stop xray || restored=false
        if "$restored"; then
            index=0
            for path in "${paths[@]}"; do
                if [[ -f "$backup/$index" ]]; then
                    # Atomic replacement avoids writing into a running executable.
                    if ! cp -p "$backup/$index" "${path}.restore" || ! mv -f "${path}.restore" "$path"; then
                        restored=false
                    fi
                else
                    rm -f "$path" || restored=false
                fi
                index=$((index + 1))
            done
        fi
    fi
    if "$restored" && { "$changed" || [[ "$active_now" != "$was_active" ]]; }; then
        if "$was_active"; then restart_xray || restored=false
        else systemctl stop xray || restored=false; fi
    fi
    if "$restored"; then
        active_now=false
        systemctl is-active --quiet xray && active_now=true
        [[ "$active_now" == "$was_active" ]] || restored=false
    fi
    if "$restored"; then
        rm -rf "$backup"
        error "更新失败，已恢复核心、数据和原服务状态（安装器可能曾重启服务）。"
    else
        error "更新失败且恢复未完成，恢复材料保留在: $backup"
    fi
    return 1
}

uninstall_xray() {
    local subscription_file=/root/xray_subscription_info.txt
    if [[ ! -f "$xray_binary_path" && ! -f "$xray_config_path" &&
          ! -f "${xray_config_path}.bak" && ! -f "$subscription_file" &&
          ! -f /etc/systemd/system/xray.service ]]; then
        info "Xray 未安装，无需卸载。"
        return 0
    fi
    warning "将卸载整个 Xray（所有协议），清除全部配置、备份、订阅及日志，含自定义内容。"
    read -r -p "${yellow}确认卸载？[y/N，回车取消]: ${none}" confirm || return 1
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "操作已取消。"
        return
    fi
    info "正在卸载 Xray..."
    if ! execute_official_script remove --purge; then
        error "Xray 卸载失败！"
        return 1
    fi
    # --purge removes files managed by the official installer. Remove this
    # script's configuration, backup, subscription and temporary leftovers too.
    if ! rm -rf -- \
        "$xray_config_path" "${xray_config_path}.bak" \
        "${xray_config_path}".tmp.* \
        "$subscription_file"; then
        error "Xray 卸载清理未完成，请检查残留配置、备份和订阅文件。"
        return 1
    fi
    find "$(dirname "$xray_config_path")" -maxdepth 1 -type d -empty -delete 2>/dev/null || true
    success "Xray 已成功卸载，相关配置、备份、日志和临时文件已清理。"
}

modify_config_menu() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装。" && return; fi

    local vless_exists="" ss_exists=""
    vless_exists=$(get_managed_inbound vless) || return 1
    ss_exists=$(get_managed_inbound shadowsocks) || return 1

    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        draw_menu_header
        printf '%b\n' "${cyan} 请选择要修改的协议配置${none}"
        draw_divider
        printf "  ${green}%-2s${none} %s\n" "1." "VLESS-Reality"
        printf "  ${cyan}%-2s${none} %s\n" "2." "Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %s\n" "0." "返回主菜单"
        draw_divider
        read -r -p " 请输入选项 [0-2]: " choice || return 1
        case "$choice" in 1) modify_vless_config ;; 2) modify_ss_config ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -n "$vless_exists" ]]; then
        draw_menu_header
        printf '%b\n' "${cyan} 请选择要修改的操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %s\n" "1." "修改 VLESS-Reality"
        printf "  ${cyan}%-2s${none} %s\n" "2." "添加 Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %s\n" "0." "返回主菜单"
        draw_divider
        read -r -p " 请输入选项 [0-2]: " choice || return 1
        case "$choice" in
            1) modify_vless_config ;;
            2) add_ss_to_vless ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
    elif [[ -n "$ss_exists" ]]; then
        draw_menu_header
        printf '%b\n' "${cyan} 请选择要修改的操作${none}"
        draw_divider
        printf "  ${cyan}%-2s${none} %s\n" "1." "修改 Shadowsocks-2022"
        printf "  ${green}%-2s${none} %s\n" "2." "添加 VLESS-Reality"
        draw_divider
        printf "  ${yellow}%-2s${none} %s\n" "0." "返回主菜单"
        draw_divider
        read -r -p " 请输入选项 [0-2]: " choice || return 1
        case "$choice" in
            1) modify_ss_config ;;
            2) add_vless_to_ss ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
    else
        error "未找到可修改的协议配置。"
    fi
}

modify_vless_config() {
    info "开始修改 VLESS-Reality 配置..."
    local vless_inbound current_port current_uuid current_domain private_key public_key port uuid domain new_vless_inbound ss_inbound new_inbounds
    vless_inbound=$(get_managed_inbound vless) || return 1
    current_port=$(jq -r '.port' <<<"$vless_inbound") || return 1
    current_uuid=$(jq -r '.settings.clients[0].id' <<<"$vless_inbound") || return 1
    current_domain=$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<<"$vless_inbound") || return 1
    private_key=$(jq -r '.streamSettings.realitySettings.privateKey' <<<"$vless_inbound") || return 1
    public_key=$(get_reality_public_key "$vless_inbound") || return 1

    while true; do
        read -r -p " -> 端口 [当前 ${cyan}${current_port}${none}，留空不改]: " port || return 1
        [[ -z "$port" ]] && port=$current_port
        if is_valid_port "$port" && { [[ "$port" == "$current_port" ]] || is_port_available "$port"; }; then break; fi
    done

    printf " 当前 UUID: %s\n" "$current_uuid"
    read -r -p " -> 新 UUID (留空不改): " uuid || return 1
    [[ -z "$uuid" ]] && uuid=$current_uuid
    is_valid_uuid "$uuid" || { error "UUID 格式无效。"; return 1; }

    printf " 当前 Reality 目标域名/SNI: %s\n" "$current_domain"
    info "SNI 填服务器可达的 TLS 1.3 域名，不含协议或路径；无需自有域名或证书。"
    while true; do
        read -r -p " -> 新目标域名/SNI (留空不改): " domain || return 1
        [[ -z "$domain" ]] && domain=$current_domain
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done

    ss_inbound=$(get_managed_inbound shadowsocks) || return 1
    [[ -z "$ss_inbound" ]] || validate_distinct_ports "$port" "$(jq -r '.port' <<<"$ss_inbound")" || return 1
    new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key") || return 1
    new_inbounds="[$new_vless_inbound]"
    [[ -n "$ss_inbound" ]] && new_inbounds="[$new_vless_inbound, $ss_inbound]"

    write_config "$new_inbounds" || return 1
    apply_config_and_restart || return 1

    success "配置修改成功！"
    view_all_info
}

modify_ss_config() {
    info "开始修改 Shadowsocks-2022 配置..."
    local ss_inbound current_port current_password port password new_ss_inbound vless_inbound new_inbounds
    ss_inbound=$(get_managed_inbound shadowsocks) || return 1
    current_port=$(jq -r '.port' <<<"$ss_inbound") || return 1
    current_password=$(jq -r '.settings.password' <<<"$ss_inbound") || return 1

    while true; do
        read -r -p " -> 端口 [当前 ${cyan}${current_port}${none}，留空不改]: " port || return 1
        [[ -z "$port" ]] && port=$current_port
        if is_valid_port "$port" && { [[ "$port" == "$current_port" ]] || is_port_available "$port"; }; then break; fi
    done

    printf " 当前密钥:\n %s\n" "$current_password"
    info "加密方式: 2022-blake3-aes-128-gcm；密钥为 16 字节的标准 Base64（24 字符，以 == 结尾）。"
    read -r -p " -> 新密钥 (留空不改): " password || return 1
    [[ -z "$password" ]] && password=$current_password
    if ! validate_ss2022_password "$password"; then
        error "SS-2022 密钥必须是 16 字节密钥对应的标准 Base64（24 个字符，通常以 == 结尾）。"
        return 1
    fi

    vless_inbound=$(get_managed_inbound vless) || return 1
    [[ -z "$vless_inbound" ]] || validate_distinct_ports "$(jq -r '.port' <<<"$vless_inbound")" "$port" || return 1
    new_ss_inbound=$(build_ss_inbound "$port" "$password") || return 1
    new_inbounds="[$new_ss_inbound]"
    [[ -n "$vless_inbound" ]] && new_inbounds="[$vless_inbound, $new_ss_inbound]"

    write_config "$new_inbounds" || return 1
    apply_config_and_restart || return 1

    success "配置修改成功！"
    view_all_info
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return 1; fi

    info "正在重启 Xray 服务..."
    if ! systemctl restart xray; then
        error "尝试重启 Xray 服务失败！"
        # 新增：显示详细错误信息
        printf '%b\n' "\n${yellow}错误详情:${none}"
        systemctl status xray --no-pager -l | tail -5 || true
        return 1
    fi

    # 等待时间稍微延长，确保服务完全启动
    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
    else
        error "服务启动失败，详细信息:"
        systemctl status xray --no-pager -l | tail -5 || true
        return 1
    fi
}

apply_config_and_restart() {
    [[ "$config_written" == true ]] || return 1
    info "应用配置将重启整个 Xray，影响所有协议。"
    if restart_xray; then
        [[ -z "$config_backup" ]] || rm -f "$config_backup"
        config_backup=""
        config_written=false
        return 0
    fi
    warning "新配置未能启动，正在恢复旧配置..."
    if rollback_config_and_restart; then
        error "新配置启动失败，已恢复旧配置。"
    else
        error "新配置和旧配置均无法启动，请检查 ${xray_config_path}.bak"
    fi
    return 1
}

rollback_config_and_restart() {
    [[ "$config_written" == true ]] || return 1
    config_written=false
    if [[ -z "$config_backup" ]]; then
        rm -f "$xray_config_path" || return 1
        systemctl stop xray || return 1
        return 0
    fi
    if ! cp -p "$config_backup" "$xray_config_path" || ! restart_xray; then
        error "恢复失败，保留恢复材料: $config_backup"
        return 1
    fi
    rm -f "$config_backup" || return 1
    config_backup=""
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

generate_ss_url() {
    local ip_address="$1"
    local port="$2"
    local password="$3"
    local method="$4"
    local node_name="$5"
    local encoded_userinfo encoded_name display_ip

    # SIP002: URL-safe Base64(method:password), outer padding omitted.
    encoded_userinfo=$(printf '%s' "$method:$password" | base64 -w0 | tr '+/' '-_' | tr -d '=') || return 1
    encoded_name=$(printf '%s' "$node_name" | jq -sRr @uri) || return 1
    display_ip="$ip_address"
    [[ "$display_ip" == *:* ]] && display_ip="[$display_ip]"
    printf 'ss://%s@%s:%s#%s\n' \
        "$encoded_userinfo" "$display_ip" "$port" "$encoded_name"
}

view_all_info() {
    if [ ! -f "$xray_config_path" ]; then
        error "错误: 配置文件不存在。"
        return
    fi

    if [[ -n "$cyan" ]]; then clear 2>/dev/null || true; fi
    printf '%b\n' "${cyan} Xray 配置及订阅信息${none}"
    draw_divider

    local ip
    if ! ip=$(get_public_ip); then
        error "无法获取公网 IP 地址。"
        return 1
    fi
    local host
    host=$(hostname) || return 1
    local links_array=()
    local subscription_file="/root/xray_subscription_info.txt"

    local vless_inbound
    vless_inbound=$(get_managed_inbound vless) || return 1
    if [[ -n "$vless_inbound" ]]; then
        local uuid port domain public_key shortid display_ip link_name_raw link_name_encoded vless_url
        uuid=$(jq -r '.settings.clients[0].id' <<<"$vless_inbound") || return 1
        port=$(jq -r '.port' <<<"$vless_inbound") || return 1
        domain=$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<<"$vless_inbound") || return 1
        public_key=$(get_reality_public_key "$vless_inbound") || return 1
        shortid=$(jq -r '.streamSettings.realitySettings.shortIds[0]' <<<"$vless_inbound") || return 1

        if [[ -z "$public_key" ]]; then
            error "VLESS配置不完整，可能已损坏。"
        else
            display_ip=$ip && [[ "$ip" =~ ":" ]] && display_ip="[$ip]"
            link_name_raw="$host X-reality"
            link_name_encoded=$(printf '%s' "$link_name_raw" | jq -sRr @uri) || return 1
            vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
            links_array+=("$vless_url")

            printf '%b\n' "${green} [ VLESS-Reality 配置 ]${none}"
            printf "    %s: ${cyan}%s${none}\n" "节点名称" "$link_name_raw"
            printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
            printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
            printf "    %s: ${cyan}%s${none}\n" "UUID" "${uuid}"
            printf "    %s: ${cyan}%s${none}\n" "加密" "none"
            printf "    %s: ${cyan}%s${none}\n" "流控" "xtls-rprx-vision"
            printf "    %s: ${cyan}%s${none}\n" "传输协议" "tcp"
            printf "    %s: ${cyan}%s${none}\n" "安全类型" "reality"
            printf "    %s: ${cyan}%s${none}\n" "SNI" "$domain"
            printf "    %s: ${cyan}%s${none}\n" "指纹" "chrome"
            printf "    %s: ${cyan}%s${none}\n" "PublicKey" "${public_key}"
            printf "    %s: ${cyan}%s${none}\n" "ShortId" "$shortid"
        fi
    fi

    local ss_inbound
    ss_inbound=$(get_managed_inbound shadowsocks) || return 1
    if [[ -n "$ss_inbound" ]]; then
        local port method password ss_url
        port=$(jq -r '.port' <<<"$ss_inbound") || return 1
        method=$(jq -r '.settings.method' <<<"$ss_inbound") || return 1
        password=$(jq -r '.settings.password' <<<"$ss_inbound") || return 1
        link_name_raw="$host X-ss2022"
        ss_url=$(generate_ss_url "$ip" "$port" "$password" "$method" "$link_name_raw") || return 1
        links_array+=("$ss_url")

        echo ""
        printf '%b\n' "${green} [ Shadowsocks-2022 配置 ]${none}"
        printf "    %s: ${cyan}%s${none}\n" "节点名称" "$link_name_raw"
        printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
        printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
        printf "    %s: ${cyan}%s${none}\n" "加密方式" "$method"
        printf "    %s: ${cyan}%s${none}\n" "密码" "${password}"
    fi

    if [ ${#links_array[@]} -gt 0 ]; then
        draw_divider
        local subscription_tmp
        subscription_tmp=$(mktemp "${subscription_file}.XXXXXX") || return 1
        if ! printf "%s\n" "${links_array[@]}" > "$subscription_tmp" ||
           ! chmod 600 "$subscription_tmp" || ! mv -f "$subscription_tmp" "$subscription_file"; then
            rm -f "$subscription_tmp"
            error "保存订阅失败。"
            return 1
        fi
        success "所有订阅链接已汇总保存到: $subscription_file"
        printf '%b\n\n' "\n${yellow} --- V2Ray / Clash 等客户端可直接导入以下链接 --- ${none}"
        for link in "${links_array[@]}"; do
            printf '%b\n\n' "${cyan}${link}${none}"
        done
        draw_divider
    else
        info "当前未安装任何协议，无订阅信息可显示。"
    fi
}

# --- 核心安装逻辑函数 ---
run_install_vless() {
    local port="$1" uuid="$2" domain="$3"
    is_port_available_for "$port" vless || return 1
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        return 1
    fi
    run_core_install || return 1
    info "正在生成 Reality 密钥对..."
    local private_key public_key vless_inbound
    if ! generate_reality_keys; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        return 1
    fi
    private_key="$reality_private_key"
    public_key="$reality_public_key"

    vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key") || return 1
    # 合并保留已存在的 Shadowsocks managed inbound（与交互"追加"语义一致），避免单协议安装擦除另一协议
    local existing_ss_inbound
    existing_ss_inbound=$(get_managed_inbound shadowsocks) || return 1
    if [[ -n "$existing_ss_inbound" ]]; then
        write_config "[$vless_inbound, $existing_ss_inbound]" || return 1
    else
        write_config "[$vless_inbound]" || return 1
    fi

    apply_config_and_restart || return 1

    success "VLESS-Reality 安装成功！"
    view_all_info
}

run_install_ss() {
    local port="$1" password="$2"
    is_port_available_for "$port" shadowsocks || return 1
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        return 1
    fi
    run_core_install || return 1
    local ss_inbound existing_vless_inbound
    ss_inbound=$(build_ss_inbound "$port" "$password") || return 1
    # 合并保留已存在的 VLESS managed inbound，避免单协议安装擦除另一协议
    existing_vless_inbound=$(get_managed_inbound vless) || return 1
    if [[ -n "$existing_vless_inbound" ]]; then
        write_config "[$existing_vless_inbound, $ss_inbound]" || return 1
    else
        write_config "[$ss_inbound]" || return 1
    fi

    apply_config_and_restart || return 1

    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

run_install_dual() {
    local vless_port="$1" vless_uuid="$2" vless_domain="$3" ss_port="$4" ss_password="$5"
    validate_distinct_ports "$vless_port" "$ss_port" || return 1
    is_port_available_for "$vless_port" vless || return 1
    is_port_available_for "$ss_port" shadowsocks || return 1
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        return 1
    fi
    run_core_install || return 1
    info "正在生成 Reality 密钥对..."
    local private_key public_key vless_inbound ss_inbound
    if ! generate_reality_keys; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        return 1
    fi
    private_key="$reality_private_key"
    public_key="$reality_public_key"

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key") || return 1
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password") || return 1
    write_config "[$vless_inbound, $ss_inbound]" || return 1

    apply_config_and_restart || return 1

    success "双协议安装成功！"
    view_all_info
}

# --- 主菜单与脚本入口 ---
main_menu() {
    while true; do
        draw_menu_header
        printf "  ${green}%-2s${none} %s\n" "1." "安装 Xray"
        printf "  ${cyan}%-2s${none} %s\n" "2." "更新 Xray"
        printf "  ${red}%-2s${none} %s\n" "3." "卸载 Xray"
        draw_divider
        printf "  ${yellow}%-2s${none} %s\n" "4." "修改配置"
        printf "  ${cyan}%-2s${none} %s\n" "5." "重启 Xray"
        printf "  ${magenta}%-2s${none} %s\n" "6." "查看 Xray 日志"
        printf "  ${green}%-2s${none} %s\n" "7." "查看订阅信息"
        draw_divider
        printf "  ${yellow}%-2s${none} %s\n" "0." "退出脚本"
        draw_divider

        read -r -p " 请输入选项 [0-7]: " choice || return 0

        local needs_pause=true

        case "$choice" in
            1) install_menu || true ;;
            2) update_xray || true ;;
            3) uninstall_xray || true ;;
            4) modify_config_menu || true ;;
            5) restart_xray || true ;;
            6) view_xray_log || true; needs_pause=false ;;
            7) view_all_info || true ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项。请输入0到7之间的数字。" ;;
        esac

        if [ "$needs_pause" = true ]; then
            press_any_key_to_continue || return 0
        fi
    done
}

# --- 非交互式安装逻辑 ---
non_interactive_usage() {
    cat << EOF

非交互式安装用法:
  ./$(basename "$0") install --type <vless|ss|dual> [选项...]

  通用选项:
    --type <type>      安装类型 (必须: vless=VLESS-Reality, ss=Shadowsocks-2022, dual=双协议)
    -h, --help         显示本帮助

  VLESS 选项:
    --vless-port <p>   VLESS 端口 (默认: 443)
    --uuid <uuid>      UUID (默认: 随机生成)
    --sni <domain>     Reality 目标域名/SNI (默认: www.sega.com)

  Shadowsocks 选项:
    --ss-port <p>      Shadowsocks 端口 (默认: 8388；dual 且 VLESS 非 443 时为 VLESS 端口 + 1)
    --ss-pass <pass>   16 字节标准 Base64 密钥 (24 字符，以 == 结尾；默认随机生成)
                      加密方式: 2022-blake3-aes-128-gcm

  端口须为 1-65535 的十进制整数，无前导零；双协议端口不能相同。
  dual 且 VLESS 端口为 65535 时必须显式指定 --ss-port。
  单协议安装会覆盖该协议配置、保留另一协议；dual 会重配两个托管协议。

  示例:
    # 安装 VLESS (使用默认值)
    ./$(basename "$0") install --type vless

    # 安装双协议并指定 VLESS 端口和 UUID
    ./$(basename "$0") install --type dual --vless-port 2053 --uuid 'your-uuid-here'
EOF
}

non_interactive_dispatcher() {
    if [[ $# -eq 0 ]]; then
        pre_check || return 1
        if [[ ! -t 0 ]]; then
            error "交互式菜单需要终端。非交互安装用法: install --type <vless|ss|dual>"
            non_interactive_usage
            exit 1
        fi
        main_menu
        return
    fi
    [[ "$1" == install ]] || { error "未知参数: $1"; return 2; }
    shift

    local type="" vless_port="" uuid="" sni="" ss_port="" ss_pass="" help=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                help=true
                shift ;;
            --type|--vless-port|--uuid|--sni|--ss-port|--ss-pass)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || {
                    error "参数 $1 缺少有效值。"
                    non_interactive_usage
                    exit 2
                }
                case "$1" in
                    --type) type="$2" ;; --vless-port) vless_port="$2" ;;
                    --uuid) uuid="$2" ;; --sni) sni="$2" ;;
                    --ss-port) ss_port="$2" ;; --ss-pass) ss_pass="$2" ;;
                esac
                shift 2 ;;
            *) error "未知参数: $1"; non_interactive_usage; exit 2 ;;
        esac
    done

    if "$help"; then non_interactive_usage; return 0; fi
    case "$type" in vless|ss|dual) ;; *) error "必须指定有效 --type"; return 2 ;; esac
    pre_check || return 1

    case "$type" in
        vless)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(< /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="www.sega.com"
            if ! is_valid_port "$vless_port" || ! is_valid_uuid "$uuid" || ! is_valid_domain "$sni"; then
                error "VLESS 参数无效。请检查端口、UUID 或 SNI 域名。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装 VLESS..."
            run_install_vless "$vless_port" "$uuid" "$sni"
            ;;
        ss)
            [[ -z "$ss_port" ]] && ss_port=8388
            if [[ -z "$ss_pass" ]]; then ss_pass=$(generate_ss_key) || return 1; fi
            if ! is_valid_port "$ss_port" || ! validate_ss2022_password "$ss_pass"; then
                error "Shadowsocks 参数无效。请检查端口或 SS 密钥。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装 Shadowsocks..."
            run_install_ss "$ss_port" "$ss_pass"
            ;;
        dual)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(< /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="www.sega.com"
            if [[ -z "$ss_pass" ]]; then ss_pass=$(generate_ss_key) || return 1; fi
            is_valid_port "$vless_port" || { error "VLESS 端口无效。"; return 1; }
            if [[ -z "$ss_port" ]]; then
                if [[ "$vless_port" == "443" ]]; then
                    ss_port=8388
                elif [[ "$vless_port" -lt 65535 ]]; then
                    ss_port=$((vless_port + 1))
                else
                    error "VLESS 使用 65535 端口时必须显式指定 --ss-port。"
                    non_interactive_usage
                    exit 1
                fi
            fi
            if ! is_valid_port "$vless_port" || ! is_valid_uuid "$uuid" || ! is_valid_domain "$sni" || ! is_valid_port "$ss_port" || ! validate_ss2022_password "$ss_pass" || ! validate_distinct_ports "$vless_port" "$ss_port"; then
                error "双协议参数无效。请检查端口、UUID、SNI 域名或 SS 密钥。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装双协议..."
            run_install_dual "$vless_port" "$uuid" "$sni" "$ss_port" "$ss_pass"
            ;;
        *)
            error "必须通过 --type 指定安装类型 (vless|ss|dual)"
            non_interactive_usage
            exit 2
            ;;
    esac
}

# --- 脚本主入口 ---
main() {
    if [[ $# -gt 0 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
        if [[ $# -ne 1 ]]; then
            error "选项 $1 不接受多余参数"
            non_interactive_usage
            exit 2
        fi
        non_interactive_usage
        exit 0
    fi
    non_interactive_dispatcher "$@"
}

# 兼容 bash <(curl ...)、直接执行与 curl ... | bash 管道方式；
# 被 source（如回归测试）时不进入 main。
# ${BASH_SOURCE[0]:-} 兼容 set -u 下管道模式的空数组。
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
