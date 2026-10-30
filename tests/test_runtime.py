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
    '-4 rule show pref 8900') printf '%s\\n' '8900: from all uidrange 987-987 lookup main';;
    '-4 rule show pref 8904') printf '%s\\n' '8904: from all fwmark 0x24681 lookup 24680';;
    '-4 rule show pref 8905') printf '%s\\n' '8905: from all fwmark 0x24680 lookup main';;
    '-4 rule show pref 8915') printf '%s\\n' '8915: from all lookup main suppress_prefixlength 0';;
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
        self.assertIn('-4 rule add pref 8904 fwmark 0x24681 table 24680', out)
        self.assertIn('-4 rule add pref 8905 fwmark 0x24680 table main', out)
        self.assertIn('-4 rule add pref 8920 table 24680', out)
        self.assertIn('-4 rule add pref 8930 blackhole', out)
        self.assertIn('-4 rule del pref 8910 from 192.0.2.10/32 table main', out)
        self.assertNotIn('-4 rule add pref 8910 from 192.0.2.10/32 table main', out)

    def test_filter_has_no_native_source_blanket_accept(self):
        out=self.run_sh('render_firewall')
        self.assertIn('ct direction reply ct state established,related accept',out)
        self.assertIn('ct direction reply meta mark set 0x24680',out)
        self.assertNotIn('ct direction original meta mark set 0x24681',out)
        self.assertIn('type route hook output',out)
        self.assertIn('masquerade',out)
        self.assertNotIn('ip saddr 192.0.2.10 accept',out)
        self.assertIn('policy drop',out)
        self.assertIn('meta skuid 987',out)
        self.assertNotIn('meta skuid 0 ',out)
        self.assertNotIn('flush ruleset',out)
        forward=out.split('chain forward {',1)[1].split('}',1)[0]
        self.assertIn('type filter hook forward',forward)
        self.assertIn('oifname "eth0" ct direction reply ct state established,related accept',forward)
        self.assertIn('reject',forward)

    def test_cleanup_is_scoped_and_preserves_other_routes(self):
        out=self.run_sh('remove_routes')
        self.assertIn('pref 8910 from 192.0.2.11/32 table main',out)
        self.assertIn('pref 8904 fwmark 0x24681 table 24680',out)
        self.assertIn('pref 8905 fwmark 0x24680 table main',out)
        self.assertIn('pref 8930 blackhole',out)
        self.assertNotIn('route flush',out)
        self.assertNotIn('pref 9000',out)
        for line in out.splitlines():
            if 'rule del' in line:
                self.assertTrue('table ' in line or 'blackhole' in line, line)

    def test_cleanup_removes_duplicate_rules(self):
        # The watcher and the installer can race and add the same rule twice.
        out=self.run_sh('remove_routes', '''
dup=2
ip() { case "$*" in '-4 rule del pref 8920 table 24680') [ "$dup" -gt 0 ] || return 2; dup=$((dup - 1)); echo DEL8920;; esac; }
''')
        self.assertEqual(out.count('DEL8920'),2)

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
        self.assertEqual(r.stdout.strip(),'2.1.0')

    def test_failure_recovery_precedes_first_guard(self):
        self.assertLess(INSTALL.index('cat > "$RUNTIME.new"'),INSTALL.index('"$RUNTIME" guard'))
        self.assertLess(INSTALL.index('> /usr/local/bin/shanchu'),INSTALL.index('"$RUNTIME" guard'))
        self.assertLess(INSTALL.index('> "$STATE/password"'),INSTALL.index('"$RUNTIME" guard'))

    def test_unusable_ppp_device_fails_before_guard(self):
        self.assertLess(INSTALL.index('( : <>/dev/ppp )'),INSTALL.index('"$RUNTIME" guard'))

    def test_worker_does_not_need_exec_permission_on_tmp(self):
        out=self.run_sh('worker /tmp/l2tp-x/worker', '''
su() { printf 'SU %s\\n' "$*"; }
''')
        self.assertIn('-c /bin/sh /tmp/l2tp-x/worker l2tp-fetch', out)

    def test_bootstrap_uses_immutable_revision_and_checksum(self):
        src=(ROOT/'bootstrap.sh').read_text()
        self.assertIn('/commits/main?',src)
        self.assertIn('L2TP-VPS@$commit/$file',src)
        self.assertIn('[ "$expected" = "$actual" ]',src)
        self.assertNotIn('L2TP-VPS@main/install.sh',src)
        self.assertNotIn('/tmp/l2tp-vps-install.sh',src)

    def test_commit_lookup_falls_back_to_git_refs(self):
        refs = "001e# service=git-upload-pack\n0000015a" + "a"*40 + " HEAD\0multi_ack\n003d" + "b"*40 + " refs/heads/main\n0000"
        for src in [RUNTIME, (ROOT/'bootstrap.sh').read_text()]:
            self.assertIn('L2TP-VPS.git/info/refs?service=git-upload-pack', src)
            line = [x for x in src.splitlines() if "refs\\/heads\\/main" in x][0]
            cmd = line.split('commit=$(', 1)[1].rsplit(')', 1)[0].replace('"$tmp/refs"', '/dev/stdin')
            r = subprocess.run(['/bin/sh', '-c', cmd], input=refs.encode(), capture_output=True, check=True)
            self.assertEqual(r.stdout.decode().strip(), 'b'*40)
        self.assertIn('https://github.com/imthnio/L2TP-VPS.git/info/refs?service=git-upload-pack)', RUNTIME)

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

