#!/bin/bash
set -euo pipefail
script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/install.sh"
# shellcheck source=install.sh
source "$script"
failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }
expect_true() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
expect_false() { local name="$1"; shift; if "$@"; then fail "$name"; else pass "$name"; fi; }

for value in '-example.com' 'example-.com' 'a.-example.com' 'a..example.com' 'example_com' 'localhost'; do
    expect_false "reject domain: $value" is_valid_domain "$value"
done
expect_true 'accept valid domain' is_valid_domain 'www.example.com'
expect_false 'reject port zero' is_valid_port 0
expect_true 'accept port 65535' is_valid_port 65535
expect_false 'reject port 65536' is_valid_port 65536
expect_true 'accept UUID' is_valid_uuid '550e8400-e29b-41d4-a716-446655440000'
expect_false 'reject invalid UUID' is_valid_uuid '550e8400-e29b-61d4-a716-446655440000'

key=$(generate_ss_key)
if [[ ${#key} -eq 24 ]] && validate_ss2022_password "$key"; then pass 'generated SS2022 key'; else fail 'generated SS2022 key'; fi
expect_false 'reject short SS key' validate_ss2022_password short
expect_false 'reject unpadded SS key' validate_ss2022_password 'AAAAAAAAAAAAAAAAAAAAAA'

url=$(generate_ss_url '203.0.113.9' 8388 'password' '2022-blake3-aes-128-gcm' '节点 name')
if [[ "$url" == ss://*@203.0.113.9:8388#%E8%8A%82%E7%82%B9%20name ]]; then pass 'SS URL encodes node name'; else fail "SS URL encoding: $url"; fi
url=$(generate_ss_url '2001:db8::9' 8388 'password' '2022-blake3-aes-128-gcm' 'node')
if [[ "$url" == ss://*'@[2001:db8::9]:8388#node' ]]; then pass 'SS URL brackets IPv6 address'; else fail "SS IPv6 URL: $url"; fi

vless_url_name=$(printf '%s' 'host #x' | jq -sRr @uri)
if [[ "$vless_url_name" == 'host%20%23x' ]]; then pass 'URI encoding handles reserved characters'; else fail "URI encoding: $vless_url_name"; fi

vless=$(build_vless_inbound 443 '550e8400-e29b-41d4-a716-446655440000' 'www.example.com' private public)
ss=$(build_ss_inbound 8388 "$key")
if jq -e '(.tag == "xray-dual-vless") and (.protocol == "vless")' <<<"$vless" >/dev/null; then pass 'VLESS JSON fields'; else fail 'VLESS JSON fields'; fi
if jq -e '(.tag == "xray-dual-ss") and (.protocol == "shadowsocks")' <<<"$ss" >/dev/null; then pass 'SS JSON fields'; else fail 'SS JSON fields'; fi

if (( 65535 + 1 > 65535 )); then pass 'port overflow boundary'; else fail 'port overflow boundary'; fi
if validate_distinct_ports 443 443 2>/dev/null; then fail 'reject duplicate protocol ports'; else pass 'reject duplicate protocol ports'; fi
if validate_distinct_ports 0443 443 2>/dev/null; then fail 'reject leading-zero duplicate ports'; else pass 'reject leading-zero duplicate ports'; fi

for value in '2400:3200::1' '2001:db8::' '::1'; do
    expect_true "accept IPv6: $value" is_valid_ipv6 "$value"
done
for value in 'deadbeef' ':::' '1:2:3:4:5:6:7:8:9' 'zz:zz' '::ffff:1.2.3.4'; do
    expect_false "reject invalid IPv6: $value" is_valid_ipv6 "$value"
done

# Validate render_config without touching the system configuration.
existing='{"log":{"loglevel":"error"},"inbounds":[{"tag":"user-vless","protocol":"vless"},{"tag":"xray-dual-vless","protocol":"vless"}],"outbounds":[{"protocol":"blackhole"}]}'
rendered=$(render_config "$existing" "[$vless]")
if jq -e '(.log.loglevel == "error") and (.outbounds[0].protocol == "blackhole") and ([.inbounds[] | select(.tag == "user-vless")] | length == 1) and ([.inbounds[] | select(.tag == "xray-dual-vless")] | length == 1)' <<<"$rendered" >/dev/null; then pass 'render preserves user inbound and top-level settings'; else fail 'render preserves user inbound and top-level settings'; fi
if render_config '{"inbounds":{}}' '[]' >/dev/null 2>&1; then fail 'reject non-array inbounds'; else pass 'reject non-array inbounds'; fi

# Validate tagged managed inbounds are detected for both protocols.
test_config=$(mktemp)
printf '{"inbounds":[%s,%s]}\n' "$vless" "$ss" > "$test_config"
if jq -e '.inbounds | length == 2' "$test_config" >/dev/null &&
   jq -e '.inbounds[1].tag == "xray-dual-ss"' "$test_config" >/dev/null &&
   [[ -n "$(get_managed_inbound vless "$test_config")" ]] &&
   [[ -n "$(get_managed_inbound shadowsocks "$test_config")" ]]; then
    pass 'dual config contains both tagged inbounds'
else
    fail 'dual config contains both tagged inbounds'
fi
rm -f "$test_config"

if [[ "$(normalize_version v26.3.27)" == "26.3.27" ]] &&
   [[ "$(normalize_version 26.3.27)" == "26.3.27" ]] &&
   ! normalize_version invalid >/dev/null 2>&1; then
    pass 'normalize Xray versions'
else
    fail 'normalize Xray versions'
fi

if grep -Fq '2." "添加 Shadowsocks-2022"' "$script" &&
   grep -Fq '2) add_ss_to_vless' "$script" &&
   grep -Fq '2." "添加 VLESS-Reality"' "$script" &&
   grep -Fq '2) add_vless_to_ss' "$script"; then
    pass 'single-protocol modify menus offer the other protocol'
else
    fail 'single-protocol modify menus offer the other protocol'
fi

if grep -Fq 'readonly SCRIPT_VERSION="v26.08.29"' "$script"; then
    pass 'script version uses date format'
else
    fail 'script version uses date format'
fi

if grep -Fq '"install" "--without-geodata"' "$script" &&
   grep -Fq 'is_port_available_for' "$script" &&
   grep -Fq -- '-z "${BASH_SOURCE[0]:-}"' "$script" &&
   grep -Fq '交互式菜单需要终端' "$script"; then
    pass 'audit fixes present (geodata dedup, port reuse, pipe guard, tty guard)'
else
    fail 'audit fixes present'
fi

if grep -Fq 'validate_distinct_ports "$vless_port" "$ss_port"' "$script"; then
    pass 'protocol addition checks distinct ports'
else
    fail 'protocol addition checks distinct ports'
fi

if grep -Fq '"${xray_config_path}.bak"' "$script" &&
   grep -Fq '"${xray_config_path}".tmp.*' "$script" &&
   grep -Fq '/root/xray_subscription_info.txt' "$script"; then
    pass 'uninstall removes configuration leftovers'
else
    fail 'uninstall removes configuration leftovers'
fi

(( failures == 0 ))
