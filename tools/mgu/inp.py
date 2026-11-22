#!/usr/bin/env python3
# inp.py "d 100 200" "u" ...: manda comandos para o input.sock do mguhost; "s0.2" espera 0,2 s
# (macOS/Linux: datagrama no socket unix; Windows: UDP em 127.0.0.1 na porta de <pasta>/input.sock.port, ver idemu/ipc.py)
import os,sys,time
ROOT=os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..'))
sys.path.insert(0,ROOT)
from idemu import ipc
OUT=os.path.join(ROOT,'mgu22')
s=ipc.dgram_socket()
RUN=open(OUT+'/run.path').read().strip()
for a in sys.argv[1:]:
    if a[0]=='s': time.sleep(float(a[1:])); continue
    ipc.dgram_send(s,ipc.addr(RUN,'input.sock'),a.encode())
