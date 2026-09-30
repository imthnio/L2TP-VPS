#!/usr/bin/env python3
"""Real Linux kernel test. All links, firewall and routes live in private netns.
Run: sudo python3 tests/test_netns.py. Does not dial a remote L2TP server or modify host networking.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
if os.uname().sysname!='Linux' or os.geteuid()!=0:
    raise SystemExit('Requires Linux and root/CAP_NET_ADMIN (use the CI job)')

def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True)
    if check and result.returncode:
        raise AssertionError(
            'command failed: ' + ' '.join(args) + '\nstdout:\n' + result.stdout + '\nstderr:\n' + result.stderr)
    return result

def ns(name,*args,check=True): return run('ip','netns','exec',name,*args,check=check)

suffix=uuid.uuid4().hex[:8]
client='l2vp-c-'+suffix; server='l2vp-s-'+suffix
processes=[]
created=[]
with tempfile.TemporaryDirectory(prefix='l2tp-netns-') as directory:
    d=Path(directory)
    library=d/'runtime.sh'
    library.write_text((ROOT/'src/runtime.sh').read_text().split('# BEGIN DISPATCH')[0])
    (d/'native-v4.txt').write_text('192.0.2.10\n')
    (d/'native-v6.txt').write_text('2001:db8:1::10\n')
    prefix=f'''. {shlex.quote(str(library))}
STATE={shlex.quote(str(d))}
NATIVE_IF=eth0
NATIVE_IP=192.0.2.10
ENDPOINT=192.0.2.20
SERVER=l2tp.example.net
FETCH_UID=65534
INIT=systemd
'''
    def runtime(body): return ns(client,'/bin/sh','-c',prefix+body)
    def curl(where,url,*args,okay=True):
        result=ns(where,'curl','--noproxy','*','-g','-fsS','--connect-timeout','1','--max-time','2',*args,url,check=False)
        if okay and result.returncode: raise AssertionError(result.stderr)
        if not okay and not result.returncode: raise AssertionError('Unexpected native egress: '+result.stdout)
        return result.stdout.strip()
    http=d/'test_server.py'
    http.write_text('''import http.server,sys,socket
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200);self.end_headers();self.wfile.write(self.client_address[0].encode())
 def log_message(self,*args): pass
class Server(http.server.HTTPServer):
 address_family=socket.AF_INET6 if ':' in sys.argv[1] else socket.AF_INET
Server((sys.argv[1],int(sys.argv[2])),Handler).serve_forever()
''')
    def serve(where,addr,port):
        p=subprocess.Popen(['ip','netns','exec',where,'python3',str(http),addr,str(port)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        processes.append(p)
    try:
        for name in [client,server]:
            run('ip','netns','add',name); created.append(name)
            ns(name,'ip','link','set','lo','up')
        run('ip','link','add','n'+suffix,'type','veth','peer','name','m'+suffix)
        run('ip','link','set','n'+suffix,'netns',client)
        run('ip','link','set','m'+suffix,'netns',server)
        ns(client,'ip','link','set','n'+suffix,'name','eth0')
        ns(server,'ip','link','set','m'+suffix,'name','eth0')
        for name,ip4,ip6 in [(client,'192.0.2.10','2001:db8:1::10'),(server,'192.0.2.20','2001:db8:1::20')]:
            ns(name,'ip','addr','add',ip4+'/24','dev','eth0')
            ns(name,'ip','-6','addr','add',ip6+'/64','dev','eth0','nodad')
            ns(name,'ip','link','set','eth0','up')
        ns(client,'ip','route','add','default','via','192.0.2.20')
        ns(client,'ip','-6','route','add','default','via','2001:db8:1::20')
        ns(server,'ip','addr','add','203.0.113.1/32','dev','lo')
        serve(server,'0.0.0.0',18080)
        serve(server,'0.0.0.0',443)
        serve(server,'::',18082)
        serve(client,'0.0.0.0',18081)
        serve(client,'::',18083)
        time.sleep(.4)
        for process in processes:
            if process.poll() is not None:
                raise AssertionError(process.stderr.read().decode())
        assert curl(client,'http://203.0.113.1:18080')=='192.0.2.10'
        runtime('guard; endpoint_route')
        # The actual nft batch has now been parsed and installed by the kernel.
        curl(client,'http://203.0.113.1:18080',okay=False)
        curl(client,'http://203.0.113.1:18080','--interface','192.0.2.10',okay=False)
        curl(client,'http://[2001:db8:1::20]:18082','--interface','2001:db8:1::10',okay=False)
        assert curl(server,'http://192.0.2.10:18081')=='192.0.2.20'
        assert curl(server,'http://[2001:db8:1::10]:18083')=='2001:db8:1::20'
        maintenance=ns(client,'setpriv','--reuid','65534','--regid','65534','--clear-groups','curl','--noproxy','*','-fsS','--max-time','2','http://203.0.113.1:443', check=False)
        if maintenance.returncode or maintenance.stdout.strip()!='192.0.2.10':
            dump=ns(client,'sh','-c','echo RULE; ip rule; echo ROUTE; ip route; echo T24680; ip route show table 24680; echo GET; ip route get 203.0.113.1; echo GETUID; ip route get 203.0.113.1 uid 65534; echo NFT; nft list table inet l2tp_vps', check=False)
            raise AssertionError(maintenance.stdout+'\n'+maintenance.stderr+'\n'+dump.stdout+'\n'+dump.stderr)
        curl(client,'http://203.0.113.1:443','--interface','192.0.2.10',okay=False)
        print('PASS: offline IPv4/IPv6 fail closed; bound-native cannot use the VPS; incoming replies and maintenance UID work')
        # A veth named like our isolated peer simulates a point-to-point egress.
        run('ip','link','add','p'+suffix,'type','veth','peer','name','q'+suffix)
        run('ip','link','set','p'+suffix,'netns',client)
        run('ip','link','set','q'+suffix,'netns',server)
        ns(client,'ip','link','set','p'+suffix,'name','l2tp-aa')
        ns(server,'ip','link','set','q'+suffix,'name','far-peer')
        ns(client,'ip','addr','add','198.18.0.1/24','dev','l2tp-aa')
        ns(server,'ip','addr','add','198.18.0.2/24','dev','far-peer')
        ns(client,'ip','link','set','l2tp-aa','up')
        ns(server,'ip','link','set','far-peer','up')
        # Weak-host ARP responds for 203.0.113.1, which stands in for the remote peer.
        runtime('peer_up l2tp-aa tty 0 198.18.0.1 198.18.0.2 l2tp-vps')
        assert curl(client,'http://203.0.113.1:18080')=='198.18.0.1'
        assert curl(client,'http://203.0.113.1:18080','--interface','192.0.2.10')=='198.18.0.1'
        curl(client,'http://[2001:db8:1::20]:18082','--interface','2001:db8:1::10',okay=False)
        assert curl(server,'http://192.0.2.10:18081')=='192.0.2.20'
        runtime('peer_up ppp9 tty 0 1 2 foreign')
        assert curl(client,'http://203.0.113.1:18080')=='198.18.0.1'
        runtime('guard') # Idempotent refresh must preserve the active PPP route.
        assert curl(client,'http://203.0.113.1:18080')=='198.18.0.1'
        # A Docker-style bridge: container NAT, a published port, and host-to-container access.
        box='l2vp-k-'+suffix
        run('ip','netns','add',box); created.append(box)
        ns(client,'ip','link','add','docker0','type','bridge')
        ns(client,'ip','addr','add','172.18.0.1/16','dev','docker0')
        ns(client,'ip','link','set','docker0','up')
        run('ip','link','add','b'+suffix,'type','veth','peer','name','k'+suffix)
        run('ip','link','set','b'+suffix,'netns',client)
        run('ip','link','set','k'+suffix,'netns',box)
        ns(client,'ip','link','set','b'+suffix,'master','docker0','up')
        ns(box,'ip','link','set','lo','up')
        ns(box,'ip','addr','add','172.18.0.2/16','dev','k'+suffix)
        ns(box,'ip','link','set','k'+suffix,'up')
        ns(box,'ip','route','add','default','via','172.18.0.1')
        ns(client,'sysctl','-qw','net.ipv4.ip_forward=1')
        ns(client,'nft','add table ip dockersim; add chain ip dockersim post { type nat hook postrouting priority srcnat; }; add rule ip dockersim post ip saddr 172.18.0.0/16 oifname != "docker0" masquerade; add chain ip dockersim pre { type nat hook prerouting priority dstnat; }; add rule ip dockersim pre iifname "eth0" tcp dport 18085 dnat to 172.18.0.2:18084')
        # Strict reverse-path check on the far side: a reply leaking into the tunnel is dropped.
        ns(server,'sysctl','-qw','net.ipv4.conf.far-peer.rp_filter=1')
        serve(box,'0.0.0.0',18084)
        time.sleep(.4)
        assert curl(box,'http://203.0.113.1:18080')=='198.18.0.1'
        assert curl(client,'http://172.18.0.2:18084')=='172.18.0.1'
        assert curl(server,'http://192.0.2.10:18085','--interface','203.0.113.1')=='203.0.113.1'
        print('PASS: Docker bridge containers use the tunnel, published ports reply natively, host reaches containers')
        ns(client,'ip','link','delete','l2tp-aa') # Hard loss, without ip-down hook.
        curl(client,'http://203.0.113.1:18080',okay=False)
        curl(client,'http://203.0.113.1:18080','--interface','192.0.2.10',okay=False)
        assert curl(server,'http://192.0.2.10:18081')=='192.0.2.20'
        print('PASS: online and native-bound traffic use the tunnel; IPv6 does not leak; foreign PPP cannot replace it; hard interface loss does not fall back')
        ns(client,'ip','rule','add','pref','9000','from','198.51.100.99','table','main')
        ns(client,'ip','route','add','blackhole','198.51.100.0/24','table','100')
        runtime('remove_routes; nft delete table inet l2tp_vps')
        assert '198.51.100.99' in ns(client,'ip','rule','show','pref','9000').stdout
        assert '198.51.100.0/24' in ns(client,'ip','route','show','table','100').stdout
        leftover=ns(client,'ip','-4','route','show','table','24680').stdout+ns(client,'ip','-6','route','show','table','24680').stdout
        assert not leftover.strip(), 'routes left in table 24680:\n'+leftover
        assert curl(client,'http://203.0.113.1:18080')=='192.0.2.10'
        print('PASS: recovery restores native access and preserves unrelated rules/table 100')
    finally:
        for p in processes:
            p.terminate()
        for p in processes:
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill();p.wait()
        for name in reversed(created): run('ip','netns','delete',name,check=False)
