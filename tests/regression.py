#!/usr/bin/env python3
"""Isolated regressions: extract functions only; never run the installer entrypoint.
Requires bash, jq and coreutils. All service/process/network boundaries are mocks.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'install.sh'


def relocate(text):
    """Relocate complete path tokens, not prefixes of sibling paths."""
    paths = {
        '/usr/local/etc/xray': '${CASE}/etc',
        '/usr/local/bin/xray': '${CASE}/bin/xray',
        '/usr/local/share/xray': '${CASE}/share',
        '/etc/systemd/system': '${CASE}/systemd',
        '/etc/logrotate.d': '${CASE}/logrotate',
        '/var/log/xray': '${CASE}/log',
        '/root/xray_subscription_info.txt': '${CASE}/subscription',
        '/var/tmp/xray-': '${CASE}/xray-',
        '/proc/sys/net/ipv6': '${CASE}/ipv6',
        '/proc/sys/kernel/random/uuid': '${CASE}/random-uuid',
        '/etc/debian_version': '${CASE}/debian-version',
        '/proc/': '${CASE}/proc/',
    }
    for old, new in paths.items():
        # Prefix paths ending '/' or '-' intentionally own their descendants.
        boundary = '' if old.endswith(('/', '-')) else r'(?=$|[/\s\"\'\)};])'
        pattern = r'(?<![\w/.-])' + re.escape(old) + boundary
        # A single-quoted path must become expandable in the regular fixture.
        text = re.sub("'(" + re.escape(old) + r"[^']*)'",
                      lambda m: '"' + re.sub(pattern, lambda _: new, m[1]) + '"', text)
        text = re.sub(pattern, lambda _: new, text)
    return text


class Regression(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory(prefix='xray-dual-test-', dir=os.environ.get('TMPDIR')) as root:
            source = SOURCE.read_text()
            functions = re.findall(r'^([a-zA-Z_]\w*)\(\) \{\n(.*?)^\}', source, re.M | re.S)
            lib = '\n'.join(f'{name}() {{\n{code}\n}}' for name, code in functions
                            if name not in ('main', 'non_interactive_dispatcher', 'pre_check'))
            lib += '\n' + '\n'.join(re.findall(r'^(?:info|success|warning)\(\) \{.*?\}$', source, re.M))
            lib = relocate(lib)
            setup = r'''
set -euo pipefail
red='' green='' yellow='' magenta='' cyan='' none=''
xray_config_path="$CASE/etc/config.json"; xray_binary_path="$CASE/bin/xray"
config_written=false; config_backup=''; transaction_backup=''
mkdir -p "$CASE/etc" "$CASE/bin" "$CASE/share" "$CASE/systemd" "$CASE/proc/123" "$CASE/ipv6/conf/all"
printf 0 > "$CASE/ipv6/conf/all/disable_ipv6"
printf '%s\n' '#!/bin/bash' 'case "$1" in version) echo "Xray 1.0.0";; run) exit 0;; x25519) echo "Password: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";; esac' > "$xray_binary_path"
chmod +x "$xray_binary_path"
ln -s "$xray_binary_path" "$CASE/proc/123/exe"
printf old-unit > "$CASE/systemd/xray.service"
STATE=active
ENABLED=enabled
systemctl() { printf 'systemctl %s\n' "$*" >> "$CASE/calls"; case "$1" in is-active) [[ "$STATE" == active ]];; is-enabled) echo "$ENABLED"; case "$ENABLED" in enabled|enabled-runtime|static|indirect) return 0;; not-found) return 4;; *) return 1;; esac;; enable) if [[ "$*" == *--runtime* ]]; then ENABLED=enabled-runtime; else ENABLED=enabled; fi;; disable) ENABLED=disabled;; show) if [[ "$*" == *MainPID* ]]; then echo MainPID=123; elif [[ "$*" == *ActiveState* ]]; then echo "ActiveState=$STATE"; elif [[ "$*" == *'-p Group'* ]]; then echo Group=; else echo User=root; fi;; restart|start) STATE=active;; stop) STATE=inactive;; *) return 0;; esac; }
kill() { printf 'BLOCKED kill\n' >> "$CASE/calls"; return 99; }
pkill() { printf 'BLOCKED pkill\n' >> "$CASE/calls"; return 99; }
pgrep() { return 1; }
apt-get() { return 99; }; apt() { return 99; }; yum() { return 99; }; dnf() { return 99; }
pidof() { return 1; }; netstat() { return 99; }; wget() { return 99; }
service() { return 99; }; timedatectl() { return 99; }; date() { return 99; }
sysctl() { return 99; }; iptables() { return 99; }; ip6tables() { return 99; }; nft() { return 99; }; ufw() { return 99; }
curl() { printf '{"tag_name":"v2.0.0"}\n'; }
ss() { return 0; }; sleep() { :; }; journalctl() { return 99; }
chown() { :; }
execute_official_script() { printf 'official %s\n' "$*" >> "$CASE/calls"; return 0; }
get_public_ip() { echo 192.0.2.1; }
view_all_info() { :; }
KEY=AAAAAAAAAAAAAAAAAAAAAA==
UUID=00112233-4455-4677-8899-aabbccddeeff
PRIV=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PUB=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
'''
            script = Path(root) / 'case.sh'
            script.write_text(lib + '\n' + setup + '\n' + body)
            result = subprocess.run(['bash', str(script)], capture_output=True, text=True,
                                    env={**os.environ, 'CASE': root, 'TMPDIR': root}, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reality_public_key_derived_not_stale(self):
        self.run_shell(r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
jq -e '.streamSettings.realitySettings | has("publicKey") | not' <<< "$v"
v=$(jq --arg public "$PUB" '.streamSettings.realitySettings.publicKey=$public' <<< "$v")
printf '#!/bin/bash\nprintf "Password: %s\\n"\n' "$PRIV" > "$xray_binary_path"
[[ $(get_reality_public_key "$v") == "$PRIV" ]]
printf '#!/bin/bash\nprintf "Password: %s\\n"\nexit 7\n' "$PRIV" > "$xray_binary_path"
if get_reality_public_key "$v"; then exit 1; fi
''')

    def test_raw_settings_migration_preserves_precedence(self):
        self.run_shell(r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB" | jq '.streamSettings.tcpSettings={header:{type:"none"}}')
render_config '{}' "[$v]" | jq -e '.inbounds[0].streamSettings | .rawSettings=={header:{type:"none"}} and (has("tcpSettings")|not)'
v=$(jq '.streamSettings.rawSettings={acceptProxyProtocol:true}' <<< "$v")
render_config '{}' "[$v]" | jq -e '.inbounds[0].streamSettings | .rawSettings=={acceptProxyProtocol:true} and (has("tcpSettings")|not)'
''')

    def test_recommended_vless_fields(self):
        self.run_shell(r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
jq -e --arg uuid "$UUID" '.settings.users[0].id == $uuid and (.settings | has("clients") | not) and .streamSettings.method == "raw" and (.streamSettings | has("network") | not) and .streamSettings.realitySettings.target == "www.sega.com:443" and (.streamSettings.realitySettings | has("dest") | not)' <<< "$v"
''')

    def test_write_migrates_only_supplied_managed_vless(self):
        self.run_shell(r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB" | jq '.settings.clients=.settings.users | del(.settings.users) | .streamSettings.network="tcp" | del(.streamSettings.method) | .streamSettings.realitySettings.dest=.streamSettings.realitySettings.target | del(.streamSettings.realitySettings.target) | .settings.clients += [{id:"11112233-4455-4677-8899-aabbccddeeff",email:"extra"}] | .streamSettings.sockopt={tcpFastOpen:true}')
custom=$(jq '.tag="custom-vless" | .port=9000' <<< "$v")
existing=$(jq -n --argjson v "$v" --argjson custom "$custom" '{dns:{servers:["1.1.1.1"]},inbounds:[$v,$custom]}')
printf '%s' "$existing" > "$xray_config_path"
s=$(build_ss_inbound 8388 "$KEY")
write_config "[$v,$s]" || exit 1
jq -e --argjson custom "$custom" '.dns.servers==["1.1.1.1"] and (.inbounds|length)==3 and .inbounds[0]==$custom and .inbounds[1].settings.users[1].email=="extra" and (.inbounds[1].settings|has("clients")|not) and .inbounds[1].streamSettings.method=="raw" and (.inbounds[1].streamSettings|has("network")|not) and .inbounds[1].streamSettings.realitySettings.target=="www.sega.com:443" and (.inbounds[1].streamSettings.realitySettings|has("dest")|not) and .inbounds[1].streamSettings.sockopt.tcpFastOpen' "$xray_config_path"
''')

    def test_freedom_migrates_to_official_socket_strategy(self):
        self.run_shell(r'''
render_config '{}' '[]' > "$CASE/fresh.json"
jq -e '.outbounds[0].settings=={} and .outbounds[0].streamSettings.sockopt.domainStrategy=="UseIPv4v6"' "$CASE/fresh.json"
render_config '{"outbounds":[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]}' '[]' > "$CASE/migrated.json"
jq -e --slurpfile expected "$CASE/fresh.json" '.==$expected[0]' "$CASE/migrated.json"
custom='[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4","redirect":"127.0.0.1:9000"},"tag":"custom"}]'
render_config "{\"outbounds\":$custom}" '[]' | jq -e '.outbounds[0] | .tag=="custom" and .settings.redirect=="127.0.0.1:9000" and (.settings|has("domainStrategy")|not) and .streamSettings.sockopt.domainStrategy=="UseIPv4"'
''')

    def test_migration_matches_core_alias_precedence(self):
        self.run_shell(r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB" | jq --arg uuid "$UUID" '.settings.clients=[{id:$uuid,flow:"xtls-rprx-vision"}] | .settings.users=[{id:"11112233-4455-4677-8899-aabbccddeeff"}] | .streamSettings.network="invalid-ignored-network" | .streamSettings.realitySettings.dest="ignored.example:8443"')
render_config '{}' "[$v]" > "$xray_config_path"
jq -e --arg uuid "$UUID" '.inbounds[0] | .settings.users[0].id==$uuid and (.settings|has("clients")|not) and .streamSettings.method=="raw" and (.streamSettings|has("network")|not) and .streamSettings.realitySettings.target=="www.sega.com:443" and (.streamSettings.realitySettings|has("dest")|not)' "$xray_config_path"
''')

    def test_old_and_new_vless_manage_modify_and_export(self):
        match = re.search(r'^view_all_info\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        view = match[0].replace('/root/xray_subscription_info.txt', '${CASE}/subscription')
        for legacy in ('true', 'false'):
            for tagged in ('true', 'false'):
                with self.subTest(legacy=legacy, tagged=tagged):
                    self.run_shell(view + '\nLEGACY=' + legacy + '; TAGGED=' + tagged + r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB" | jq '.listen="0.0.0.0" | .settings.users += [{id:"11112233-4455-4677-8899-aabbccddeeff",email:"extra"}] | .streamSettings.sockopt={tcpFastOpen:true} | .streamSettings.realitySettings.shortIds += ["ab"] | .streamSettings.realitySettings.target="www.sega.com:8443"')
if "$LEGACY"; then v=$(jq '.settings.clients=.settings.users | del(.settings.users) | .streamSettings.network="tcp" | del(.streamSettings.method) | .streamSettings.realitySettings.dest=.streamSettings.realitySettings.target | del(.streamSettings.realitySettings.target)' <<< "$v"); fi
if ! "$TAGGED"; then v=$(jq 'del(.tag)' <<< "$v"); fi
s=$(build_ss_inbound 8388 "$KEY")
jq -n --argjson v "$v" --argjson s "$s" '{inbounds:[$v,$s]}' > "$xray_config_path"
[[ -n "$(get_managed_inbound vless)" ]]
view_all_info > "$CASE/view-before" || exit 1
cp "$CASE/subscription" "$CASE/subscription-before"
grep -Fq "vless://${UUID}@192.0.2.1:443?" "$CASE/subscription"
grep -Fq "type=tcp&security=reality" "$CASE/subscription"
grep -Fq "pbk=${PUB}" "$CASE/subscription"
STATE=inactive
modify_vless_config <<< $'\n\n\n' > "$CASE/modify" || exit 1
cmp "$CASE/subscription-before" "$CASE/subscription"
jq -e '.inbounds | length==2 and any(.[]; .protocol=="vless" and .settings.users[1].email=="extra" and .streamSettings.sockopt.tcpFastOpen and .streamSettings.realitySettings.shortIds==["20220701","ab"] and .streamSettings.realitySettings.target=="www.sega.com:8443" and (.settings|has("clients")|not) and (.streamSettings|has("network")|not))' "$xray_config_path"
[[ -n "$(get_managed_inbound vless)" ]]
modify_vless_config <<< $'444\n11112233-4455-4677-8899-aabbccddeeff\nwww.example.com' > "$CASE/modify-again" || exit 1
jq -e 'any(.inbounds[]; .protocol=="vless" and .port==444 and .settings.users[0].id=="11112233-4455-4677-8899-aabbccddeeff" and .streamSettings.realitySettings.target=="www.example.com:443" and .settings.users[1].email=="extra")' "$xray_config_path"
! grep -q '^systemctl restart' "$CASE/calls" || exit 97
''')

    def test_ipv6_export_rejects_old_listeners(self):
        match=re.search(r'^view_all_info\(\) \{\n.*?^\}',SOURCE.read_text(),re.M|re.S)
        assert match
        view=match[0].replace('/root/xray_subscription_info.txt','${CASE}/subscription')
        self.run_shell(view+'''\nget_public_ip() { echo 2001:db8::1; }
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
s=$(build_ss_inbound 8388 "$KEY")
for which in 0 1; do
 render_config '{}' "[$v,$s]" | jq --argjson i "$which" '.inbounds[$i].listen="0.0.0.0"' > "$xray_config_path"
 printf ORIGINAL > "$CASE/subscription"
 if view_all_info; then exit 81; fi
 [[ $(<"$CASE/subscription") == ORIGINAL ]]
done
''')

    def test_partial_uninstall_skips_official(self):
        self.run_shell('''rm -f "$CASE/systemd/xray.service"
printf template > "$CASE/systemd/xray@.service"
execute_official_script() { return 81; }
uninstall_xray <<< y
[[ ! -e "$CASE/systemd/xray@.service" ]]
''')

    def test_modify_ss_preserves_custom_inbound_fields(self):
        self.run_shell(r'''
s=$(build_ss_inbound 8388 "$KEY" | jq '.settings.network="tcp,udp" | .settings.users=[{password:"extra-user"}] | .sniffing={enabled:false} | .streamSettings={sockopt:{tcpFastOpen:true}}')
render_config '{}' "[$s]" > "$xray_config_path"
cp "$xray_config_path" "$CASE/original"
STATE=inactive
modify_ss_config <<< $'8389\n\n' || exit 1
jq '.inbounds[0].port=8389' "$CASE/original" > "$CASE/expected"
jq -S . "$xray_config_path" > "$CASE/actual"
jq -S . "$CASE/expected" > "$CASE/sorted-expected"
cmp "$CASE/actual" "$CASE/sorted-expected"
''')

    def test_domain_total_length_limit(self):
        self.run_shell(r'''
printf -v label '%063d' 0
is_valid_domain "$label.$label.$label.${label:0:61}" || exit 1
if is_valid_domain "$label.$label.$label.$label"; then exit 81; fi
''')

    def test_port_probe_failure(self):
        self.run_shell('ss() { return 2; }; if is_port_available 443; then exit 1; fi')

    def test_single_protocol_collision_before_installer(self):
        self.run_shell('''v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
render_config '{}' "[$v]" > "$xray_config_path"
if run_install_ss 443 "$KEY"; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null || exit 97
''')

    def test_unknown_inbound_collision(self):
        self.run_shell('''printf '{"inbounds":[{"tag":"custom","port":8388,"protocol":"socks"}]}' > "$xray_config_path"
s=$(build_ss_inbound 8388 "$KEY")
if write_config "[$s]"; then exit 1; fi
jq -e '.inbounds[0].tag == "custom"' "$xray_config_path"
''')

    def test_sip002(self):
        self.run_shell('''url=$(generate_ss_url 2001:db8::1 8388 '+////////////////////w==' 2022-blake3-aes-128-gcm 'node test')
[[ "$url" == 'ss://2022-blake3-aes-128-gcm:%2B%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2Fw%3D%3D@[2001:db8::1]:8388#node%20test' ]]
''')

    def test_fresh_config_stop_failure_retains_config(self):
        self.run_shell('''s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]"
restart_xray() { return 1; }
systemctl() { [[ "$1" != stop ]]; }
if apply_config_and_restart; then exit 1; fi
[[ -f "$xray_config_path" && "$config_written" == true ]]
if write_config "[$s]"; then exit 1; fi
''')

    def test_reinstall_geodata_rollback(self):
        self.run_shell('''printf '{"inbounds":[]}' > "$xray_config_path"
cp -p "$xray_binary_path" "$CASE/original"; cp -p "$xray_config_path" "$CASE/config"
execute_official_script() { printf 'official %s\\n' "$*" >> "$CASE/calls"; if [[ "$1" == install ]]; then printf '# changed\\n' > "$xray_binary_path"; STATE=inactive; return 0; else return 1; fi; }
if run_install_ss 8388 "$KEY"; then exit 1; fi
cmp "$CASE/original" "$xray_binary_path"; cmp "$CASE/config" "$xray_config_path"; [[ "$STATE" == active ]]
grep -q -- '--no-update-service' "$CASE/calls"
''')

    def test_update_missing_main_unit(self):
        self.run_shell('''rm "$CASE/systemd/xray.service"
mkdir -p "$CASE/systemd/xray.service.d"; printf override > "$CASE/systemd/xray.service.d/custom.conf"
if update_xray; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null || exit 97
[[ $(< "$CASE/systemd/xray.service.d/custom.conf") == override ]]
''')

    def test_config_only_uninstall(self):
        self.run_shell('''rm "$xray_binary_path" "$CASE/systemd/xray.service"; printf '{}' > "$xray_config_path"
printf '192.0.2.1\\n' > "$CASE/etc/.public-ip"
execute_official_script() { return 1; }
uninstall_xray <<< y || exit 1
[[ ! -e "$xray_config_path" && ! -e "$CASE/etc/.public-ip" ]]
''')

    def test_dropin_only_uninstall(self):
        self.run_shell('''rm "$xray_binary_path" "$CASE/systemd/xray.service"
mkdir "$CASE/systemd/xray.service.d"; printf override > "$CASE/systemd/xray.service.d/custom.conf"
uninstall_xray <<< y || exit 1
[[ ! -e "$CASE/systemd/xray.service.d" ]]
''')

    def test_uninstall_removes_only_cache_file_or_link(self):
        self.run_shell(r'''
rm "$xray_binary_path" "$CASE/systemd/xray.service"
cache="$CASE/etc/.public-ip"
mkdir "$cache"
printf KEEP > "$cache/unrelated"
uninstall_xray <<< y || exit 90
[[ $(< "$cache/unrelated") == KEEP ]]
if grep -q '^systemctl daemon-reload$' "$CASE/calls"; then exit 93; fi
printf '{}' > "$xray_config_path"
mkdir "$CASE/etc/unrelated-empty-dir"
uninstall_xray <<< y || exit 91
[[ ! -e "$xray_config_path" && $(< "$cache/unrelated") == KEEP ]]
[[ -d "$CASE/etc/unrelated-empty-dir" ]]
mv "$cache" "$CASE/unrelated-dir"
ln -s "$CASE/unrelated-dir" "$cache"
uninstall_xray <<< y || exit 92
[[ ! -L "$cache" && $(< "$CASE/unrelated-dir/unrelated") == KEEP ]]
''')

    def test_pinned_stopped_conditional(self):
        self.run_shell('''printf '%s\\n' 'main() {' '  [[ "$1" != early ]] || return 7' '  XRAY_RUNNING=0' "    [[ \\"\\$XRAY_RUNNING\\" -eq '1' ]] && start_xray" '}' 'main "$@"' > "$CASE/official"
normalize_official_script "$CASE/official" || exit 1
bash "$CASE/official" || exit 1
if bash "$CASE/official" early; then exit 1; else [[ $? == 7 ]]; fi
if normalize_official_script "$CASE/official"; then exit 1; fi
''')

    def test_fresh_transaction_cleans_dropins(self):
        self.run_shell('''rm "$xray_binary_path" "$CASE/systemd/xray.service"; STATE=inactive
execute_official_script() {
 if [[ "$1" == install ]]; then
  printf replacement > "$xray_binary_path"; printf '{}' > "$xray_config_path"
  printf unit > "$CASE/systemd/xray.service"; printf template > "$CASE/systemd/xray@.service"
  mkdir -p "$CASE/systemd/xray.service.d" "$CASE/systemd/xray@.service.d"
  printf override > "$CASE/systemd/xray.service.d/10.conf"; printf override > "$CASE/systemd/xray@.service.d/10.conf"
  return 0
 fi
 return 1
}
if run_install_ss 8388 "$KEY"; then exit 1; fi
[[ ! -e "$xray_binary_path" && ! -e "$xray_config_path" && ! -e "$CASE/systemd/xray.service.d" && ! -e "$CASE/systemd/xray@.service.d" && -z "$transaction_backup" ]]
if run_install_ss 8388 "$KEY"; then exit 1; fi
[[ -z "$transaction_backup" ]]
''')

    def test_recovery_failure_blocks_menu_retry(self):
        self.run_shell('''printf '{"inbounds":[]}' > "$xray_config_path"; chmod 604 "$xray_config_path"
cp -p "$xray_binary_path" "$CASE/original"
execute_official_script() { if [[ "$1" == install ]]; then printf changed > "$xray_binary_path"; return 0; fi; return 1; }
restore_file() { return 1; }
run_install_ss 8388 "$KEY" || true
[[ -d "$transaction_backup" ]]; saved="$transaction_backup"
cmp "$CASE/original" "$saved/0"
run_install_ss 8388 "$KEY" || true
[[ "$transaction_backup" == "$saved" ]]
s=$(build_ss_inbound 8389 "$KEY")
if write_config "[$s]"; then exit 1; fi
''')

    def test_update_stopped_preserves_state_and_files(self):
        self.run_shell('''STATE=inactive
printf '{}' > "$xray_config_path"
mkdir "$CASE/systemd/xray.service.d"; printf override > "$CASE/systemd/xray.service.d/custom.conf"
execute_official_script() { printf 'official %s\\n' "$*" >> "$CASE/calls"; return 0; }
update_xray || exit 1
[[ "$STATE" == inactive && -z "$transaction_backup" && $(< "$CASE/systemd/xray.service.d/custom.conf") == override ]]
grep -q -- '--no-update-service' "$CASE/calls"
''')

    def test_residual_identity_and_term(self):
        self.run_shell('''mkdir -p "$CASE/proc/456"; ln -s /unrelated/xray "$CASE/proc/456/exe"
printf '123\\n456\\n' > "$CASE/pids"
pgrep() { command cat "$CASE/pids"; }
kill() { [[ "$1" == -TERM && "$2" == 123 ]] || return 1; printf '456\\n' > "$CASE/pids"; printf term > "$CASE/terminated"; }
stop_residual_xray || exit 1
[[ -f "$CASE/terminated" && -L "$CASE/proc/456/exe" ]]
''')

    def test_uninstall_process_query_error_retains_files(self):
        self.run_shell('''pgrep() { return 2; }
if uninstall_xray <<< y; then exit 1; fi
[[ -e "$xray_binary_path" && -e "$CASE/systemd/xray.service" ]]
''')

    def test_restart_stability_and_executable(self):
        self.run_shell('''restart_xray || exit 1
ln -sf /unrelated/program "$CASE/proc/123/exe"
if restart_xray; then exit 1; fi
ln -sf "$xray_binary_path" "$CASE/proc/123/exe"
printf 0 > "$CASE/probes"
systemctl() { if [[ "$1" == show ]]; then n=$(< "$CASE/probes"); printf '%s' "$((n+1))" > "$CASE/probes"; if [[ "$n" == 0 ]]; then echo MainPID=123; else echo MainPID=456; fi; fi; }
mkdir -p "$CASE/proc/456"; ln -s "$xray_binary_path" "$CASE/proc/456/exe"
if restart_xray; then exit 1; fi
[[ $(< "$CASE/probes") == 2 ]]
''')

    def test_port_probe_prompt_propagation(self):
        self.run_shell('''ss() { return 2; }; a=''; b=''; c=''
if prompt_for_vless_config a b c <<< $'443\\n'; then exit 1; fi
if prompt_for_ss_config a b <<< $'8388\\n'; then exit 1; fi
if run_install_ss 8388 "$KEY"; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null || exit 97
''')

    def test_custom_port_range_conflict(self):
        self.run_shell('''printf '{"inbounds":[{"tag":"custom","port":"8000-9000","protocol":"socks"}]}' > "$xray_config_path"
if run_install_ss 8388 "$KEY"; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null || exit 97
''')

    def test_successful_merge_preserves_other_and_permissions_rollback(self):
        self.run_shell('''v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
render_config '{"dns":{"servers":["1.1.1.1"]},"inbounds":[{"tag":"custom","port":9000,"protocol":"socks"}]}' "[$v]" > "$xray_config_path"
run_install_ss 8388 "$KEY" || exit 1
jq -e '.dns.servers == ["1.1.1.1"] and (.inbounds|length)==3' "$xray_config_path"
chmod 604 "$xray_config_path"; cp -p "$xray_config_path" "$CASE/original"
s=$(build_ss_inbound 8389 "$KEY"); write_config "[$v,$s]" || exit 1
restart_xray() { return 1; }
apply_config_and_restart || true
cmp "$CASE/original" "$xray_config_path"; [[ $(stat -c %a "$xray_config_path") == 604 && "$config_written" == true ]]
''')

    def test_config_permissions_use_effective_service_group(self):
        self.run_shell(r'''
eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
systemctl() {
 if [[ "$1" == show && "$*" == *'-p Group'* ]]; then echo Group=nogroup
 else original_systemctl "$@"; fi
}
chown() { printf '%s\n' "$1" > "$CASE/ownership"; }
s=$(build_ss_inbound 8388 "$KEY")
write_config "[$s]" || exit 1
[[ $(< "$CASE/ownership") == root:nogroup ]]
''')

    def test_service_properties_fail_closed(self):
        for value in ('failure', 'missing', 'User=nonexistent-xray-user', 'User=root\\nUser=nobody'):
            with self.subTest(value=value):
                self.run_shell('VALUE=' + __import__('shlex').quote(value) + r'''
printf '{}' > "$xray_config_path"; cp "$xray_config_path" "$CASE/original-config"
s=$(build_ss_inbound 8388 "$KEY")
eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
systemctl() {
 [[ "$*" != *--value* ]] || return 1
 if [[ "$1" == show && "$*" == *'-p User'* ]]; then
  [[ "$VALUE" != failure ]] || return 1
  printf '%b\n' "$VALUE"; return 0
 fi
 original_systemctl "$@"
}
if write_config "[$s]"; then exit 1; fi
cmp "$CASE/original-config" "$xray_config_path"
! compgen -G "$CASE/etc/config.json.tmp.*" || exit 97
''')
        self.run_shell(r'''
eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
systemctl() { [[ "$*" != *--value* ]] || return 1; if [[ "$1" == show && "$*" == *'-p User'* ]]; then echo User=; else original_systemctl "$@"; fi; }
s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]" || exit 1
restart_xray || exit 1
''')

    def test_stopped_config_change_does_not_start(self):
        self.run_shell(r'''
STATE=inactive
s=$(build_ss_inbound 8388 "$KEY"); render_config '{}' "[$s]" > "$xray_config_path"
s=$(build_ss_inbound 8389 "$KEY"); write_config "[$s]" || exit 1
apply_config_and_restart || exit 1
[[ "$STATE" == inactive && "$config_written" == false && -z "$config_backup" ]]
! grep -q 'systemctl restart' "$CASE/calls" || exit 97
jq -e '.inbounds[0].port == 8389' "$xray_config_path"
''')

    def test_dispatcher_validates_before_dependency_side_effects(self):
        match = re.search(r'^non_interactive_dispatcher\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        dispatcher = match[0].replace('/proc/sys/kernel/random/uuid', '${CASE}/random-uuid')
        self.run_shell(dispatcher + r'''
printf '%s' "$UUID" > "$CASE/random-uuid"
pre_check() { printf called >> "$CASE/precheck"; }
non_interactive_usage() { :; }
run_install_vless() { printf 'vless %s\n' "$*" >> "$CASE/args"; }
run_install_ss() { printf 'ss %s\n' "$*" >> "$CASE/args"; }
run_install_dual() { printf 'dual %s\n' "$*" >> "$CASE/args"; }
for args in 'vless --vless-port 0001' 'ss --ss-port 65536' 'ss --ss-pass wrong' 'dual --uuid wrong' 'dual --vless-port 65535'; do
 if ( non_interactive_dispatcher install --type $args ); then exit 1; fi
done
( non_interactive_dispatcher </dev/null ) && exit 90 || rc=$?
[[ "$rc" == 1 ]]
[[ ! -e "$CASE/precheck" && ! -e "$CASE/args" ]]
non_interactive_dispatcher install --type vless --uuid "$UUID" || exit 1
non_interactive_dispatcher install --type ss || exit 1
non_interactive_dispatcher install --type dual --uuid "$UUID" || exit 1
[[ $(wc -l < "$CASE/args") == 3 && -s "$CASE/precheck" ]]
''')

    def test_official_wrapper_failure_propagation(self):
        match = re.search(r'^execute_official_script\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        self.run_shell(match[0].replace('/usr/local/share/xray', '${CASE}/share') + r'''
xray_install_script_url=https://example.invalid/pinned; xray_install_script_sha256=unused
for PHASE in download digest patch writes execution success; do
 curl() { echo stub; [[ "$PHASE" != download ]]; }
 sha256sum() { [[ "$PHASE" != digest ]]; }
 normalize_official_script() { [[ "$PHASE" != patch ]]; }
 normalize_official_writes() { [[ "$PHASE" != writes ]]; }
 bash() { printf called >> "$CASE/exec"; [[ "$PHASE" != execution ]] || return 37; }
 rm -f "$CASE/exec"
 if execute_official_script install; then [[ "$PHASE" == success ]] || exit 1
 else result=$?; [[ "$PHASE" != success ]] || exit 1
  [[ "$PHASE" != execution || "$result" == 37 ]] || exit 1
 fi
 if [[ "$PHASE" != execution && "$PHASE" != success ]]; then [[ ! -e "$CASE/exec" ]]; fi
 ! compgen -G "$CASE/tmp.*" || exit 97
done
''')

    def test_config_staging_failures_leave_original_and_no_staging_file(self):
        for phase in ('chmod', 'log-temp', 'backup-temp', 'rename'):
            with self.subTest(phase=phase):
                self.run_shell('PHASE=' + phase + r'''
printf '{}' > "$xray_config_path"; cp -p "$xray_config_path" "$CASE/original-config"
s=$(build_ss_inbound 8388 "$KEY")
chmod() { [[ "$PHASE" != chmod ]] || return 1; command chmod "$@"; }
mktemp() {
 if [[ "$PHASE" == log-temp && $# == 0 ]]; then return 1; fi
 if [[ "$PHASE" == backup-temp && "$*" == *rollback* ]]; then return 1; fi
 command mktemp "$@"
}
mv() { [[ "$PHASE" != rename || "${@: -1}" != "$xray_config_path" ]] || return 1; command mv "$@"; }
if write_config "[$s]"; then exit 1; fi
cmp "$CASE/original-config" "$xray_config_path"
[[ "$config_written" == false ]]
! compgen -G "$CASE/etc/config.json.tmp.*" || exit 97
! compgen -G "$CASE/etc/config.json.rollback.*" || exit 97
''')

    def test_config_rename_interrupt_is_armed_for_recovery(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
(
 trap 'on_exit $?' EXIT; trap 'exit 143' TERM
 mv() { command mv "$@" || return 1; if [[ "${@: -1}" == "$xray_config_path" && ! -e "$CASE/signaled" ]]; then touch "$CASE/signaled"; builtin kill -TERM "$BASHPID"; fi; }
 s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]"
 exit 91
) && exit 1 || result=$?
[[ "$result" == 143 && $(< "$xray_config_path") == '{}' ]]
''')

    def test_fresh_transaction_interrupt_removes_new_installation(self):
        self.run_shell(r'''
rm "$xray_binary_path" "$CASE/systemd/xray.service"
STATE=inactive; ENABLED=not-found
(
 trap 'on_exit $?' EXIT; trap 'exit 130' INT
 begin_transaction || exit 1
 printf new > "$xray_binary_path"; printf '{}' > "$xray_config_path"
 printf unit > "$CASE/systemd/xray.service"; STATE=active; ENABLED=enabled
 builtin kill -INT "$BASHPID"
 exit 91
) && exit 1 || result=$?
[[ "$result" == 130 && ! -e "$xray_binary_path" && ! -e "$xray_config_path" && ! -e "$CASE/systemd/xray.service" ]]
grep -q '^systemctl stop xray$' "$CASE/calls"; grep -q '^systemctl disable xray$' "$CASE/calls"
! compgen -G "$CASE/xray-transaction.*" || exit 97
''')

    def test_snapshot_interrupt_does_not_restore_partial_backup(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
cp -p "$xray_binary_path" "$CASE/original"
(
 trap 'on_exit $?' EXIT; trap 'exit 143' TERM
 cp() { command cp "$@" || return 1; builtin kill -TERM "$BASHPID"; }
 begin_transaction
 exit 91
) && exit 1 || result=$?
[[ "$result" == 143 ]]
cmp "$CASE/original" "$xray_binary_path"
[[ $(< "$xray_config_path") == '{}' ]]
! compgen -G "$CASE/xray-transaction.*" || exit 97
! grep -q '^systemctl stop' "$CASE/calls" || exit 97
''')

    def test_configuration_interrupt_restores_stopped_state(self):
        self.run_shell(r'''
STATE=inactive
printf '{}' > "$xray_config_path"
(
 trap 'on_exit $?' EXIT; trap 'exit 130' INT
 s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]" || exit 1
 builtin kill -INT "$BASHPID"
 exit 91
) && exit 1 || result=$?
[[ "$result" == 130 && $(< "$xray_config_path") == '{}' ]]
! grep -q '^systemctl restart' "$CASE/calls" || exit 97
''')

    def test_commit_cleanup_interrupt_does_not_restore_partial_backup(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
(
 trap 'on_exit $?' EXIT; trap 'exit 143' TERM
 begin_transaction || exit 1
 printf changed > "$xray_binary_path"
 rm() { command rm "$@" || return 1; builtin kill -TERM "$BASHPID"; }
 commit_transaction
 exit 91
) && exit 1 || result=$?
[[ "$result" == 143 && $(< "$xray_binary_path") == changed ]]
! grep -q '^systemctl stop' "$CASE/calls" || exit 97
''')

    def test_interrupted_transaction_recovers_and_keeps_exit_code(self):
        for stopped in (False, True):
            with self.subTest(stopped=stopped):
                self.run_shell(('STATE=inactive\n' if stopped else '') + r'''
printf '{}' > "$xray_config_path"
cp -p "$xray_binary_path" "$CASE/original"
cp -p "$xray_config_path" "$CASE/config-original"
(
 trap 'on_exit $?' EXIT
 trap 'exit 143' TERM
 begin_transaction || exit 1
 printf changed > "$xray_binary_path"; printf changed > "$xray_config_path"
 builtin kill -TERM "$BASHPID"
 exit 91
) && exit 1 || result=$?
[[ "$result" == 143 ]]
cmp "$CASE/original" "$xray_binary_path"; cmp "$CASE/config-original" "$xray_config_path"
! compgen -G "$CASE/xray-transaction.*" || exit 97
''' + (r'! grep -q "systemctl restart" "$CASE/calls"' if stopped else r'grep -q "systemctl restart" "$CASE/calls"'))

    def test_exit_only_cleans_owned_temporary_config(self):
        self.run_shell(r'''
printf owned > "$CASE/etc/config.json.tmp.owned"
printf other > "$CASE/etc/config.json.tmp.other"
pending_config_file="$CASE/etc/config.json.tmp.owned"
on_exit 0
[[ ! -e "$pending_config_file" && -e "$CASE/etc/config.json.tmp.other" ]]
''')

    def test_official_environment_cannot_escape_transaction_paths(self):
        match = re.search(r'^execute_official_script\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        wrapper = match[0].replace('/usr/local/share/xray', '${CASE}/share')
        self.run_shell(wrapper + r'''
xray_install_script_url=https://example.invalid/pinned
xray_install_script_sha256=unused
export JSON_PATH="$CASE/foreign-json" JSONS_PATH="$CASE/foreign-multi" DAT_PATH="$CASE/foreign-data"
curl() { echo stub; }; sha256sum() { return 0; }; normalize_official_script() { return 0; }; normalize_official_writes() { return 0; }
bash() { printf '%s\n' "$JSON_PATH" "$JSONS_PATH" "$DAT_PATH" > "$CASE/env"; }
execute_official_script install || exit 1
mapfile -t paths < "$CASE/env"
[[ "${paths[0]}" == "$CASE/etc" && -z "${paths[1]}" && "${paths[2]}" == "$CASE/share" ]]
[[ "$JSON_PATH" == "$CASE/foreign-json" ]]
''')

    def test_recovery_failure_never_restarts_mixed_files(self):
        for boundary in ('restore_file', 'reload', 'enablement'):
            with self.subTest(boundary=boundary):
                self.run_shell('BOUNDARY=' + boundary + r'''
printf '{}' > "$xray_config_path"
begin_transaction || exit 1
printf changed > "$xray_binary_path"
if [[ "$BOUNDARY" == restore_file ]]; then restore_file() { return 1; }; fi
if [[ "$BOUNDARY" == enablement ]]; then restore_enablement() { return 1; }; fi
if [[ "$BOUNDARY" == reload ]]; then
 eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
 systemctl() { [[ "$1" != daemon-reload ]] || return 1; original_systemctl "$@"; }
fi
rollback_transaction || true
[[ "$STATE" == inactive && -d "$transaction_backup" ]]
! grep -q '^systemctl restart' "$CASE/calls" || exit 97
''')

    def test_config_restore_failure_stops_before_replacement(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]" || exit 1
restore_file() { return 1; }
restart_xray() { printf UNEXPECTED >> "$CASE/restarts"; return 1; }
rollback_config_and_restart || true
[[ "$STATE" == inactive && -f "$config_backup" && "$config_written" == true ]]
[[ ! -e "$CASE/restarts" ]]
''')
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]" || exit 1
cp "$xray_config_path" "$CASE/new-config"
systemctl() { [[ "$1" != stop ]]; }
restore_file() { printf UNEXPECTED >> "$CASE/restore-calls"; }
rollback_config_and_restart || true
cmp "$CASE/new-config" "$xray_config_path"
[[ ! -e "$CASE/restore-calls" && -f "$config_backup" ]]
''')

    def test_symlink_snapshots_round_trip(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
printf real-unit > "$CASE/unit-source"
rm "$CASE/systemd/xray.service"; ln -s "$CASE/unit-source" "$CASE/systemd/xray.service"
ln -s "$CASE/missing-target" "$CASE/share/geosite.dat"
begin_transaction || exit 1
rm "$CASE/systemd/xray.service" "$CASE/share/geosite.dat"
printf changed > "$CASE/systemd/xray.service"; printf changed > "$CASE/share/geosite.dat"
rollback_transaction || true
[[ -L "$CASE/systemd/xray.service" && $(readlink "$CASE/systemd/xray.service") == "$CASE/unit-source" ]]
[[ -L "$CASE/share/geosite.dat" && $(readlink "$CASE/share/geosite.dat") == "$CASE/missing-target" ]]
[[ -z "$transaction_backup" ]]
''')

    def test_active_state_query_failure_stops_before_installer(self):
        for state in ('query-failed', 'activating', 'deactivating', 'malformed'):
            with self.subTest(state=state):
                self.run_shell('MODE=' + state + r'''
eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
systemctl() {
 if [[ "$1" == show && "$*" == *ActiveState* ]]; then
  [[ "$MODE" != query-failed ]] || return 1
  echo "ActiveState=$MODE"; return 0
 fi
 original_systemctl "$@"
}
if run_install_ss 8388 "$KEY"; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null || exit 97
[[ -z "$transaction_backup" ]]
''')

    def test_config_backup_does_not_follow_old_backup_link(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
printf KEEP > "$CASE/other-file"
chmod 644 "$CASE/other-file"
ln -s "$CASE/other-file" "$xray_config_path.bak"
s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]" || exit 90
[[ $(< "$CASE/other-file") == KEEP && $(stat -c %a "$CASE/other-file") == 644 ]]
[[ ! -L "$xray_config_path.bak" && $(< "$xray_config_path.bak") == '{}' ]]
[[ $(stat -c %a "$xray_config_path.bak") == 600 ]]
''')

    def test_config_rollback_preserves_live_config_link(self):
        self.run_shell(r'''
printf '{}' > "$CASE/linked-config"
ln -s "$CASE/linked-config" "$xray_config_path"
s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]" || exit 90
[[ ! -L "$xray_config_path" && ! -L "$xray_config_path.bak" ]]
rollback_config_and_restart || exit 91
[[ $(readlink "$xray_config_path") == "$CASE/linked-config" && $(< "$CASE/linked-config") == '{}' ]]
''')

    def test_config_rename_completed_but_returned_failure(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
s=$(build_ss_inbound 8388 "$KEY")
mv() {
    command mv "$@" || return 1
    if [[ "${@: -1}" == "$xray_config_path" && ! -e "$CASE/rename-failed" ]]; then
        touch "$CASE/rename-failed"
        return 1
    fi
}
if write_config "[$s]"; then exit 90; fi
[[ -e "$CASE/rename-failed" && $(< "$xray_config_path") == '{}' && "$config_written" == false ]]
! compgen -G "$CASE/etc/config.json.rollback.*" || exit 97
! grep -q '^systemctl restart' "$CASE/calls" || exit 97
''')

    def test_explicit_success_exit_does_not_hide_recovery_failure(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
(
    trap 'on_exit $?' EXIT
    s=$(build_ss_inbound 8388 "$KEY"); write_config "[$s]" || exit 90
    restore_file() { touch "$CASE/restore-attempted"; return 1; }
    exit 0
) && exit 91 || rc=$?
[[ "$rc" == 1 && -f "$CASE/restore-attempted" ]]
compgen -G "$CASE/etc/config.json.rollback.*" >/dev/null
''')

    def test_incomplete_recovery_blocks_mutating_menu_actions(self):
        self.run_shell(r'''
recovery_pending=true
transaction_backup="$CASE/recovery"
mkdir "$transaction_backup"
draw_menu_header() { :; }
press_any_key_to_continue() { :; }
install_menu() { touch "$CASE/unsafe"; }
update_xray() { touch "$CASE/unsafe"; }
uninstall_xray() { touch "$CASE/unsafe"; }
modify_config_menu() { touch "$CASE/unsafe"; }
restart_xray() { touch "$CASE/unsafe"; }
view_all_info() { touch "$CASE/unsafe"; }
view_xray_log() { touch "$CASE/log-viewed"; }
main_menu <<< $'1\n2\n3\n4\n5\n7\n6' || exit 90
[[ ! -e "$CASE/unsafe" && -f "$CASE/log-viewed" && -d "$transaction_backup" ]]
''')

    def test_public_ip_cache_and_family(self):
        match = re.search(r'^get_public_ip\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        function = match[0].replace('/usr/local/etc/xray', '${CASE}/etc')
        self.run_shell(function + r'''
# Invalid fresh caches must not bypass network validation.
printf '999.1.2.3' > "$CASE/etc/.public-ip"
curl() { printf '%s\n' "$*" >> "$CASE/network"; echo 192.0.2.2; }
[[ $(get_public_ip) == 192.0.2.2 ]]
[[ $(< "$CASE/etc/.public-ip") == 192.0.2.2 ]]
curl() { return 99; }; [[ $(get_public_ip) == 192.0.2.2 ]]
printf '2001:db8::1' > "$CASE/etc/.public-ip"; [[ $(get_public_ip) == 2001:db8::1 ]]
touch -d '2 days ago' "$CASE/etc/.public-ip"
curl() { if [[ "$*" == *api6.ipify.org* ]]; then echo 2001:db8::2; else echo invalid; fi; }
[[ $(get_public_ip) == 2001:db8::2 ]]
rm "$CASE/etc/.public-ip"; rmdir "$CASE/etc"
[[ $(get_public_ip 2> "$CASE/errors") == 2001:db8::2 && ! -s "$CASE/errors" ]]
mkdir -p "$CASE/etc/.public-ip"
[[ $(get_public_ip 2> "$CASE/errors") == 2001:db8::2 && ! -s "$CASE/errors" ]]
curl() { return 99; }; if get_public_ip; then exit 1; fi
''')

    def test_public_ip_rejects_failed_response_and_preserves_cache_target(self):
        match = re.search(r'^get_public_ip\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        self.run_shell(match[0].replace('/usr/local/etc/xray', '${CASE}/etc') + r'''
printf KEEP > "$CASE/unrelated"
ln -s "$CASE/unrelated" "$CASE/etc/.public-ip"
curl() {
    case "${@: -1}" in
        https://api.ipify.org) echo 192.0.2.2; return 22 ;;
        https://ip.sb) echo 192.0.2.3 ;;
        *) return 1 ;;
    esac
}
[[ $(get_public_ip) == 192.0.2.3 ]]
[[ $(< "$CASE/unrelated") == KEEP ]]
[[ $(< "$CASE/etc/.public-ip") == 192.0.2.3 && ! -L "$CASE/etc/.public-ip" ]]
''')

    def test_enablement_scope_on_success_and_rollback(self):
        for enabled in ('enabled', 'enabled-runtime', 'disabled', 'static', 'indirect', 'linked', 'linked-runtime', 'masked', 'masked-runtime'):
            for failure in ('false', 'true'):
                with self.subTest(enabled=enabled, failure=failure):
                    self.run_shell('ENABLED=' + enabled + '; FAIL=' + failure + r'''
printf '{}' > "$xray_config_path"
execute_official_script() {
 if [[ "$1" == install ]]; then printf '# changed\n' >> "$xray_binary_path"; return 0; fi
 ! "$FAIL"
}
run_install_ss 8388 "$KEY" || true
[[ "$ENABLED" == ''' + enabled + r''' && -z "$transaction_backup" ]]
if [[ ''' + enabled + r''' != enabled ]]; then
 ! grep -q '^systemctl enable xray$' "$CASE/calls" || exit 97
fi
''')
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
ENABLED=enabled-runtime
begin_transaction || exit 1
ENABLED=enabled
rollback_transaction || true
[[ "$ENABLED" == enabled-runtime && -z "$transaction_backup" ]]
grep -q '^systemctl enable --runtime xray$' "$CASE/calls"
''')

    def test_enablement_query_failure_stops_before_installer(self):
        self.run_shell(r'''
ENABLED=''
if run_install_ss 8388 "$KEY"; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null || exit 97
[[ -z "$transaction_backup" ]]
''')

    @unittest.skipUnless(os.environ.get('XRAY_TEST_BINARY'), 'set XRAY_TEST_BINARY for non-listening core checks')
    def test_real_core_generated_configs(self):
        self.run_shell('''binary="$XRAY_TEST_BINARY"
keys=$("$binary" x25519); PRIV=$(awk '/PrivateKey:/ {print $2}' <<< "$keys"); PUB=$(awk '/^Password/ {print $NF}' <<< "$keys")
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB"); s=$(build_ss_inbound 8388 "$KEY")
for inbounds in "[$v]" "[$s]" "[$v,$s]"; do
 render_config '{}' "$inbounds" > "$CASE/validate.json"
 "$binary" run -test -config "$CASE/validate.json" || exit 1
done
''')

    @unittest.skipUnless(os.environ.get('XRAY_TEST_BINARY'), 'set XRAY_TEST_BINARY for non-listening migration checks')
    def test_real_core_migration_and_modifiers(self):
        match = re.search(r'^view_all_info\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        view = match[0].replace('/root/xray_subscription_info.txt', '${CASE}/subscription')
        for legacy in ('true', 'false'):
            with self.subTest(legacy=legacy):
                self.run_shell(view + '\nLEGACY=' + legacy + r'''
# Only the non-listening real core CLI is reachable from this shim.
printf '#!/bin/bash\nexec "%s" "$@"\n' "$XRAY_TEST_BINARY" > "$xray_binary_path"
generate_reality_keys || exit 1
PRIV=$reality_private_key; PUB=$reality_public_key
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
if "$LEGACY"; then v=$(jq '.settings.clients=.settings.users | del(.settings.users) | .streamSettings.network="tcp" | del(.streamSettings.method) | .streamSettings.realitySettings.dest=.streamSettings.realitySettings.target | del(.streamSettings.realitySettings.target)' <<< "$v"); fi
s=$(build_ss_inbound 8388 "$KEY")
jq -n --argjson v "$v" --argjson s "$s" '{inbounds:[$v,$s],outbounds:[{protocol:"freedom"}]}' > "$xray_config_path"
"$xray_binary_path" run -test -config "$xray_config_path" || exit 1
STATE=inactive
view_all_info > "$CASE/view-original" || exit 1
cp "$CASE/subscription" "$CASE/original-subscription"
modify_ss_config <<< $'8389\n' > "$CASE/modify-ss" || exit 1
jq -e 'any(.inbounds[]; .protocol=="vless" and .settings.users[0].id!=null and .streamSettings.method=="raw" and .streamSettings.realitySettings.target=="www.sega.com:443") and any(.inbounds[]; .protocol=="shadowsocks" and .port==8389)' "$xray_config_path"
modify_vless_config <<< $'444\n\nwww.example.com' > "$CASE/modify-vless" || exit 1
"$xray_binary_path" run -test -config "$xray_config_path" || exit 1
grep -Fq "vless://${UUID}@192.0.2.1:444?" "$CASE/subscription"
grep -Fq 'type=tcp&security=reality&sni=www.example.com' "$CASE/subscription"
grep -Fq 'ss://2022-blake3-aes-128-gcm:' "$CASE/subscription"
# Negative controls prove users/method/target and SS keys reach the parser.
for filter in '.inbounds |= map(if .protocol=="vless" then .settings.users[0].id="invalid-user-id-with-more-than-thirty-bytes" else . end)' '.inbounds |= map(if .protocol=="vless" then .streamSettings.method="invalid-transport" else . end)' '.inbounds |= map(if .protocol=="vless" then .streamSettings.realitySettings.target="no-port" else . end)' '.inbounds |= map(if .protocol=="shadowsocks" then .settings.password="bad-key" else . end)'; do
 jq "$filter" "$xray_config_path" > "$CASE/invalid.json"
 if "$xray_binary_path" run -test -config "$CASE/invalid.json" > "$CASE/negative-log" 2>&1; then exit 1; fi
done
! grep -q '^systemctl restart' "$CASE/calls" || exit 97
''')

    @unittest.skipUnless(os.environ.get('XRAY_TEST_BINARY'), 'set XRAY_TEST_BINARY for optional REALITY pqv checks')
    def test_real_core_optional_reality_pqv(self):
        match = re.search(r'^view_all_info\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        view = match[0].replace('/root/xray_subscription_info.txt', '${CASE}/subscription')
        self.run_shell(view + r'''
printf '#!/bin/bash\nexec "%s" "$@"\n' "$XRAY_TEST_BINARY" > "$xray_binary_path"
generate_reality_keys || exit 1
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$reality_private_key" "$reality_public_key")
v=$(jq '.streamSettings.realitySettings.mldsa65Seed="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' <<< "$v")
render_config '{}' "[$v]" > "$xray_config_path"
"$xray_binary_path" run -test -config "$xray_config_path" || exit 1
view_all_info > "$CASE/view" || exit 1
python3 - "$CASE/subscription" "$CASE/client.json" <<'PY'
import base64, json, sys
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
q = parse_qs(urlsplit(Path(sys.argv[1]).read_text().strip()).query)
assert len(base64.urlsafe_b64decode(q['pqv'][0] + '=')) == 1952
assert q['type'] == ['tcp'] and 'pbk' in q
Path(sys.argv[2]).write_text(json.dumps({'outbounds':[{'protocol':'vless','settings':{'address':'192.0.2.1','port':443,'id':'00112233-4455-4677-8899-aabbccddeeff','flow':'xtls-rprx-vision','encryption':'none'},'streamSettings':{'method':'raw','security':'reality','realitySettings':{'serverName':'www.sega.com','fingerprint':'chrome','password':q['pbk'][0],'shortId':'20220701','mldsa65Verify':q['pqv'][0]}}}]}))
PY
"$xray_binary_path" run -test -config "$CASE/client.json" || exit 1
STATE=inactive
modify_vless_config <<< $'\n\n\n' > "$CASE/modify" || exit 1
jq -e '.inbounds[0].streamSettings.realitySettings.mldsa65Seed=="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' "$xray_config_path"
"$xray_binary_path" run -test -config "$xray_config_path" || exit 1
# No derived result (or even valid-looking output on nonzero exit) may replace a subscription.
cp "$CASE/subscription" "$CASE/original-subscription"
for MODE in malformed failed; do
 printf '#!/bin/bash\nprintf "Verify: bad\\n"\nexit 0\n' > "$xray_binary_path"
 if [[ "$MODE" == failed ]]; then printf '#!/bin/bash\n"%s" "$@"\nexit 9\n' "$XRAY_TEST_BINARY" > "$xray_binary_path"; fi
 if view_all_info > "$CASE/failure"; then exit 1; fi
 cmp "$CASE/subscription" "$CASE/original-subscription"
done
''')

    @unittest.skipUnless(os.environ.get('PINNED_INSTALLER'), 'set PINNED_INSTALLER for relocated official-write checks')
    def test_actual_pinned_write_failures(self):
        self.run_shell(r'''
cp "$PINNED_INSTALLER" "$CASE/official-data"
normalize_official_writes "$CASE/official-data" || exit 1
# Fail closed if the fixed source changes or a patch is applied twice.
if normalize_official_writes "$CASE/official-data"; then exit 1; fi
cp "$PINNED_INSTALLER" "$CASE/duplicate"
printf '\n  install -d "$DAT_PATH"\n# duplicate sentinel\n' >> "$CASE/duplicate"
if normalize_official_writes "$CASE/duplicate"; then exit 1; fi
# Full official source is data only; execute extracted, reviewed functions.
python3 - "$CASE/official-data" "$CASE/official-functions" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
names = ('install_file', 'install_geodata')
functions = []
for name in names:
 m = re.search(r'^' + name + r'\(\) \{\n.*?^\}', s, re.M | re.S)
 assert m
 functions.append(m[0].replace('/usr/local/bin', '${CASE}/bin'))
Path(sys.argv[2]).write_text('\n'.join(functions))
PY
source "$CASE/official-functions"
TMP_DIRECTORY="$CASE/staging"; DAT_PATH="$CASE/share"
mkdir "$TMP_DIRECTORY"; printf binary > "$TMP_DIRECTORY/xray"
install_file xray || exit 1
[[ $(< "$CASE/bin/xray") == binary ]]
# Core write failure exits even in a conditional.
install() { return 1; }
if ( install_file xray ); then exit 1; fi
# Geodata download/checksum boundaries mocked; required local writes real/mocked.
curl() { local prev='' arg; for arg; do if [[ "$prev" == -o ]]; then printf data > "$arg"; fi; prev="$arg"; done; }
sha256sum() { return 0; }
XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=1; PROXY=''
for FAIL_AT in 1 2 3 0; do
 printf 0 > "$CASE/write-count"
 install() {
  local count; count=$(< "$CASE/write-count"); count=$((count+1)); printf '%s' "$count" > "$CASE/write-count"
  [[ "$count" != "$FAIL_AT" ]] || return 1
  command install "$@"
 }
 if ( install_geodata ); then [[ "$FAIL_AT" == 0 ]] || exit 1
 else [[ "$FAIL_AT" != 0 ]] || exit 1; fi
 [[ $(< "$CASE/write-count") == "$FAIL_AT" || "$FAIL_AT" == 0 ]]
done
[[ $(< "$CASE/share/geoip.dat") == data && $(< "$CASE/share/geosite.dat") == data ]]
''')

    @unittest.skipUnless(os.environ.get('PINNED_INSTALLER'), 'set PINNED_INSTALLER for relocated official-main checks')
    def test_actual_pinned_main(self):
        import hashlib
        pinned = Path(os.environ['PINNED_INSTALLER']).read_text()
        self.assertEqual(hashlib.sha256(pinned.encode()).hexdigest(),
                         '7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555')
        match = re.search(r'^main\(\) \{\n.*?^\}', pinned, re.M | re.S)
        assert match is not None
        main = match.group()
        main = main.replace("'/etc/systemd/system/xray.service'", '"$CASE/systemd/xray.service"')
        # Only the exact upstream main is executed; every reachable helper is mocked.
        self.run_shell(r'''
cp "$PINNED_INSTALLER" "$CASE/official-data"
normalize_official_script "$CASE/official-data" || exit 1
normalize_official_writes "$CASE/official-data" || exit 1
python3 - "$CASE/official-data" "$CASE/official-main" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
m = re.search(r'^main\(\) \{\n.*?^\}', s, re.M | re.S)
assert m
Path(sys.argv[2]).write_text(m[0].replace("'/etc/systemd/system/xray.service'", '"$CASE/systemd/xray.service"'))
PY
source "$CASE/official-main"
check_if_running_as_root() { [[ "$MODE" != root ]]; }
identify_the_operating_system_and_architecture() { [[ "$MODE" != os ]]; }
judgment_parameters() { [[ "$MODE" != args ]]; }
install_software() { :; }; tput() { :; }; check_install_user() { :; }
get_current_version() { CURRENT_VERSION=1.0.0; }
get_latest_version() { RELEASE_LATEST=2.0.0; }
version_gt() { return 0; }
download_xray() { [[ "$MODE" != download ]]; }
decompression() { :; }; pidof() { [[ "$MODE" == active ]] && echo 123; }
stop_xray() { :; }; start_xray() { [[ "$MODE" != startfail ]]; }
install_xray() { [[ "$MODE" != corewritefail ]] || return 1; printf installed > "$CASE/installed"; }
install_startup_service_file() { printf overwritten > "$CASE/systemd/xray.service"; }
systemctl() { if [[ "$1" == list-unit-files ]]; then echo xray.service; fi; }
package_provide_tput=tput; HELP=0; CHECK=0; REMOVE=0; INSTALL_GEODATA=0; LOGROTATE=0
LOCAL_FILE=''; REINSTALL=0; SPECIFIED_VERSION=''; FORCE=0; BETA=0; MACHINE=test
N_UP_SERVICE=1; GEODATA=0; CONFIG_NEW=0; CONFDIR=0; LOG=0; LOGROTATE_FIN=0; SYSTEMD=0
PACKAGE_MANAGEMENT_REMOVE=mock; XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=1; XRAY_RUNNING=0
for MODE in stopped active; do ( main ) || exit 1; done
[[ $(< "$CASE/systemd/xray.service") == old-unit && -e "$CASE/installed" ]]
for MODE in root os args download corewritefail; do if ( main ); then exit 1; fi; done
MODE=startfail; XRAY_RUNNING=1
if ( main ); then exit 1; fi
''')

    def test_probe_failure_on_unchanged_ports(self):
        self.run_shell('''s=$(build_ss_inbound 8388 "$KEY"); render_config '{}' "[$s]" > "$xray_config_path"
ss() { return 2; }
if is_port_available_for 8388 shadowsocks; then exit 1; else [[ $? == 2 ]]; fi
if modify_ss_config <<< $'\\n\\n'; then exit 1; fi
! grep -q 'systemctl restart' "$CASE/calls" 2>/dev/null || exit 97
''')

    def test_transaction_stop_failure_retains_everything(self):
        self.run_shell('''rm "$xray_binary_path" "$CASE/systemd/xray.service"; STATE=inactive
execute_official_script() { if [[ "$1" == install ]]; then printf new > "$xray_binary_path"; printf '{}' > "$xray_config_path"; printf unit > "$CASE/systemd/xray.service"; return 0; fi; return 1; }
systemctl() { [[ "$1" != stop && "$1" != is-active && "$1" != is-enabled ]]; }
run_install_ss 8388 "$KEY" || true
[[ -e "$xray_binary_path" && -e "$xray_config_path" && -e "$CASE/systemd/xray.service" && -d "$transaction_backup" ]]
''')

    def test_rollback_metadata(self):
        self.run_shell('''printf '{"inbounds":[]}' > "$xray_config_path"; chmod 604 "$xray_config_path"; touch -t 202001010101 "$xray_config_path"
cp -p "$xray_config_path" "$CASE/original"
execute_official_script() { if [[ "$1" == install ]]; then printf changed > "$xray_config_path"; chmod 600 "$xray_config_path"; return 0; fi; return 1; }
run_install_ss 8388 "$KEY" || true
cmp "$CASE/original" "$xray_config_path"
[[ $(stat -c '%a:%u:%g:%Y' "$xray_config_path") == $(stat -c '%a:%u:%g:%Y' "$CASE/original") ]]
''')

    def test_empty_existing_config_supported(self):
        self.run_shell('''printf '{}' > "$xray_config_path"
run_install_ss 8388 "$KEY" || exit 1
jq -e '.inbounds[0].tag == "xray-dual-ss"' "$xray_config_path"
''')

    def test_both_single_protocol_directions(self):
        self.run_shell('''s=$(build_ss_inbound 8388 "$KEY"); render_config '{}' "[$s]" > "$xray_config_path"
generate_reality_keys() { reality_private_key="$PRIV"; reality_public_key="$PUB"; }
if run_install_vless 8388 "$UUID" www.sega.com; then exit 1; fi
run_install_vless 443 "$UUID" www.sega.com || exit 1
jq -e '[.inbounds[].port]|sort == [443,8388]' "$xray_config_path"
''')

    def test_install_failure_phases_restore_baseline(self):
        for phase in ('core', 'keys', 'config', 'restart', 'subscription'):
            with self.subTest(phase=phase):
                self.run_shell('PHASE=' + phase + '''
printf '{"inbounds":[]}' > "$xray_config_path"
cp -p "$xray_binary_path" "$CASE/original"; cp -p "$xray_config_path" "$CASE/config-original"
execute_official_script() {
 if [[ "$1" == install ]]; then
  printf '%s\\n' '#!/bin/bash' '# updated' 'exit 0' > "$xray_binary_path"
  STATE=inactive
  [[ "$PHASE" != core ]] || return 1
 fi
 return 0
}
generate_reality_keys() { [[ "$PHASE" != keys ]] || return 1; reality_private_key="$PRIV"; reality_public_key="$PUB"; }
if [[ "$PHASE" == config ]]; then build_vless_inbound() { return 1; }; fi
if [[ "$PHASE" == restart ]]; then
 restart_xray() { if cmp -s "$CASE/original" "$xray_binary_path"; then STATE=active; return 0; fi; return 1; }
fi
if [[ "$PHASE" == subscription ]]; then view_all_info() { return 1; }; fi
if run_install_vless 443 "$UUID" www.sega.com; then exit 1; fi
cmp "$CASE/original" "$xray_binary_path"; cmp "$CASE/config-original" "$xray_config_path"
[[ "$STATE" == active && -z "$transaction_backup" ]]
''')

    def test_restart_pid_required(self):
        self.run_shell('''systemctl() { case "$1" in show) echo 0;; *) return 0;; esac; }
if restart_xray; then exit 1; fi
''')

    def test_config_single_object_before_consumers(self):
        match = re.search(r'^view_all_info\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        view = relocate(match[0])
        for document in ('{} {}', 'null', '[]', ''):
            with self.subTest(document=document):
                self.run_shell(view + '\nDOCUMENT=' + __import__('shlex').quote(document) + r'''
printf '%s' "$DOCUMENT" > "$xray_config_path"
printf ORIGINAL > "$CASE/subscription"
if get_managed_inbound shadowsocks > "$CASE/result" 2> "$CASE/reject"; then exit 81; fi
grep -q 'JSON' "$CASE/reject"
if view_all_info > "$CASE/view" 2>&1; then exit 82; fi
[[ $(< "$CASE/subscription") == ORIGINAL ]]
s=$(jq -nc --arg key "$KEY" '{tag:"xray-dual-ss",port:8388,protocol:"shadowsocks",settings:{method:"2022-blake3-aes-128-gcm",password:$key}}')
if write_config "[$s]"; then exit 83; fi
[[ $(< "$xray_config_path") == "$DOCUMENT" ]]
if update_xray > "$CASE/update" 2>&1; then exit 84; fi
! grep -q '^official' "$CASE/calls" 2>/dev/null || exit 97
''')

    def test_reinstall_keeps_documented_restart_policy(self):
        self.run_shell(r'''
STATE=inactive
printf '{}' > "$xray_config_path"
run_install_ss 8388 "$KEY" || exit 80
[[ "$STATE" == active ]]
grep -q '^systemctl restart' "$CASE/calls"
generate_reality_keys() { reality_private_key="$PRIV"; reality_public_key="$PUB"; }
STATE=inactive
run_install_vless 443 "$UUID" www.sega.com || exit 81
STATE=inactive
run_install_dual 443 "$UUID" www.sega.com 8388 "$KEY" || exit 82
[[ "$STATE" == active ]]
''')

    @unittest.skipUnless(os.environ.get('PINNED_INSTALLER'), 'set PINNED_INSTALLER for exact anchor checks')
    def test_official_patch_anchor_boundaries(self):
        self.run_shell(r'''
python3 - "$PINNED_INSTALLER" "$CASE" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
needles=[
    '    [[ "$XRAY_RUNNING" -eq \'1\' ]] && start_xray',
    '    install -m 755 "${TMP_DIRECTORY}/$NAME" "/usr/local/bin/$NAME"',
    '  install -d "$DAT_PATH"',
    '  install -m 644 "${dir_tmp}"/${file_dlc} "${DAT_PATH}"/${file_site}',
    '  install -m 644 "${dir_tmp}"/${file_ip} "${DAT_PATH}"/${file_ip}',
    '  install_file xray',
    '  install_xray',
]
for i,needle in enumerate(needles):
    assert s.count('\n'+needle+'\n')==1
    for kind, replacement in [('duplicate',needle+'\n'+needle),('prefix',needle+' # changed'),('suffix',needle+' extra')]:
        Path(sys.argv[2],f'{i}-{kind}').write_text(s.replace(needle,replacement))
PY
unexpected=false
for i in 0 1 2 3 4 5 6; do
 for variant in duplicate prefix suffix; do
  cp "$CASE/$i-$variant" "$CASE/probe"
  accepted=false
  if [[ "$i" == 0 ]]; then
   normalize_official_script "$CASE/probe" && accepted=true
  else
   normalize_official_writes "$CASE/probe" && accepted=true
  fi
  if "$accepted"; then printf 'unexpected anchor acceptance: %s-%s\n' "$i" "$variant" >&2; unexpected=true
  else cmp "$CASE/probe" "$CASE/$i-$variant" || exit 83; fi
 done
done
[[ "$unexpected" == false ]]
''')

    def test_dual_reinstall_validates_final_not_old_managed_ports(self):
        self.run_shell(r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
s=$(build_ss_inbound 8388 "$KEY")
render_config '{}' "[$v,$s]" > "$xray_config_path"
generate_reality_keys() { reality_private_key="$PRIV"; reality_public_key="$PUB"; }
run_install_dual 8388 "$UUID" www.sega.com 443 "$KEY" || exit 81
jq -e '.inbounds | any(.[]; .protocol=="vless" and .port==8388) and any(.[]; .protocol=="shadowsocks" and .port==443)' "$xray_config_path"
# The interactive caller has the same final-set semantics, including occupied
# sockets belonging to the managed inbounds that will be replaced.
ss() { printf 'LISTEN 0 0 *:443 *:* users:xray\nLISTEN 0 0 *:8388 *:* users:xray\n'; }
install_dual <<< $'443\n00112233-4455-4677-8899-aabbccddeeff\nwww.sega.com\n8388\nAAAAAAAAAAAAAAAAAAAAAA==' || exit 82
jq -e '.inbounds | any(.[]; .protocol=="vless" and .port==443) and any(.[]; .protocol=="shadowsocks" and .port==8388)' "$xray_config_path"
printf '{"inbounds":[{"tag":"custom","port":"9000-9010","protocol":"socks"}]}' > "$xray_config_path"
if run_install_dual 9001 "$UUID" www.sega.com 9002 "$KEY"; then exit 83; fi
''')

    @unittest.skipUnless(os.environ.get('XRAY_TEST_BINARY'), 'set XRAY_TEST_BINARY for multi-user config and sharing checks')
    def test_real_core_ss_multiuser_export_uses_user_key(self):
        match = re.search(r'^view_all_info\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        for legacy in ('true', 'false'):
            with self.subTest(legacy=legacy):
                self.run_shell(relocate(match[0]) + '\nLEGACY=' + legacy + r'''
USER_KEY=AQEBAQEBAQEBAQEBAQEBAQ==
s=$(build_ss_inbound 8388 "$KEY" | jq --arg user "$USER_KEY" '.settings.users=[{password:$user,email:"first"},{password:$user,email:"extra"}]')
if "$LEGACY"; then s=$(jq '.settings.clients=.settings.users | .settings.users=[{password:"ignored"}]' <<< "$s"); fi
render_config '{}' "[$s]" > "$xray_config_path"
"$XRAY_TEST_BINARY" run -test -config "$xray_config_path" > "$CASE/core-log" 2>&1 || exit 80
view_all_info > "$CASE/view" || exit 81
python3 - "$CASE/subscription" "$KEY:$USER_KEY" "$CASE/client.json" <<'PY'
import json,sys
from pathlib import Path
from urllib.parse import urlsplit,unquote
uri=urlsplit(Path(sys.argv[1]).read_text().strip())
assert unquote(uri.password)==sys.argv[2], 'missing effective SS-2022 user key'
Path(sys.argv[3]).write_text(json.dumps({'outbounds':[{'protocol':'shadowsocks','settings':{'address':'192.0.2.1','port':8388,'method':unquote(uri.username),'password':unquote(uri.password)}}]}))
PY
"$XRAY_TEST_BINARY" run -test -config "$CASE/client.json" > "$CASE/client-log" 2>&1 || exit 82
STATE=inactive
modify_ss_config <<< $'8389\n\n' > "$CASE/modify" || exit 83
jq -e --arg key "$USER_KEY" '(.inbounds[0].settings.clients // .inbounds[0].settings.users) | length==2 and .[1].email=="extra" and .[0].password==$key' "$xray_config_path"
''')

    def test_export_invalid_metadata_retains_previous_subscription(self):
        match = re.search(r'^view_all_info\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        for filter_ in ('.inbounds[0].port=0', '.inbounds[0].settings.users[0].id=null',
                        '.inbounds[0].streamSettings.realitySettings.serverNames=[]',
                        '.inbounds[0].streamSettings.realitySettings.shortIds=["zz"]',
                        '.inbounds[1].settings.password=null', '.inbounds[1].settings.method="invalid"'):
            with self.subTest(filter=filter_):
                self.run_shell(relocate(match[0]) + '\nFILTER=' + __import__('shlex').quote(filter_) + r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
s=$(build_ss_inbound 8388 "$KEY")
render_config '{}' "[$v,$s]" | jq "$FILTER" > "$xray_config_path"
printf ORIGINAL > "$CASE/subscription"
if view_all_info > "$CASE/view" 2> "$CASE/rejected"; then exit 81; fi
grep -q '配置' "$CASE/rejected"
[[ $(< "$CASE/subscription") == ORIGINAL ]]
''')

    def test_vless_export_matches_effective_flow_and_empty_shortid(self):
        match = re.search(r'^view_all_info\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S)
        assert match
        self.run_shell(relocate(match[0]) + r'''
v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB" | jq '.settings.users[0].flow="" | .streamSettings.realitySettings.shortIds=[""]')
render_config '{}' "[$v]" > "$xray_config_path"
view_all_info > "$CASE/view" || exit 80
! grep -q 'flow=' "$CASE/subscription" || exit 97
grep -Fq '&sid=#' "$CASE/subscription"
v=$(jq 'del(.settings.users[0].flow) | .settings.flow="xtls-rprx-vision"' <<< "$v")
render_config '{}' "[$v]" > "$xray_config_path"
view_all_info > "$CASE/view" || exit 81
grep -q 'flow=xtls-rprx-vision' "$CASE/subscription"
''')

    def test_cli_parser_matrix_and_precheck_dependency_boundary(self):
        source = SOURCE.read_text()
        dispatcher = re.search(r'^non_interactive_dispatcher\(\) \{\n.*?^\}', source, re.M | re.S)
        precheck = re.search(r'^pre_check\(\) \{\n.*?^\}', source, re.M | re.S)
        assert dispatcher and precheck
        self.run_shell(relocate(precheck[0]) + r'''
printf debian > "$CASE/debian-version"
id() { if [[ "${1:-}" == -u ]]; then echo 0; else command id "$@"; fi; }
command() {
 if [[ "${1:-}" == -v && "${2:-}" == pgrep && ! -f "$CASE/installed-procps" ]]; then return 1; fi
 builtin command "$@"
}
apt-get() { printf '%s\n' "$*" >> "$CASE/packages"; if [[ "$*" == *'install -y'* ]]; then touch "$CASE/installed-procps"; fi; }
pre_check || exit 80
grep -q 'DPkg::Lock::Timeout=600 install -y jq curl iproute2 openssl coreutils procps' "$CASE/packages"
''')
        self.run_shell(relocate(dispatcher[0]) + r'''
printf '%s' "$UUID" > "$CASE/random-uuid"
pre_check() { touch "$CASE/precheck"; }
run_install_vless() { printf 'vless %s\n' "$*" >> "$CASE/install-args"; }
run_install_ss() { printf 'ss %s\n' "$*" >> "$CASE/install-args"; }
run_install_dual() { printf 'dual %s\n' "$*" >> "$CASE/install-args"; }
for args in 'install --type' 'install --type invalid' 'install --type ss --unknown value' 'install --type ss --ss-port' 'install --type dual --ss-pass'; do
 if ( non_interactive_dispatcher $args ); then exit 81; else [[ $? == 2 ]] || exit 82; fi
done
non_interactive_dispatcher install --help || exit 83
[[ ! -e "$CASE/precheck" && ! -e "$CASE/install-args" ]]
non_interactive_dispatcher install --type vless --uuid "$UUID" || exit 84
non_interactive_dispatcher install --type ss --ss-pass "$KEY" || exit 85
non_interactive_dispatcher install --type dual --vless-port 65535 --ss-port 1 --uuid "$UUID" --ss-pass "$KEY" || exit 86
[[ $(wc -l < "$CASE/install-args") == 3 ]]
grep -q 'dual 65535 .* www.sega.com 1' "$CASE/install-args"
''')

    @unittest.skipUnless(os.environ.get('PINNED_INSTALLER'), 'set PINNED_INSTALLER for actual remover checks')
    def test_actual_pinned_remover_and_incomplete_uninstalls(self):
        pinned = Path(os.environ['PINNED_INSTALLER']).read_text()
        match = re.search(r'^remove_xray\(\) \{\n.*?^\}', pinned, re.M | re.S)
        assert match
        self.run_shell(relocate(match[0]) + r'''
# Complete installs exercise the pinned removal logic, not a successful mock.
eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
systemctl() {
 if [[ "$1" == list-unit-files ]]; then echo xray.service
 else original_systemctl "$@"; fi
}
JSON_PATH="$CASE/etc"; JSONS_PATH=''; DAT_PATH="$CASE/share"; PURGE=1; PACKAGE_MANAGEMENT_REMOVE=mock
execute_official_script() { printf 'official %s\n' "$*" >> "$CASE/calls"; ( remove_xray ); }
printf '{}' > "$xray_config_path"
printf template > "$CASE/systemd/xray@.service"
mkdir "$CASE/systemd/xray.service.d" "$CASE/systemd/xray@.service.d"
printf override > "$CASE/systemd/xray.service.d/custom.conf"
uninstall_xray <<< y || exit 80
grep -q '^official remove --purge$' "$CASE/calls"
[[ ! -e "$xray_binary_path" && ! -e "$xray_config_path" && ! -e "$CASE/systemd/xray.service" ]]
# xray-dual has no self-delete contract; only this disposable function fixture
# is executed, and its own script must remain available for repeated actions.
[[ -f "$0" ]]
for residue in binary config main template dropin; do
 mkdir -p "$CASE/etc" "$CASE/bin" "$CASE/systemd"
 case "$residue" in
  binary) printf core > "$xray_binary_path" ;;
  config) printf '{}' > "$xray_config_path" ;;
  main) printf unit > "$CASE/systemd/xray.service" ;;
  template) printf template > "$CASE/systemd/xray@.service" ;;
  dropin) mkdir "$CASE/systemd/xray@.service.d"; printf custom > "$CASE/systemd/xray@.service.d/custom.conf" ;;
 esac
 execute_official_script() { printf unexpected >> "$CASE/unsafe-official"; return 99; }
 uninstall_xray <<< y || exit 81
 [[ ! -e "$xray_binary_path" && ! -e "$xray_config_path" && ! -e "$CASE/systemd/xray.service" && ! -e "$CASE/systemd/xray@.service" && ! -e "$CASE/systemd/xray@.service.d" ]]
done
[[ ! -e "$CASE/unsafe-official" ]]
''')

    def test_menu_routes_and_prompt_failures_in_actual_or_list(self):
        self.run_shell(r'''
generate_reality_keys() { reality_private_key="$PRIV"; reality_public_key="$PUB"; }
draw_menu_header() { :; }
# EOF must prevent any installer call even under handler || true.
install_vless_only </dev/null || true
install_ss_only </dev/null || true
install_dual </dev/null || true
[[ ! -f "$CASE/calls" ]]
install_menu <<< 0 || exit 80
clean_install_menu <<< 0 || exit 81
# Route choices dispatch actual handlers; only external effects remain mocked.
s=$(build_ss_inbound 8388 "$KEY")
render_config '{}' "[$s]" > "$xray_config_path"
modify_config_menu <<< $'1\n8389\n\n' || exit 82
jq -e '.inbounds[0].port==8389' "$xray_config_path"
add_vless_to_ss <<< $'443\n00112233-4455-4677-8899-aabbccddeeff\nwww.sega.com' || exit 83
jq -e '.inbounds|length==2' "$xray_config_path"
modify_config_menu <<< 0 || exit 84
''')

    def test_validators_numeric_ip_and_version_boundaries(self):
        self.run_shell(r'''
for port in 1 443 65535; do is_valid_port "$port" || exit 80; done
for port in 0 00 0443 65536 -1 +1 1.1 999999999999999999999999999999999; do
 if is_valid_port "$port"; then exit 81; fi
done
for ip in :: ::1 2001:db8:: 1:2:3:4:5:6:7:8; do is_valid_ipv6 "$ip" || exit 82; done
for ip in :1::2 1::2: 1:::2 1::2::3 12345::1 1:2:3:4:5:6:7 ::1:2:3:4:5:6:7:8; do
 if is_valid_ipv6 "$ip"; then exit 83; fi
done
for ip in 0.0.0.0 192.0.2.1 255.255.255.255; do is_valid_ipv4 "$ip" || exit 84; done
for ip in 01.1.2.3 256.1.2.3 1.2.3 1.2.3.4.5; do if is_valid_ipv4 "$ip"; then exit 85; fi; done
for version in v26.11.9 26.11.9 26.11.9-beta.1; do normalize_version "$version" || exit 86; done
for version in null v invalid 26.11 '26.11.9 injected'; do if normalize_version "$version"; then exit 87; fi; done
''')

    def test_freedom_effective_strategy_empty_and_asis_fallback(self):
        self.run_shell(r'''
for spec in '{"targetStrategy":"AsIs","settings":{"targetStrategy":"UseIPv4","domainStrategy":"UseIPv6"}}' '{"targetStrategy":"","settings":{"targetStrategy":"","domainStrategy":"UseIPv4"}}' '{"targetStrategy":"UseIPv4","settings":{"targetStrategy":"UseIPv6"}}'; do
 existing=$(jq -nc --argjson spec "$spec" '{outbounds:[({protocol:"freedom",streamSettings:{sockopt:{domainStrategy:"UseIPv6"}}}+$spec)]}')
 render_config "$existing" '[]' | jq -e '.outbounds[0] | .streamSettings.sockopt.domainStrategy=="UseIPv4" and (has("targetStrategy")|not) and (.settings|has("domainStrategy")|not)' || exit 80
done
render_config '{"outbounds":[{"protocol":"freedom","settings":{"targetStrategy":"AsIs","domainStrategy":"UseIPv4"},"streamSettings":{"sockopt":{"domainStrategy":"UseIPv6"}}}]}' '[]' | jq -e '.outbounds[0].streamSettings.sockopt.domainStrategy=="UseIPv6"' || exit 81
''')

    def test_fixture_path_relocation_is_token_bounded(self):
        self.assertEqual(relocate('"/usr/local/etc/xray-old" /usr/local/etc/xray/config.json'),
                         '"/usr/local/etc/xray-old" ${CASE}/etc/config.json')
        self.assertEqual(relocate("'/etc/systemd/system/xray.service'"),
                         '"${CASE}/systemd/xray.service"')

    def test_service_query_failed_stdout_is_not_a_snapshot(self):
        for phase in ('active', 'enablement'):
            with self.subTest(phase=phase):
                self.run_shell('PHASE=' + phase + r'''
printf '{}' > "$xray_config_path"
eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
systemctl() {
 if [[ "$PHASE" == active && "$1" == show && "$*" == *ActiveState* ]]; then echo ActiveState=inactive; return 2; fi
 if [[ "$PHASE" == enablement && "$1" == is-enabled ]]; then echo enabled; return 2; fi
 original_systemctl "$@"
}
if run_install_ss 8388 "$KEY"; then exit 81; fi
[[ -z "$transaction_backup" ]]
if grep -q '^official' "$CASE/calls" 2>/dev/null; then exit 82; fi
''')

    def test_update_failed_version_output_is_rejected_before_installer(self):
        for phase in ('version', 'latest'):
            with self.subTest(phase=phase):
                self.run_shell('PHASE=' + phase + r'''
printf '{}' > "$xray_config_path"
if [[ "$PHASE" == version ]]; then
 printf '#!/bin/bash\nprintf "Xray 1.0.0\\n"\nexit 7\n' > "$xray_binary_path"
else
 curl() { printf '{"tag_name":"v2.0.0"}\n'; return 22; }
fi
if update_xray; then exit 81; fi
if grep -q '^official' "$CASE/calls" 2>/dev/null; then exit 82; fi
[[ -z "$transaction_backup" ]]
''')

    def test_information_helpers_and_main_help_without_entrypoint(self):
        source = SOURCE.read_text()
        main = re.search(r'^main\(\) \{\n.*?^\}', source, re.M | re.S)
        assert main
        self.run_shell(main[0] + r'''
non_interactive_dispatcher() { touch "$CASE/dispatcher"; }
( main --help ) > "$CASE/help" || exit 80
[[ ! -e "$CASE/dispatcher" ]]
grep -q -- '--ss-pass' "$CASE/help"
if ( main --help extra ); then exit 81; else [[ $? == 2 ]]; fi
main install --type ss || exit 82
[[ -f "$CASE/dispatcher" ]]
SCRIPT_VERSION=v26.11.22
check_xray_status || exit 83
[[ "$xray_status_info" == *1.0.0* ]]
draw_menu_header > "$CASE/header" || exit 84
grep -q 'Version: v26.11.22' "$CASE/header"
press_any_key_to_continue <<< a || exit 85
journalctl() { printf '%s\n' "$*" > "$CASE/journal"; }
view_xray_log || exit 86
[[ $(< "$CASE/journal") == '-u xray -f --no-pager' ]]
''')

    def test_real_failed_transaction_stays_pending_across_menu_actions(self):
        self.run_shell(r'''
printf '{}' > "$xray_config_path"
cp "$xray_binary_path" "$CASE/original-core"
execute_official_script() {
 printf 'official %s\n' "$*" >> "$CASE/calls"
 if [[ "$1" == install ]]; then printf changed > "$xray_binary_path"; return 0; fi
 return 1
}
restore_file() { printf attempted >> "$CASE/restores"; return 1; }
draw_menu_header() { :; }
press_any_key_to_continue() { :; }
view_xray_log() { touch "$CASE/log-viewed"; }
# The first real update fails and cannot restore. Every later menu mutation
# must leave the original active recovery reference and its bytes untouched.
main_menu <<< $'2\n4\n2\n1\n3\n5\n7\n6' || exit 80
[[ "$recovery_pending" == true && -d "$transaction_backup" && -f "$CASE/log-viewed" ]]
cmp "$CASE/original-core" "$transaction_backup/0"
[[ $(grep -c '^official' "$CASE/calls") == 2 ]]
[[ $(< "$xray_config_path") == '{}' && $(< "$xray_binary_path") == changed ]]
''')

    def test_palette_respects_both_output_descriptors(self):
        import pty
        source = SOURCE.read_text()
        palette = source.split("red='' green=''", 1)[1].split('readonly red green', 1)[0]
        palette = "red='' green=''" + palette
        error = re.search(r'^error\(\) \{\n.*?^\}', source, re.M | re.S)
        assert error
        with tempfile.TemporaryDirectory(prefix='xray-dual-palette-', dir=os.environ.get('TMPDIR')) as root:
            fixture = Path(root)/'palette.sh'
            fixture.write_text(palette + '\n' + error[0] + '\nprintf "%s" "$red"\nerror plain\n')
            for tty_out, tty_err, env in ((True, True, {'TERM':'xterm'}),
                                          (False, True, {'TERM':'xterm'}),
                                          (True, False, {'TERM':'xterm'}),
                                          (True, True, {'TERM':'dumb'}),
                                          (True, True, {'TERM':'xterm', 'NO_COLOR':'1'})):
                with self.subTest(stdout_tty=tty_out, stderr_tty=tty_err, env=env):
                    master, slave = pty.openpty()
                    try:
                        p = subprocess.run(['bash', str(fixture)],
                                           stdout=slave if tty_out else subprocess.PIPE,
                                           stderr=slave if tty_err else subprocess.PIPE,
                                           env={k:v for k,v in {**os.environ, **env}.items()
                                                if k != 'NO_COLOR' or 'NO_COLOR' in env}, timeout=5)
                        os.close(slave); slave = None
                        data = b''
                        while True:
                            try:
                                chunk = os.read(master, 4096)
                            except OSError:
                                break
                            if not chunk:
                                break
                            data += chunk
                        data += (p.stdout or b'') + (p.stderr or b'')
                        self.assertEqual(p.returncode, 0)
                        self.assertEqual(b'\x1b[' in data, tty_out and tty_err and env.get('TERM') != 'dumb' and 'NO_COLOR' not in env)
                    finally:
                        os.close(master)
                        if slave is not None:
                            os.close(slave)

    def test_native_dual_stack_and_preserved_listen(self):
        self.run_shell('''s=$(build_ss_inbound 8388 "$KEY"); [[ $(jq -r .listen <<< "$s") == :: ]]
printf '{"inbounds":[{"tag":"xray-dual-ss","listen":"127.0.0.1","port":8388,"protocol":"shadowsocks"}]}' > "$xray_config_path"
s=$(build_ss_inbound 8388 "$KEY"); [[ $(jq -r .listen <<< "$s") == 127.0.0.1 ]]
rm "$xray_config_path"; printf 1 > "$CASE/ipv6/conf/all/disable_ipv6"
s=$(build_ss_inbound 8388 "$KEY"); [[ $(jq -r .listen <<< "$s") == 0.0.0.0 ]]
''')

if __name__ == '__main__':
    unittest.main(verbosity=2)
