#!/usr/bin/env python3
"""Drive one sppqd process through a list of render requests and print the replies.

  python3 sppqd_try.py <sppqd> <params.bin> <tmpdir> <request line> [<request line> ...]

Each request line is the tab-separated protocol line without the id= field (added here).
Runs with the working directory set to SIGMA Photo Pro's bundle root like the app does.
"""
import os, subprocess, sys, time

exe, params, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
reqs = sys.argv[4:]
os.makedirs(tmp, exist_ok=True)
env = dict(os.environ, SPPQ_PARAMS=params, TMPDIR=tmp, SPPQD_VERBOSE="1")
cwd = "/Applications/SIGMA_PhotoPro6.app" if os.path.isdir("/Applications/SIGMA_PhotoPro6.app") else None
p = subprocess.Popen([exe, params], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(os.path.join(tmp, "sppqd.err"), "ab"),
                     cwd=cwd, env=env, text=True, bufsize=1)
line = p.stdout.readline().rstrip("\n")
print("<", line)
for i, r in enumerate(reqs, 1):
    cmd, _, rest = r.partition("\t")
    req = f"{cmd}\tid={i}" + ("\t" + rest if rest else "") + "\n"
    t0 = time.time()
    p.stdin.write(req); p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line:
            print("! server exited"); sys.exit(1)
        line = line.rstrip("\n")
        if line.startswith("dbg"):
            continue
        break
    print(f"< [{time.time() - t0:5.1f}s] {line}")
p.stdin.write("quit\n"); p.stdin.flush()
p.wait(timeout=30)
