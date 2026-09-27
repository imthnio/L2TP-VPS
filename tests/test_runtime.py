#!/usr/bin/env python3
"""Regression tests execute real runtime functions with isolated command stubs."""
import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = (ROOT / 'src/runtime.sh').read_text().split('# BEGIN DISPATCH')[0]
INSTALL = (ROOT / 'src/install.sh').read_text()

class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        (self.d/'native-v4.txt').write_text('192.0.2.10\n192.0.2.11\n')
        (self.d/'native-v6.txt').write_text('2001:db8::10\n')

    def run_sh(self, body, setup=''):
        prefix = RUNTIME + '\nSTATE=' + shlex.quote(str(self.d)) + '''
NATIVE_IF=eth0
NATIVE_IP=192.0.2.10
ENDPOINT=198.51.100.1
SERVER=l2tp.example.net
FETCH_UID=987
INIT=systemd
ip() { printf 'IP %s\\n' "$*"; }
sysctl() { :; }
''' + setup + '\n'
        r = subprocess.run(['/bin/sh'], input=prefix + body, text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        return r.stdout

    def test_foreign_ppp_up_is_ignored(self):
        self.assertEqual(self.run_sh('peer_up ppp9 tty 0 1.1.1.1 2.2.2.2 unrelated'), '')

    def test_same_interface_wrong_identity_is_ignored(self):
        self.assertEqual(self.run_sh('peer_up l2tp-aa tty 0 1 2 wrong'), '')

    def test_own_ppp_gets_ipv4_route(self):
        out=self.run_sh('peer_up l2tp-aa tty 0 1 2 l2tp-vps')
        self.assertIn('-4 route replace default dev l2tp-aa metric 100 table 24680', out)
        self.assertNotIn('-6 route replace', out)

    def test_ipv6_only_when_global_address_exists(self):
        out=self.run_sh('peer_v6 l2tp-aa tty 0 1 2 l2tp-vps', '''
ip() { case "$*" in '-6 addr show dev l2tp-aa scope global') echo 'inet6 2001:db8:1::1/64 scope global';; *) printf 'IP %s\\n' "$*";; esac; }
''')
        self.assertIn('-6 route replace default dev l2tp-aa',out)

    def test_unrelated_down_does_not_delete_routes(self):
        self.assertEqual(self.run_sh('peer_down ppp9 tty 0 1 2 other'), '')

    def test_own_down_keeps_prohibit(self):
        out=self.run_sh('peer_down l2tp-aa tty 0 1 2 l2tp-vps')
        self.assertIn('metric 100 table 24680',out)
        self.assertNotIn('prohibit',out)
        self.assertNotIn('flush',out)

    def test_missing_policy_is_restored_without_flushing_foreign_state(self):
        out=self.run_sh('restore_policy', '''
ip() {
  case "$*" in
    '-4 route show default table main') echo 'default via 192.0.2.1 dev eth0';;
    *) printf 'IP %s\\n' "$*";;
  esac
}
nft() { printf 'NFT %s\\n' "$*"; cat >/dev/null; }
''')
        self.assertIn('NFT -f -', out)
        self.assertIn('-4 rule add pref 8920 table 24680', out)
        self.assertIn('-4 route replace 198.51.100.1/32 via 192.0.2.1 dev eth0 onlink table 24680', out)
        self.assertNotIn('rule flush', out)
        self.assertNotIn('route flush', out)

    def test_present_policy_is_not_reinstalled(self):
        out=self.run_sh('restore_policy', '''
ip() {
  case "$*" in
    '-4 rule show pref 8905') printf '%s\\n' '8905: from all fwmark 0x24680 lookup main';;
    '-4 rule show pref 8920') printf '%s\\n' '8920: from all lookup 24680';;
    '-4 rule show pref 8930') printf '%s\\n' '8930: from all blackhole';;
    '-4 rule show pref 8910') ;;
    '-6 rule show pref 8910') ;;
    *) printf 'IP %s\\n' "$*";;
  esac
}
nft() { return 0; }
ipv6_on() { return 1; }
''')
        self.assertEqual(out, '')

    def test_guard_does_not_send_native_source_out_the_vps(self):
        out=self.run_sh('guard', '''
ip() {
  case "$*" in
    '-4 route show default table main') echo 'default via 192.0.2.1 dev eth0';;
    *) printf 'IP %s\\n' "$*";;
  esac
}
nft() { cat >/dev/null; }
''')
        self.assertIn('-4 rule add pref 8905 fwmark 0x24680 table main', out)
        self.assertIn('-4 rule add pref 8920 table 24680', out)
        self.assertIn('-4 rule add pref 8930 blackhole', out)
        self.assertIn('-4 rule del pref 8910 from 192.0.2.10/32 table main', out)
        self.assertNotIn('-4 rule add pref 8910 from 192.0.2.10/32 table main', out)

    def test_filter_has_no_native_source_blanket_accept(self):
        out=self.run_sh('render_firewall')
        self.assertIn('ct direction reply ct state established,related accept',out)
        self.assertIn('ct direction reply meta mark set 0x24680',out)
        self.assertIn('type route hook output',out)
        self.assertIn('masquerade',out)
        self.assertNotIn('ip saddr 192.0.2.10 accept',out)
        self.assertIn('policy drop',out)
        self.assertIn('meta skuid 987',out)
        self.assertNotIn('meta skuid 0 ',out)
        self.assertNotIn('flush ruleset',out)

    def test_cleanup_is_scoped_and_preserves_other_routes(self):
        out=self.run_sh('remove_routes')
        self.assertIn('pref 8910 from 192.0.2.11/32 table main',out)
        self.assertIn('pref 8905 fwmark 0x24680 table main',out)
        self.assertIn('pref 8930 blackhole',out)
        self.assertNotIn('route flush',out)
        self.assertNotIn('pref 9000',out)
        for line in out.splitlines():
            if 'rule del' in line:
                self.assertTrue('table ' in line or 'blackhole' in line, line)

    def test_uninstall_never_kills_all_ppp_or_purges_packages(self):
        out=self.run_sh('uninstall', '''
recover() { echo recover; }
rm() { printf 'RM %s\\n' "$*"; }
systemctl() { printf 'SYSTEMCTL %s\\n' "$*"; }
''')
        self.assertNotIn('pkill',out)
        self.assertNotIn('apt-get',out)
        self.assertNotIn('apk del',out)
        self.assertNotIn('RM -rf /etc',out)
        self.assertNotIn('/etc/xl2tpd/xl2tpd.conf',out)

    def test_fetch_worker_handles_stub_dns_independently(self):
        setup='''
chown() { :; }
worker() {
  cat "$1" >&2
  mkdir -p "$(dirname "$1")/out"
  printf 'payload' > "$(dirname "$1")/out/payload"
}
'''
        out=self.run_sh('fetch https://raw.githubusercontent.com/imthnio/L2TP-VPS/main/install.sh "$STATE/download"; cat "$STATE/download"',setup)
        self.assertEqual(out,'payload')
        # Execute the generated worker too, without real DNS or network access.
        setup='''
chown() { :; }
worker() {
  sed 's/^exec curl /fake_curl /' "$1" > "$1.test"
  timeout() { shift; "$@"; }
  nslookup() { printf 'Server: 1.1.1.1\\nAddress: 1.1.1.1#53\\nName: raw.githubusercontent.com\\nAddress: 185.199.108.133\\n'; }
  fake_curl() {
    printf '%s\\n' "$*" >&2
    case "$*" in *'--resolve raw.githubusercontent.com:443:185.199.108.133'*) ;; *) exit 9;; esac
    while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; printf payload > "$1"; break; fi; shift; done
  }
  . "$1.test"
}
'''
        out=self.run_sh('fetch https://raw.githubusercontent.com/imthnio/L2TP-VPS/main/install.sh "$STATE/download"; cat "$STATE/download"',setup)
        self.assertEqual(out,'payload')

    def test_build_is_reproducible(self):
        expected=INSTALL.replace('@@RUNTIME@@',(ROOT/'src/runtime.sh').read_text().rstrip('\n'))
        self.assertEqual(expected,(ROOT/'install.sh').read_text())
        self.assertEqual((ROOT/'SHA256SUMS').read_text().split()[0],hashlib.sha256(expected.encode()).hexdigest())

    def test_syntax(self):
        for path in [ROOT/'install.sh',ROOT/'bootstrap.sh',ROOT/'src/runtime.sh']:
            subprocess.run(['/bin/sh','-n',str(path)],check=True)

    def test_version_does_not_install(self):
        r=subprocess.run(['/bin/sh',str(ROOT/'install.sh'),'--version'],text=True,capture_output=True,check=True)
        self.assertEqual(r.stdout.strip(),'2.0.3')

    def test_failure_recovery_precedes_first_guard(self):
        self.assertLess(INSTALL.index('cat > "$RUNTIME.new"'),INSTALL.index('"$RUNTIME" guard'))
        self.assertLess(INSTALL.index('> /usr/local/bin/shanchu'),INSTALL.index('"$RUNTIME" guard'))
        self.assertLess(INSTALL.index('> "$STATE/password"'),INSTALL.index('"$RUNTIME" guard'))

    def test_bootstrap_uses_immutable_revision_and_checksum(self):
        src=(ROOT/'bootstrap.sh').read_text()
        self.assertIn('/commits/main?',src)
        self.assertIn('L2TP-VPS@$commit/$file',src)
        self.assertIn('[ "$expected" = "$actual" ]',src)
        self.assertNotIn('L2TP-VPS@main/install.sh',src)
        self.assertNotIn('/tmp/l2tp-vps-install.sh',src)

    def test_update_pins_bootstrap_to_the_commit(self):
        src = RUNTIME
        self.assertIn('/commits/main?', src)
        self.assertIn('L2TP-VPS@$commit/bootstrap.sh', src)
        self.assertNotIn('L2TP-VPS/main/bootstrap.sh', src)

    def test_user_text_does_not_name_a_provider(self):
        blob = '\n'.join([
            INSTALL,
            RUNTIME,
            (ROOT/'README.md').read_text(),
            (ROOT/'bootstrap.sh').read_text(),
        ])
        self.assertNotIn('A&A', blob)
        self.assertNotIn('aa.net.uk', blob)
        self.assertNotIn('Andrews', blob)
        self.assertIn('PEER=l2tp-aa', INSTALL)
        self.assertIn('PEER=l2tp-aa', RUNTIME)
        self.assertIn('ifname l2tp-aa', INSTALL)

    def test_resolve_keeps_current_address_when_dns_lists_several(self):
        out = self.run_sh('resolve; ENDPOINT=203.0.113.8; resolve', '''
worker() { printf '%s\\n' 'Name: l2tp.example.net' 'Address: 203.0.113.10' 'Address: 198.51.100.1'; }
''')
        self.assertEqual(out.splitlines(), ['198.51.100.1', '203.0.113.10'])

    def test_resolve_reads_busybox_nslookup(self):
        out = self.run_sh('resolve', '''
worker() { printf '%s\\n' 'Server:    1.1.1.1' 'Address 1: 1.1.1.1 one.one.one.one' 'Name:    l2tp.example.net' 'Address 1: 203.0.113.10 l2tp.example.net' 'Address 1: 198.51.100.1 l2tp.example.net'; }
''')
        self.assertEqual(out.strip(), '198.51.100.1')

    def test_refresh_repairs_route_without_restart_when_address_is_unchanged(self):
        out = self.run_sh('refresh', '''
mkdir() { :; }
rmdir() { :; }
resolve() { printf '%s\\n' "$ENDPOINT"; }
endpoint_route() { echo ROUTE; }
guard() { echo GUARD; }
service() { echo RESTART; }
''')
        self.assertIn('ROUTE', out)
        self.assertNotIn('GUARD', out)
        self.assertNotIn('RESTART', out)

    def test_refresh_switches_endpoint_when_dns_withdraws_it(self):
        out = self.run_sh('refresh; printf FILE:%s\\n "$(cat "$STATE/net.env")"; printf LNS:%s\\n "$(cat "$STATE/xl2tpd.conf")"', '''
mkdir() { :; }
rmdir() { :; }
resolve() { printf '%s\\n' '203.0.113.9'; }
endpoint_route() { echo ROUTE; }
guard() { echo GUARD; }
service() { echo RESTART; }
printf 'ENDPOINT=198.51.100.1\\n' > "$STATE/net.env"
printf 'lns = 198.51.100.1\\n' > "$STATE/xl2tpd.conf"
''')
        self.assertIn('ROUTE', out)
        self.assertIn('GUARD', out)
        self.assertIn('RESTART', out)
        self.assertIn('FILE:ENDPOINT=203.0.113.9', out)
        self.assertIn('LNS:lns = 203.0.113.9', out)

class LegacyPasswordTests(unittest.TestCase):
    def test_actual_migration_parser_roundtrips_special_characters(self):
        code=INSTALL.split('old_pass=$(awk -v user="${L2TP_USER:-$old_user}"',1)[1].split("' /etc/ppp/chap-secrets",1)[0]
        awk_program=code[code.index("'")+1:]
        for password in ['normal','spaces and tabs\tend','quote"slash\\hash#dollar$backtick`',' leading and trailing ']:
            escaped=password.replace('\\','\\\\').replace('"','\\"')
            r=subprocess.run(['awk','-v','user=user@a.1',awk_program],input=f'"user@a.1" * "{escaped}" *\n',text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(r.stdout,password+'\n')

if __name__=='__main__': unittest.main(verbosity=2)
