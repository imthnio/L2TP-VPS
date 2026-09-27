#!/usr/bin/env python3
"""Real Linux kernel test. All links, firewall and routes live in private netns.
Run: sudo python3 tests/test_netns.py. Does NOT dial A&A or modify host networking.
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
    return subprocess.run(args,text=True,capture_output=True,check=check)

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
SERVER=l2tp.aa.net.uk
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
        maintenance=ns(client,'setpriv','--reuid','65534','--regid','65534','--clear-groups','curl','--noproxy','*','-fsS','--max-time','2','http://203.0.113.1:443')
        assert maintenance.stdout=='192.0.2.10'
        curl(client,'http://203.0.113.1:443','--interface','192.0.2.10',okay=False)
        print('PASS: offline IPv4/IPv6 fail closed; new bound-native connections blocked; incoming management replies and maintenance UID work')
        # A veth named like our isolated peer simulates a point-to-point egress.
        run('ip','link','add','p'+suffix,'type','veth','peer','name','q'+suffix)
        run('ip','link','set','p'+suffix,'netns',client)
        run('ip','link','set','q'+suffix,'netns',server)
        ns(client,'ip','link','set','p'+suffix,'name','l2tp-aa')
        ns(server,'ip','link','set','q'+suffix,'name','aa-peer')
        ns(client,'ip','addr','add','198.18.0.1/24','dev','l2tp-aa')
        ns(server,'ip','addr','add','198.18.0.2/24','dev','aa-peer')
        ns(client,'ip','link','set','l2tp-aa','up')
        ns(server,'ip','link','set','aa-peer','up')
        # Weak-host ARP responds for 203.0.113.1, which the simulated A&A owns.
        runtime('peer_up l2tp-aa tty 0 198.18.0.1 198.18.0.2 l2tp-vps')
        assert curl(client,'http://203.0.113.1:18080')=='198.18.0.1'
        runtime('peer_up ppp9 tty 0 1 2 foreign')
        assert curl(client,'http://203.0.113.1:18080')=='198.18.0.1'
        runtime('guard') # Idempotent refresh must preserve the active PPP route.
        assert curl(client,'http://203.0.113.1:18080')=='198.18.0.1'
        ns(client,'ip','link','delete','l2tp-aa') # Hard loss, without ip-down hook.
        curl(client,'http://203.0.113.1:18080',okay=False)
        curl(client,'http://203.0.113.1:18080','--interface','192.0.2.10',okay=False)
        assert curl(server,'http://192.0.2.10:18081')=='192.0.2.20'
        print('PASS: online traffic uses tunnel; foreign PPP cannot replace it; hard interface loss does not fall back')
        ns(client,'ip','rule','add','pref','9000','from','198.51.100.99','table','main')
        ns(client,'ip','route','add','blackhole','198.51.100.0/24','table','100')
        runtime('remove_routes; nft delete table inet l2tp_vps')
        assert '198.51.100.99' in ns(client,'ip','rule','show','pref','9000').stdout
        assert '198.51.100.0/24' in ns(client,'ip','route','show','table','100').stdout
        assert curl(client,'http://203.0.113.1:18080')=='192.0.2.10'
        print('PASS: recovery restores native access and preserves unrelated rules/table 100')
    finally:
        for p in processes:
            p.terminate()
        for p in processes:
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill();p.wait()
        for name in reversed(created): run('ip','netns','delete',name,check=False)
