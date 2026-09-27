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

class Regression(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory(prefix='xray-dual-test-', dir=os.environ.get('TMPDIR')) as root:
            source = SOURCE.read_text()
            functions = re.findall(r'^([a-zA-Z_]\w*)\(\) \{\n(.*?)^\}', source, re.M | re.S)
            lib = '\n'.join(f'{name}() {{\n{code}\n}}' for name, code in functions
                            if name not in ('main', 'non_interactive_dispatcher', 'pre_check'))
            lib += '\n' + '\n'.join(re.findall(r'^(?:info|success|warning)\(\) \{.*?\}$', source, re.M))
            for old, new in [('/usr/local/etc/xray', '${CASE}/etc'),
                             ('/usr/local/share/xray', '${CASE}/share'),
                             ('/etc/systemd/system', '${CASE}/systemd'),
                             ('/var/log/xray', '${CASE}/log'),
                             ('/root/xray_subscription_info.txt', '${CASE}/subscription'),
                             ('/var/tmp/xray-', '${CASE}/xray-'),
                             ('/proc/sys/net/ipv6', '${CASE}/ipv6'),
                             ('/proc/', '${CASE}/proc/')]:
                lib = lib.replace(old, new)
            setup = r'''
set -euo pipefail
red='' green='' yellow='' magenta='' cyan='' none=''
xray_config_path="$CASE/etc/config.json"; xray_binary_path="$CASE/bin/xray"
config_written=false; config_backup=''; transaction_backup=''
mkdir -p "$CASE/etc" "$CASE/bin" "$CASE/share" "$CASE/systemd" "$CASE/proc/123" "$CASE/ipv6/conf/all"
printf 0 > "$CASE/ipv6/conf/all/disable_ipv6"
printf '%s\n' '#!/bin/bash' 'case "$1" in version) echo "Xray 1.0.0";; run) exit 0;; esac' > "$xray_binary_path"
chmod +x "$xray_binary_path"
ln -s "$xray_binary_path" "$CASE/proc/123/exe"
printf old-unit > "$CASE/systemd/xray.service"
STATE=active
systemctl() { printf 'systemctl %s\n' "$*" >> "$CASE/calls"; case "$1" in is-active) [[ "$STATE" == active ]];; is-enabled) return 0;; show) if [[ "$*" == *MainPID* ]]; then echo 123; else echo root; fi;; restart|start) STATE=active;; stop) STATE=inactive;; *) return 0;; esac; }
kill() { printf 'BLOCKED kill\n' >> "$CASE/calls"; return 99; }
pkill() { printf 'BLOCKED pkill\n' >> "$CASE/calls"; return 99; }
pgrep() { return 1; }
apt-get() { return 99; }; apt() { return 99; }; yum() { return 99; }; dnf() { return 99; }
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
                                    env={**os.environ, 'CASE': root, 'TMPDIR': root}, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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

    def test_port_probe_failure(self):
        self.run_shell('ss() { return 2; }; if is_port_available 443; then exit 1; fi')

    def test_single_protocol_collision_before_installer(self):
        self.run_shell('''v=$(build_vless_inbound 443 "$UUID" www.sega.com "$PRIV" "$PUB")
render_config '{}' "[$v]" > "$xray_config_path"
if run_install_ss 443 "$KEY"; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null
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
! grep -q official "$CASE/calls" 2>/dev/null
[[ $(< "$CASE/systemd/xray.service.d/custom.conf") == override ]]
''')

    def test_config_only_uninstall(self):
        self.run_shell('''rm "$xray_binary_path" "$CASE/systemd/xray.service"; printf '{}' > "$xray_config_path"
execute_official_script() { return 1; }
uninstall_xray <<< y || exit 1
[[ ! -e "$xray_config_path" ]]
''')

    def test_dropin_only_uninstall(self):
        self.run_shell('''rm "$xray_binary_path" "$CASE/systemd/xray.service"
mkdir "$CASE/systemd/xray.service.d"; printf override > "$CASE/systemd/xray.service.d/custom.conf"
uninstall_xray <<< y || exit 1
[[ ! -e "$CASE/systemd/xray.service.d" ]]
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
systemctl() { if [[ "$1" == show ]]; then n=$(< "$CASE/probes"); printf '%s' "$((n+1))" > "$CASE/probes"; if [[ "$n" == 0 ]]; then echo 123; else echo 456; fi; fi; }
mkdir -p "$CASE/proc/456"; ln -s "$xray_binary_path" "$CASE/proc/456/exe"
if restart_xray; then exit 1; fi
[[ $(< "$CASE/probes") == 2 ]]
''')

    def test_port_probe_prompt_propagation(self):
        self.run_shell('''ss() { return 2; }; a=''; b=''; c=''
if prompt_for_vless_config a b c <<< $'443\\n'; then exit 1; fi
if prompt_for_ss_config a b <<< $'8388\\n'; then exit 1; fi
if run_install_ss 8388 "$KEY"; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null
''')

    def test_custom_port_range_conflict(self):
        self.run_shell('''printf '{"inbounds":[{"tag":"custom","port":"8000-9000","protocol":"socks"}]}' > "$xray_config_path"
if run_install_ss 8388 "$KEY"; then exit 1; fi
! grep -q official "$CASE/calls" 2>/dev/null
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
        self.run_shell("printf '%s' " + __import__('shlex').quote(main) + ''' > "$CASE/official-main"
normalize_official_script "$CASE/official-main" || exit 1
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
install_xray() { printf installed > "$CASE/installed"; }
install_startup_service_file() { printf overwritten > "$CASE/systemd/xray.service"; }
systemctl() { if [[ "$1" == list-unit-files ]]; then echo xray.service; fi; }
package_provide_tput=tput; HELP=0; CHECK=0; REMOVE=0; INSTALL_GEODATA=0; LOGROTATE=0
LOCAL_FILE=''; REINSTALL=0; SPECIFIED_VERSION=''; FORCE=0; BETA=0; MACHINE=test
N_UP_SERVICE=1; GEODATA=0; CONFIG_NEW=0; CONFDIR=0; LOG=0; LOGROTATE_FIN=0; SYSTEMD=0
PACKAGE_MANAGEMENT_REMOVE=mock; XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=1; XRAY_RUNNING=0
for MODE in stopped active; do ( main ) || exit 1; done
[[ $(< "$CASE/systemd/xray.service") == old-unit && -e "$CASE/installed" ]]
for MODE in root os args download; do if ( main ); then exit 1; fi; done
MODE=startfail; XRAY_RUNNING=1
if ( main ); then exit 1; fi
''')

    def test_probe_failure_on_unchanged_ports(self):
        self.run_shell('''s=$(build_ss_inbound 8388 "$KEY"); render_config '{}' "[$s]" > "$xray_config_path"
ss() { return 2; }
if is_port_available_for 8388 shadowsocks; then exit 1; else [[ $? == 2 ]]; fi
if modify_ss_config <<< $'\\n\\n'; then exit 1; fi
! grep -q 'systemctl restart' "$CASE/calls" 2>/dev/null
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

    def test_native_dual_stack_and_preserved_listen(self):
        self.run_shell('''s=$(build_ss_inbound 8388 "$KEY"); [[ $(jq -r .listen <<< "$s") == :: ]]
printf '{"inbounds":[{"tag":"xray-dual-ss","listen":"127.0.0.1","port":8388,"protocol":"shadowsocks"}]}' > "$xray_config_path"
s=$(build_ss_inbound 8388 "$KEY"); [[ $(jq -r .listen <<< "$s") == 127.0.0.1 ]]
rm "$xray_config_path"; printf 1 > "$CASE/ipv6/conf/all/disable_ipv6"
s=$(build_ss_inbound 8388 "$KEY"); [[ $(jq -r .listen <<< "$s") == 0.0.0.0 ]]
''')

if __name__ == '__main__':
    unittest.main(verbosity=2)
