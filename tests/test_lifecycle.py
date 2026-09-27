#!/usr/bin/env python3
"""Run the full generated installer against a temporary filesystem and command model.
No real routes, packages, users, services, credentials, or /etc files are modified.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
MOCK=r'''#!/usr/bin/env python3
import json,os,sys,subprocess
from pathlib import Path
r=Path(os.environ['MOCK_ROOT']); f=r/'model.json'
s=json.loads(f.read_text()); cmd=Path(sys.argv[0]).name; args=sys.argv[1:]; a=' '.join(args)
with (r/'calls.log').open('a') as log: log.write(cmd+' '+a+'\n')
def save(): f.write_text(json.dumps(s))
if cmd=='uname': print('Linux')
elif cmd=='id':
 if args==['-u']: print(0)
 elif s.get('user'):
  print(987 if '-u' in args else 'uid=987(l2tp-fetch)')
 else: sys.exit(1)
elif cmd in ['useradd','adduser']: s['user']=True;save()
elif cmd=='getent':
 if s.get('getent_fail'): sys.exit(1)
 print('198.51.100.1 STREAM l2tp.example.net')
elif cmd=='nslookup':
 if s.get('busybox_dns'): print('Server:    1.1.1.1\nAddress 1: 1.1.1.1 one.one.one.one\nName:    l2tp.example.net\nAddress 1: 198.51.100.1 l2tp.example.net')
 else: print('Name: l2tp.example.net\nAddress: 198.51.100.1')
elif cmd=='timeout': sys.exit(subprocess.call(args[1:]))
elif cmd=='su': sys.exit(subprocess.call(['/bin/sh',args[args.index('-c')+1]]))
elif cmd=='nft':
 if 'list' in args: sys.exit(0 if s.get('guard') else 1)
 elif 'delete' in args: s['guard']=False;save()
 else:
  rules=sys.stdin.read(); s['guard']=True; s['rules']=rules;save()
elif cmd=='ip':
 if 'rule' in args:
  if 'show' in args:
   pref=args[args.index('pref')+1] if 'pref' in args else ''
   for x in s.get('rules_ip',[]):
    if not pref or ('pref '+pref+' ') in x: print(x.replace(' add ',' ').replace('/32','').replace('table','lookup'))
  elif 'add' in args: s.setdefault('rules_ip',[]).append(a);save()
  elif 'del' in args:
   match=a.replace(' del ',' add ')
   if match in s.get('rules_ip',[]): s['rules_ip'].remove(match);save()
 elif 'route' in args:
  if 'show default table main' in a: print('default via 192.0.2.1 dev eth0')
  elif 'get' in args:
   if s.get('connected') and s.get('ppp_route'):
    src='192.0.2.10' if s.get('bad_src') else '198.51.100.10'
    print('1.1.1.1 dev l2tp-aa src '+src)
   else: print('1.1.1.1 via 192.0.2.1 dev eth0')
  elif 'replace default dev l2tp-aa' in a: s['ppp_route']=True;save()
  elif 'del default dev l2tp-aa' in a: s['ppp_route']=False;save()
  elif 'prohibit' in a:
   s['prohibit']='replace' in args;save()
 elif 'addr' in args:
  if 'eth0' in args and '-4' in args: print('2: eth0 inet 192.0.2.10/24 scope global eth0')
  elif 'l2tp-aa' in args and s.get('connected') and '-4' in args: print('8: l2tp-aa inet 198.51.100.10/32 scope global l2tp-aa')
 elif 'link show l2tp-aa' in a: sys.exit(0 if s.get('connected') else 1)
elif cmd=='systemctl':
 if ('restart' in args or 'start' in args) and 'l2tp-vps.service' in args:
  if not s.get('fail_dial'):
   s['connected']=True;save()
   sys.exit(subprocess.call(['/bin/sh',str(r/'usr/local/sbin/l2tp-vps'),'up','l2tp-aa','tty','0','198.51.100.10','198.51.100.1','l2tp-vps']))
 if ('stop' in args or '--now' in args) and 'l2tp-vps.service' in args:
  s['connected']=False;save()
elif cmd=='curl':
 print(s.get('public_ip') or '198.51.100.10')
elif cmd=='chmod':
 for path in args[1:]: os.chmod(path,int(args[0],8))
elif cmd=='mv':
 # Python emulates rename-over-symlink: macOS mv otherwise follows a symlink.
 operands=[x for x in args if not x.startswith('-')]
 os.replace(*operands)
elif cmd in ['chmod','chown','sleep','modprobe','sysctl','pppd','xl2tpd','apt-get','rc-service','rc-update','apk']: pass
else: raise SystemExit('Unhandled mock '+cmd+' '+a)
'''

class LifecycleTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='l2tp-lifecycle-');self.addCleanup(self.temp.cleanup)
  self.d=Path(self.temp.name);self.bin=self.d/'bin';self.bin.mkdir()
  (self.d/'model.json').write_text('{}');(self.d/'calls.log').write_text('')
  self.mock=self.bin/'mock';self.mock.write_text(MOCK);self.mock.chmod(0o755)
  for cmd in ['uname','id','useradd','adduser','getent','nslookup','timeout','su','nft','ip','systemctl','curl','mv','chmod','chown','sleep','modprobe','sysctl','pppd','xl2tpd','apt-get','apk','rc-service','rc-update']:
   (self.bin/cmd).symlink_to(self.mock)
  for name in ['etc','run/systemd/system','usr/local/bin','usr/local/sbin','etc/ppp','etc/xl2tpd','etc/systemd/system','etc/init.d']:(self.d/name).mkdir(parents=True,exist_ok=True)
  (self.d/'etc/debian_version').write_text('12')
  (self.d/'etc/resolv.conf').write_text('nameserver 192.0.2.53\n')
  src=(ROOT/'install.sh').read_text()
  # Rewrite filesystem references only, never network data. Runtime heredoc is
  # also relocated, so generated commands operate under this temporary root.
  for prefix in ['/etc/','/usr/local/','/run/','/proc/']:
   src=src.replace(prefix,str(self.d)+prefix)
  src=src.replace('/dev/ppp','/dev/null')
  src=src.replace('mkdir -p /run','mkdir -p '+str(self.d)+'/run')
  src=src.replace('PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin','PATH='+str(self.bin)+':/usr/bin:/bin')
  # The earlier path relocation also rewrites the literal PATH assignment.
  src='\n'.join(('PATH='+str(self.bin)+':/usr/bin:/bin') if x.startswith('PATH=') else x for x in src.splitlines())+'\n'
  self.installer=self.d/'installer.sh';self.installer.write_text(src)
  self.env=dict(os.environ,PATH=str(self.bin)+':/usr/bin:/bin',MOCK_ROOT=str(self.d))
 def install(self,first=True,okay=True):
  env=self.env.copy()
  if first: env.update(L2TP_SERVER='l2tp.example.net',L2TP_USER='user@example.net',L2TP_PASS='space "quote" \\ $ end')
  r=subprocess.run(['/bin/sh',str(self.installer)],env=env,text=True,errors='replace',capture_output=True)
  if okay:self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  else:self.assertNotEqual(r.returncode,0)
  return r
 def runtime(self,op):
  return subprocess.run(['/bin/sh',str(self.d/'usr/local/sbin/l2tp-vps'),op],env=self.env,text=True,errors='replace',capture_output=True)
 def model(self):return json.loads((self.d/'model.json').read_text())
 def test_fresh_then_upgrade_preserves_credentials_and_snapshot(self):
  first=self.install();state=self.d/'etc/l2tp-vless'
  password=(state/'password').read_bytes()
  self.install(first=False)
  self.assertEqual((state/'password').read_bytes(),password)
  self.assertTrue((state/'rollback-path').exists())
  self.assertEqual((state/'installed-version').read_text().strip(),'2.0.4')
  self.assertTrue(self.model()['guard'])
  self.assertEqual((self.d/'etc/resolv.conf').read_text().splitlines()[0],'nameserver 1.1.1.1')
  options=(state/'options').read_text()
  self.assertEqual(self.pppd_unquote(options,'password'),'space "quote" \\ $ end')
  self.assertEqual(self.pppd_unquote(options,'user'),'user@example.net')
  conf=(state/'xl2tpd.conf').read_text()
  self.assertIn('[lac vps]\n',conf)
  self.assertIn('refuse pap = yes\n',conf)
  unit=(self.d/'etc/systemd/system/l2tp-vps.service').read_text()
  self.assertLess(unit.index('l2tp-vps guard'), unit.index('l2tp-vps route'))
  netconf=(self.d/'etc/systemd/networkd.conf.d/l2tp-vps.conf').read_text()
  self.assertIn('ManageForeignRoutingPolicyRules=no', netconf)
  self.assertIn('ManageForeignRoutes=no', netconf)
  self.assertNotIn('A&A',unit)
  self.assertNotIn('A&A',first.stdout+first.stderr)
  self.assertNotIn('aa.net.uk',first.stdout+first.stderr)
 def test_failed_first_install_has_working_offline_recovery(self):
  (self.d/'model.json').write_text('{"fail_dial":true}')
  self.install(okay=False)
  self.assertTrue(self.model()['guard'])
  self.assertFalse((self.d/'etc/l2tp-vless/installed-version').exists())
  r=self.runtime('recover');self.assertEqual(r.returncode,0,r.stderr)
  self.assertFalse((self.d/'etc/systemd/networkd.conf.d/l2tp-vps.conf').exists())
  self.assertFalse(self.model()['guard'])
  self.assertFalse(self.model()['prohibit'])
  self.assertEqual((self.d/'etc/resolv.conf').read_text(),'nameserver 192.0.2.53\n')
 def test_legacy_migration_preserves_existing_credentials(self):
  state=self.d/'etc/l2tp-vless';state.mkdir()
  (state/'net.env').write_text('GW=192.0.2.1\nIF=eth0\nNATIVE_IP=192.0.2.10\nSERVER_IP=198.51.100.1\n')
  (state/'native-v6.txt').write_text('')
  # These paths in legacy config are also relocated, like the generated source.
  (self.d/'etc/xl2tpd/xl2tpd.conf').write_text('[global]\n[lac aa]\npppoptfile = '+str(self.d)+'/etc/ppp/options.l2tp-vless\n')
  (self.d/'etc/ppp/options.l2tp-vless').write_text('name old@example.net\n')
  (self.d/'etc/ppp/chap-secrets').write_text('"old@example.net" * "old \\"quote\\" \\\\ pass" *\n')
  self.install(first=False)
  self.assertEqual((state/'user').read_text(),'old@example.net\n')
  self.assertEqual((state/'password').read_text(),'old "quote" \\ pass\n')
  self.assertFalse((state/'legacy-pending').exists())
  calls=(self.d/'calls.log').read_text()
  self.assertIn('systemctl stop xl2tpd',calls)
  self.assertNotIn('pkill',calls)
  self.assertNotIn('route flush',calls)
 def pppd_unquote(self,text,key):
  line=[x for x in text.splitlines() if x.startswith(key+' "')][0]
  inner=line[len(key)+2:]
  if not inner.endswith('"'): raise AssertionError(line)
  inner=inner[:-1]
  out=[]; i=0
  while i<len(inner):
   if inner[i]=='\\' and i+1<len(inner):
    out.append(inner[i+1]); i+=2
   else:
    out.append(inner[i]); i+=1
  return ''.join(out)
 def test_provider_nat_is_success_and_native_egress_is_not(self):
  (self.d/'model.json').write_text('{"public_ip":"203.0.113.50"}')
  result=self.install()
  self.assertIn('203.0.113.50',result.stdout)
  self.assertNotIn('A&A',result.stdout+result.stderr)
  self.patch_model(public_ip='192.0.2.10')
  failed=self.install(first=False,okay=False)
  self.assertIn('原生地址',failed.stderr)
  self.patch_model(public_ip='198.51.100.10',bad_src=True)
  leaked=self.install(first=False,okay=False)
  self.assertIn('源地址',leaked.stderr)
 def patch_model(self,**kwargs):
  model=self.model(); model.update(kwargs)
  (self.d/'model.json').write_text(json.dumps(model))
 def test_hostname_falls_back_when_system_dns_fails(self):
  (self.d/'model.json').write_text('{"getent_fail":true}')
  self.install()
  self.assertEqual((self.d/'etc/l2tp-vless/server').read_text().strip(),'l2tp.example.net')
 def test_busybox_nslookup_can_resolve_the_server(self):
  (self.d/'model.json').write_text('{"getent_fail":true,"busybox_dns":true}')
  self.install()
  self.assertEqual((self.d/'etc/l2tp-vless/server').read_text().strip(),'l2tp.example.net')
 def test_special_password_is_written_for_pppd_not_the_shell(self):
  marker=self.d/'PWNED'
  password='$(touch '+str(marker)+') `touch '+str(marker)+'` \\ " $PATH'
  user='DOMAIN\\ops user'
  env=self.env.copy()
  env.update(L2TP_SERVER='l2tp.example.net',L2TP_USER=user,L2TP_PASS=password)
  result=subprocess.run(['/bin/sh',str(self.installer)],env=env,text=True,errors='replace',capture_output=True)
  self.assertEqual(result.returncode,0,result.stderr+result.stdout)
  self.assertFalse(marker.exists())
  options=(self.d/'etc/l2tp-vless/options').read_text()
  self.assertEqual(self.pppd_unquote(options,'password'),password)
  self.assertEqual(self.pppd_unquote(options,'user'),user)
  self.assertEqual((self.d/'etc/l2tp-vless/password').read_text(),password+'\n')

if __name__=='__main__':unittest.main(verbosity=2)
