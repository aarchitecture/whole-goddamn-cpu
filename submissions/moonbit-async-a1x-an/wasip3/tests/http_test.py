"""Read-only transport regressions against an already-running Conduit server."""

import argparse
import http.client
import json
import socket
import sys
import threading
import time
from urllib.parse import urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base", default="http://127.0.0.1:3000")
base = urlsplit(parser.parse_args().base)
if base.scheme != "http" or not base.hostname or base.path not in ("", "/"):
    parser.error("--base must be an HTTP origin")
B = base.hostname
P = base.port or 80
ok = []
def a(name,cond,info=""):
    print(("PASS" if cond else "FAIL"),name,info); ok.append((name,cond))
# HEAD /api/tags: 200, body 0, CL>0
c=http.client.HTTPConnection(B,P,timeout=5)
c.request("HEAD","/api/tags"); r=c.getresponse(); body=r.read(); cl=r.getheader("Content-Length")
a("HEAD tags", r.status==200 and len(body)==0 and cl and int(cl)>0, f"cl={cl}")
c.request("GET","/api/tags"); r=c.getresponse(); b=r.read()
a("GET same conn", r.status==200 and json.loads(b).get("tags") is not None)
c.close()
# exact 1MiB login body -> 422
big=b'{}'+b' '*(1048576-2)
c=http.client.HTTPConnection(B,P,timeout=5)
c.request("POST","/api/users/login",body=big,headers={"Content-Type":"application/json","Content-Length":str(len(big))})
r=c.getresponse(); r.read(); a("1MiB login", r.status==422, f"got {r.status}"); c.close()
# 1MiB+1 -> 413
big2=b'{}'+b' '*(1048577-2)
c=http.client.HTTPConnection(B,P,timeout=5)
c.request("POST","/api/users/login",body=big2,headers={"Content-Type":"application/json","Content-Length":str(len(big2))})
r=c.getresponse(); r.read(); a("1MiB+1 login", r.status==413, f"got {r.status}"); c.close()
# raw chunked >1MiB held open -> 413 BEFORE client EOF
s=socket.create_connection((B,P),timeout=5)
s.sendall(b"POST /api/users/login HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n")
buf=b""
chunk=hex(65536)[2:].encode()+b"\r\n"+b"x"*65536+b"\r\n"
try:
    for i in range(17):
        s.sendall(chunk)
except BrokenPipeError:
    pass
while b"\r\n" not in buf:
    part=s.recv(4096)
    assert part, "connection closed without response"
    buf+=part
a("early 413 open stream", buf.split(b"\r\n",1)[0].startswith(b"HTTP/1.1 413 "), buf[:60].decode(errors="replace"))
s.close()
# 3 mid-body aborts then GET 200
for i in range(3):
    s=socket.create_connection((B,P),timeout=5)
    s.sendall(b"POST /api/users/login HTTP/1.1\r\nHost: x\r\nContent-Length: 1048576\r\n\r\n"+b"x"*4096)
    s.close()
c=http.client.HTTPConnection(B,P,timeout=5); c.request("GET","/api/tags"); r=c.getresponse(); r.read()
a("post-abort GET", r.status==200); c.close()
# repeated 404 + health
for i in range(3):
    c=http.client.HTTPConnection(B,P,timeout=5); c.request("GET","/nope%d"%i); r=c.getresponse(); r.read()
    a("404 #%d"%i, r.status==404); c.close()
# 4 concurrent GET
res=[0]*4
def g(i):
    try:
        cc=http.client.HTTPConnection(B,P,timeout=5); cc.request("GET","/api/tags"); rr=cc.getresponse(); rr.read(); res[i]=rr.status; cc.close()
    except Exception: res[i]=0
th=[threading.Thread(target=g,args=(i,)) for i in range(4)]
[t.start() for t in th]; [t.join() for t in th]
a("4 concurrent", res==[200]*4, str(res))
# 14s idle then GET -> server still alive (no request-expiration kill)
time.sleep(14)
c=http.client.HTTPConnection(B,P,timeout=5); c.request("GET","/api/tags"); r=c.getresponse(); r.read()
a("post-14s idle", r.status==200); c.close()
print("RESULT:", sum(1 for _,c in ok if c),"/",len(ok),"passed")
sys.exit(0 if all(c for _,c in ok) else 1)