class BypassTests(unittest.TestCase):
    """Excluded ports: parsing, firewall rendering, reserved ports and program detection."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        (self.d/'native-v4.txt').write_text('192.0.2.10\n192.0.2.11\n')
        (self.d/'native-v6.txt').write_text('2001:db8::10\n')
        (self.d/'proc/sys/net/ipv4').mkdir(parents=True)
        (self.d/'proc/sys/net/ipv4/ip_local_port_range').write_text('32768\t60999\n')
        (self.d/'cgroup').mkdir()
        (self.d/'cgroup/cgroup.controllers').write_text('cpu\n')
        (self.d/'run').mkdir()
        (self.d/'initd').mkdir()

    def runtime(self):
        # Relocate kernel, cgroup, /run and init script paths into the temporary directory.
        text = RUNTIME.replace('/proc/', str(self.d)+'/proc/').replace('/sys/fs/cgroup', str(self.d)+'/cgroup')
        return text.replace('/run/', str(self.d)+'/run/').replace('/etc/init.d/', str(self.d)+'/initd/')

    def run_sh(self, body, setup='', ok=True):
        prefix = self.runtime() + '\nSTATE=' + shlex.quote(str(self.d)) + '\n' + BASE + setup + '\n'
        r = subprocess.run(['/bin/sh'], input=prefix + body, text=True, capture_output=True)
        if ok: self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        return r

    def reserved(self, value=''):
        (self.d/'proc/sys/net/ipv4/ip_local_reserved_ports').write_text(value+'\n')

    def test_installer_and_runtime_share_the_same_parser(self):
        pick = lambda text: text[text.index('\nnormalize_ports() {'):].split('\n}\n', 1)[0]
        self.assertEqual(pick(RUNTIME), pick(INSTALL))

    def test_parser_accepts_lists_and_ranges_and_rejects_garbage(self):
        out = self.run_sh('normalize_ports "2000-2010, 1112，3000;2005-2020 1111 001113、4000"').stdout
        self.assertEqual(out.split(), ['1111-1113', '2000-2020', '3000', '4000'])
        for bad in ['0', '65536', 'abc', '5-3', '1112 x', '-1', '1-2-3', '$(touch x)']:
            r = self.run_sh('normalize_ports ' + shlex.quote(bad), ok=False)
            self.assertEqual(r.returncode, 2, bad)
            self.assertEqual(r.stdout, '', bad)
        r = self.run_sh('normalize_ports "36190 27173 49011 510892"', ok=False)
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (2, '', '510892'))

    def test_no_ports_means_no_bypass_rules_at_all(self):
        out = self.run_sh('render_firewall').stdout
        self.assertNotIn('0x24682', out)
        self.assertNotIn('elements', out)
        self.assertNotIn('jump', out)
        # Chains exist but stay empty, so re-renders and rollbacks remain valid.
        self.assertIn('chain l2tp_bypass_cg', out)
        self.assertIn('flush set inet l2tp_vps bypass_ports', out)

    def test_tunnel_is_outbound_only(self):
        out = self.run_sh('render_firewall').stdout
        for chain in ['tunnel_in', 'tunnel_forward']:
            body = out.split('chain ' + chain + ' {', 1)[1].split('\n  }', 1)[0]
            self.assertIn('iifname "l2tp-aa" ct state established,related accept', body)
            self.assertTrue(body.rstrip().endswith('iifname "l2tp-aa" counter drop'), body)
        tin = out.split('chain tunnel_in {', 1)[1].split('\n  }', 1)[0]
        self.assertIn('nd-router-advert', tin)
        self.assertIn('type filter hook input', tin)

    def test_hybrid_cgroup_mount_is_found(self):
        (self.d/'cgroup/cgroup.controllers').unlink()
        self.assertEqual(self.run_sh('cgroot || echo NONE').stdout.strip(), 'NONE')
        (self.d/'cgroup/unified').mkdir()
        (self.d/'cgroup/unified/cgroup.controllers').write_text('\n')
        self.assertEqual(self.run_sh('cgroot').stdout.strip(), str(self.d)+'/cgroup/unified')

    def test_old_kernel_falls_back_to_iptables(self):
        (self.d/'bypass-ports').write_text('1112\n')
        setup = (
            "bypass_scan() { echo 'ok|/system.slice/xray.service|1112'; }\n"
            'nft() { input=$(cat); case "$input" in *cgroupv2*) return 1;; esac; }\n'
            'iptables() { echo "IPT $*" >> "$STATE/ipt.log"; }\n'
            'ip6tables() { echo "IP6T $*" >> "$STATE/ipt.log"; }\n')
        self.run_sh('bypass_refresh', setup)
        log = (self.d/'ipt.log').read_text()
        self.assertIn('-t mangle -A L2TP_VPS_BYPASS -m conntrack --ctdir ORIGINAL -m cgroup --path system.slice/xray.service -j CONNMARK --set-mark 0x24682', log)
        self.assertIn('-m connmark --mark 0x24682 -j MARK --set-mark 0x24682', log)
        self.assertIn('IP6T', log)
        status = (self.d/'run/l2tp-vps-bypass.status').read_text()
        self.assertNotIn('fail|', status)
        # Removing the ports tears the iptables chain down again.
        (self.d/'bypass-ports').unlink()
        self.run_sh('bypass_refresh', setup)
        self.assertIn('-X L2TP_VPS_BYPASS', (self.d/'ipt.log').read_text())
        self.assertFalse((self.d/'run/l2tp-vps-bypass.ipt').exists())

    def test_without_iptables_old_kernel_reports_port_only(self):
        (self.d/'bypass-ports').write_text('1112\n')
        setup = (
            "bypass_scan() { echo 'ok|/system.slice/xray.service|1112'; }\n"
            'nft() { input=$(cat); case "$input" in *cgroupv2*) return 1;; esac; }\n'
            'command() { case "$2" in iptables|ip6tables) return 1;; esac; builtin command "$@"; }\n')
        self.run_sh('bypass_refresh', setup)
        self.assertIn('fail|/system.slice/xray.service', (self.d/'run/l2tp-vps-bypass.status').read_text())

    def test_iptables_untouched_when_never_used(self):
        setup = 'iptables() { echo CALLED; }\nip6tables() { echo CALLED; }\n'
        self.assertNotIn('CALLED', self.run_sh('bypass_refresh; ipt_bypass', setup).stdout)

    def test_corrupt_port_file_fails_safe(self):
        (self.d/'bypass-ports').write_text('1112\nrm -rf /\n')
        out = self.run_sh('render_firewall; bypass_on && echo ON || echo OFF').stdout
        self.assertNotIn('0x24682', out)
        self.assertIn('OFF', out)

    def test_rendered_bypass_rules(self):
        (self.d/'bypass-ports').write_text('1112\n2000-2010\n')
        self.reserved('1112,2000-2010')
        out = self.run_sh('render_firewall').stdout
        self.assertIn('elements = { 1112, 2000-2010 }', out)
        self.assertIn('iifname != { "lo", "l2tp-aa" } ct state new fib daddr type local tcp dport @bypass_ports ct mark set 0x24682', out)
        self.assertIn('iifname != { "lo", "l2tp-aa" } ct state new fib daddr type local udp dport @bypass_ports ct mark set 0x24682', out)
        self.assertIn('tcp sport @bypass_ports ct mark set 0x24682 meta mark set 0x24682 accept', out)
        self.assertIn('jump l2tp_bypass_cg', out)
        self.assertIn('oifname "eth0" meta mark 0x24682 ip saddr != { 192.0.2.10, 192.0.2.11 } masquerade', out)
        self.assertIn('oifname "eth0" meta mark 0x24682 ip6 saddr != { 2001:db8::10 } masquerade', out)
        self.assertIn('oifname "eth0" meta mark 0x24682 accept', out)
        # Replies are left to l2tp_route; the kill switch still ends in reject.
        out_chain = out.split('chain l2tp_bypass_out {', 1)[1].split('}', 1)[0]
        self.assertLess(out_chain.index('ct direction reply accept'), out_chain.index('sport'))
        output = out.split('chain output {', 1)[1].split('\n  }', 1)[0]
        self.assertTrue(output.rstrip().endswith('counter reject with icmpx type admin-prohibited'), output)
        self.assertIn('policy drop', out)

    def test_source_port_rule_needs_reserved_ports(self):
        (self.d/'bypass-ports').write_text('40000\n')
        self.reserved('')
        out = self.run_sh('render_firewall').stdout
        self.assertNotIn('sport @bypass_ports', out)
        self.assertIn('dport @bypass_ports', out)

    def test_reserve_adds_and_releases_only_our_ports(self):
        (self.d/'bypass-ports').write_text('1112\n40000-40010\n')
        self.reserved('8080,40005')
        self.run_sh('bypass_reserve')
        kernel = self.d/'proc/sys/net/ipv4/ip_local_reserved_ports'
        r = self.run_sh('portset has "$(cat ' + shlex.quote(str(kernel)) + ')" "8080,1112,40000-40010" && echo HAS')
        self.assertIn('HAS', r.stdout)
        # 40005 was reserved by someone else before us and must survive a release.
        self.assertEqual((self.d/'bypass-reserved').read_text().strip(), '1112,40000-40004,40006-40010')
        (self.d/'bypass-ports').write_text('1112\n')
        self.run_sh('bypass_reserve')
        self.assertEqual(kernel.read_text().strip(), '1112,8080,40005')
        self.run_sh('bypass_reserve release')
        self.assertEqual(kernel.read_text().strip(), '8080,40005')
        self.assertEqual((self.d/'bypass-reserved').read_text().strip(), '')

    def test_reserve_refuses_to_starve_ephemeral_ports(self):
        (self.d/'bypass-ports').write_text('20000-60000\n')
        self.reserved('')
        r = self.run_sh('bypass_reserve && echo OK || echo REFUSED; reserve_ok && echo RES || echo NORES')
        self.assertIn('REFUSED', r.stdout)
        self.assertIn('NORES', r.stdout)
        self.assertEqual((self.d/'proc/sys/net/ipv4/ip_local_reserved_ports').read_text().strip(), '')
        self.assertNotIn('sport @bypass_ports', self.run_sh('render_firewall').stdout)

    def test_guard_adds_bypass_route_rule_only_when_configured(self):
        setup = GUARD_STUBS
        out = self.run_sh('guard', setup).stdout
        self.assertIn('-4 rule del pref 8906 fwmark 0x24682 table main', out)
        self.assertNotIn('rule add pref 8906', out)
        (self.d/'bypass-ports').write_text('1112\n')
        out = self.run_sh('guard', setup).stdout
        self.assertIn('-4 rule add pref 8906 fwmark 0x24682 table main', out)
        self.assertLess(out.index('pref 8906'), out.index('pref 8920'))

    def test_cleanup_removes_bypass_route_rule(self):
        out = self.run_sh('remove_routes').stdout
        self.assertIn('-4 rule del pref 8906 fwmark 0x24682 table main', out)
        self.assertIn('-6 rule del pref 8906 fwmark 0x24682 table main', out)

    def scan(self, listeners, cgroups, ports='1112', init='systemd'):
        (self.d/'bypass-ports').write_text(ports+'\n')
        for pid, path in cgroups.items():
            (self.d/'proc'/str(pid)).mkdir(parents=True, exist_ok=True)
            (self.d/'proc'/str(pid)/'cgroup').write_text('0::'+path+'\n')
        ss = "ss() { cat <<'SS'\nNetid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n" + listeners + "\nSS\n}\n"
        out = self.run_sh('INIT=' + init + '; bypass_scan', ss).stdout
        return sorted(out.strip().splitlines())

    def test_scan_accepts_a_dedicated_service(self):
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("xray",pid=101,fd=3))\n'
                          'udp UNCONN 0 0 *:1112 *:* users:(("xray",pid=101,fd=5))\n'
                          'udp UNCONN 0 0 0.0.0.0:45678 0.0.0.0:* users:(("xray",pid=101,fd=9))\n'
                          'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=7,fd=3))',
                          {101: '/system.slice/xray.service', 7: '/system.slice/ssh.service'})
        self.assertEqual(lines, ['ok|/system.slice/xray.service|1112'])

    def test_scan_ignores_loopback_only_ports(self):
        # xray API, sing-box clash_api and 3x-ui's internal port listen only on loopback; nothing outside can reach them.
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("xray",pid=101,fd=3))\n'
                          'tcp LISTEN 0 4096 127.0.0.1:10085 0.0.0.0:* users:(("xray",pid=101,fd=4))\n'
                          'tcp LISTEN 0 4096 [::1]:9090 [::]:* users:(("xray",pid=101,fd=5))\n'
                          'tcp LISTEN 0 4096 [::ffff:127.0.0.1]:62789 *:* users:(("xray",pid=101,fd=6))\n'
                          'udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("xray",pid=101,fd=7))',
                          {101: '/system.slice/xray.service'})
        self.assertEqual(lines, ['ok|/system.slice/xray.service|1112'])
        # A public second port still blocks it: that node is meant to keep using L2TP.
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("xray",pid=101,fd=3))\n'
                          'tcp LISTEN 0 4096 127.0.0.1:10085 0.0.0.0:* users:(("xray",pid=101,fd=4))\n'
                          'tcp LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=101,fd=5))',
                          {101: '/system.slice/xray.service'})
        self.assertTrue(lines[0].startswith('skip|'), lines)
        self.assertIn('tcp/443', lines[0])
        self.assertNotIn('10085', lines[0])

    def test_scan_groups_sub_cgroups_under_their_service(self):
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("panel",pid=110,fd=3))\n'
                          'tcp LISTEN 0 4096 *:8443 *:* users:(("xray",pid=111,fd=3))',
                          {110: '/system.slice/panel.service', 111: '/system.slice/panel.service/payload'})
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith('skip|/system.slice/panel.service|1112|'), lines)
        self.assertIn('tcp/8443', lines[0])
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("xray",pid=112,fd=3))',
                          {112: '/system.slice/system-xray.slice/xray@a.service/sub'})
        self.assertEqual(lines, ['ok|/system.slice/system-xray.slice/xray@a.service|1112'])

    def test_scan_refuses_a_process_that_also_serves_other_ports(self):
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("xray",pid=101,fd=3))\n'
                          'tcp LISTEN 0 4096 *:443 *:* users:(("xray",pid=101,fd=4))\n'
                          'udp UNCONN 0 0 *:5353 *:* users:(("xray",pid=101,fd=6))',
                          {101: '/system.slice/x-ui.service'})
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith('skip|/system.slice/x-ui.service|1112|'), lines)
        self.assertIn('tcp/443', lines[0])
        self.assertIn('udp/5353', lines[0])

    def test_scan_refuses_sessions_ssh_docker_and_itself(self):
        cases = {'/user.slice/user-0.slice/session-3.scope': '独立的系统服务',
                 '/init.scope': '独立的系统服务',
                 '/': '独立的系统服务',
                 '/system.slice/ssh.service': '关键服务',
                 '/system.slice/l2tp-vps.service': '关键服务',
                 '/system.slice/docker.service': 'Docker',
                 '/system.slice/bad\\x2dname.service': '不支持的字符'}
        for path, why in cases.items():
            lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("p",pid=200,fd=3))', {200: path})
            self.assertEqual(len(lines), 1, path)
            self.assertTrue(lines[0].startswith('skip|'), (path, lines))
            self.assertIn(why, lines[0], path)

    def test_scan_on_openrc_needs_a_real_service(self):
        (self.d/'initd/xray').write_text('#!/sbin/openrc-run\n')
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("xray",pid=300,fd=3))', {300: '/openrc.xray'}, init='openrc')
        self.assertEqual(lines, ['ok|/openrc.xray|1112'])
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("sh",pid=301,fd=3))', {301: '/'}, init='openrc')
        self.assertTrue(lines[0].startswith('skip|'), lines)
        (self.d/'initd/sshd').write_text('#!/sbin/openrc-run\n')
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("sshd",pid=302,fd=3))', {302: '/sshd'}, init='openrc')
        self.assertIn('关键服务', lines[0])

    def test_scan_without_cgroup2_falls_back_to_ports(self):
        (self.d/'cgroup/cgroup.controllers').unlink()
        lines = self.scan('tcp LISTEN 0 4096 *:1112 *:* users:(("xray",pid=101,fd=3))', {101: '/system.slice/xray.service'})
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith('none||'))

    def test_refresh_writes_cgroup_rules_and_skips_unchanged(self):
        (self.d/'bypass-ports').write_text('1112\n')
        (self.d/'cgroup/system.slice/xray.service').mkdir(parents=True)
        setup = (
            "bypass_scan() { echo 'ok|/system.slice/xray.service|1112'; echo 'skip|/system.slice/x-ui.service|1113|other'; }\n"
            "nft() { echo NFT; cat; }\n")
        out = self.run_sh('bypass_refresh; echo ---; bypass_refresh; echo ---; bypass_refresh force', setup).stdout
        first, second, third = out.split('---\n')
        self.assertIn('flush chain inet l2tp_vps l2tp_bypass_cg', first)
        self.assertIn('add rule inet l2tp_vps l2tp_bypass_cg socket cgroupv2 level 2 "system.slice/xray.service" ct mark set 0x24682 meta mark set 0x24682 accept', first)
        self.assertNotIn('x-ui', first)
        self.assertEqual(second, '')
        self.assertIn('socket cgroupv2', third)
        status = (self.d/'run/l2tp-vps-bypass.status').read_text()
        self.assertIn('ok|/system.slice/xray.service|1112', status)

    def test_rerender_keeps_known_service_rules_atomically(self):
        (self.d/'bypass-ports').write_text('1112\n')
        (self.d/'run/l2tp-vps-bypass.rules').write_text(
            'socket cgroupv2 level 2 "system.slice/xray.service" ct mark set 0x24682 meta mark set 0x24682 accept\n'
            'socket cgroupv2 level 1 "x"; flush ruleset; add rule inet l2tp_vps l2tp_bypass_cg accept\n')
        out = self.run_sh('render_firewall').stdout
        cg = out.split('chain l2tp_bypass_cg {', 1)[1].split('}', 1)[0]
        self.assertIn('socket cgroupv2 level 2 "system.slice/xray.service"', cg)
        self.assertNotIn('flush ruleset', out)
        # If the kernel rejects the batch (service cgroup gone), guard reloads without service rules.
        setup = GUARD_STUBS + 'nft() { input=$(cat); case "$input" in *cgroupv2*) echo REJECTED; return 1;; *add\\ table*) echo LOADED;; esac; }\n'
        out = self.run_sh('guard', setup).stdout
        self.assertIn('REJECTED', out)
        self.assertIn('LOADED', out)

    def test_refresh_reports_rules_the_kernel_rejects(self):
        (self.d/'bypass-ports').write_text('1112\n')
        setup = (
            "bypass_scan() { echo 'ok|/system.slice/xray.service|1112'; }\n"
            'nft() { input=$(cat); case "$input" in *cgroupv2*) return 1;; esac; }\n')
        self.run_sh('bypass_refresh', setup)
        status = (self.d/'run/l2tp-vps-bypass.status').read_text()
        self.assertIn('fail|/system.slice/xray.service', status)
        shown = self.run_sh('bypass_show').stdout
        self.assertIn('xray.service', shown)
        self.assertIn('没装上', shown)

    def test_ports_command_validates_and_applies(self):
        setup = (
            'guard() { echo GUARD; bypass_refresh force; }\n'
            'bypass_scan() { :; }\n'
            'nft() { cat >/dev/null; }\n')
        r = self.run_sh('ports_cmd 1112,abc', setup, ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.d/'bypass-ports').exists())
        # A typo in a long list names the one bad entry.
        r = self.run_sh('ports_cmd "36190、27173、49011、510892"', setup, ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('"510892" 不是有效端口', r.stderr)
        self.assertFalse((self.d/'bypass-ports').exists())
        out = self.run_sh('ports_cmd 1112 2000-2010 </dev/null', setup).stdout
        self.assertIn('GUARD', out)
        self.assertEqual((self.d/'bypass-ports').read_text(), '1112\n2000-2010\n')
        self.assertIn('1112 2000-2010', out)
        out = self.run_sh('ports_cmd 0 </dev/null', setup).stdout
        self.assertFalse((self.d/'bypass-ports').exists())
        self.assertIn('不走 L2TP 的端口：无', out)
        (self.d/'disabled').write_text('')
        out = self.run_sh('ports_cmd 1112 </dev/null', setup).stdout
        self.assertNotIn('GUARD', out)

    def test_policy_check_notices_missing_bypass_rule(self):
        (self.d/'bypass-ports').write_text('1112\n')
        out = self.run_sh('policy_missing && echo MISSING || echo OK', POLICY_PRESENT).stdout
        self.assertIn('MISSING', out)
        (self.d/'bypass-ports').unlink()
        out = self.run_sh('policy_missing && echo MISSING || echo OK', POLICY_PRESENT).stdout
        self.assertIn('OK', out)

BASE = '''NATIVE_IF=eth0
NATIVE_IP=192.0.2.10
ENDPOINT=198.51.100.1
SERVER=l2tp.example.net
FETCH_UID=987
INIT=systemd
ip() { printf 'IP %s\\n' "$*"; }
sysctl() { :; }
'''

GUARD_STUBS = '''
ip() { case "$*" in '-4 route show default table main') echo 'default via 192.0.2.1 dev eth0';; *) printf 'IP %s\\n' "$*";; esac; }
nft() { cat >/dev/null; }
ipv6_on() { return 1; }
'''

POLICY_PRESENT = '''
ip() {
  case "$*" in
    '-4 rule show pref 8900') printf '%s\\n' '8900: from all uidrange 987-987 lookup main';;
    '-4 rule show pref 8904') printf '%s\\n' '8904: from all fwmark 0x24681 lookup 24680';;
    '-4 rule show pref 8905') printf '%s\\n' '8905: from all fwmark 0x24680 lookup main';;
    '-4 rule show pref 8915') printf '%s\\n' '8915: from all lookup main suppress_prefixlength 0';;
    '-4 rule show pref 8920') printf '%s\\n' '8920: from all lookup 24680';;
    '-4 rule show pref 8930') printf '%s\\n' '8930: from all blackhole';;
    *) ;;
  esac
}
nft() { return 0; }
ipv6_on() { return 1; }
'''

class LegacyPasswordTests(unittest.TestCase):
    def test_actual_migration_parser_roundtrips_special_characters(self):
        code=INSTALL.split('old_pass=$(L2TP_MATCH_USER="${L2TP_USER:-$old_user}" awk',1)[1].split("' /etc/ppp/chap-secrets",1)[0]
        awk_program=code[code.index("'")+1:]
        for password in ['normal','spaces and tabs\tend','quote"slash\\hash#dollar$backtick`',' leading and trailing ']:
            escaped=password.replace('\\','\\\\').replace('"','\\"')
            r=subprocess.run(['awk',awk_program],input=f'"user@a.1" * "{escaped}" *\n',env=dict(os.environ,L2TP_MATCH_USER='user@a.1'),text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(r.stdout,password+'\n')

if __name__=='__main__': unittest.main(verbosity=2)
