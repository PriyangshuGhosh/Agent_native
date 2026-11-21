#!/usr/bin/env python3
"""Test helper. `appsclient.py '<json>'` plays agentd: sends one request to the application runner and prints its final
answer. `appsclient.py --approver` plays the person at the console: answers yes to every approval the runner asks for.
The runner is the person's whose uid is in $APPS_UID (/run/agentd-apps/<uid>.sock and <uid>.approve.sock)."""
import json, os, socket, sys, time

RUNNER = "/run/agentd-apps/" + os.environ["APPS_UID"]

def approver():
    last = 0
    while True:
        for i in range(last + 1, last + 4):
            try:
                a = socket.socket(socket.AF_UNIX)
                a.settimeout(5)
                a.connect(RUNNER + ".approve.sock")
                a.sendall((json.dumps({"id": i}) + "\n").encode())
                line = a.makefile().readline()
                if line:
                    print("APPROVING:", json.loads(line)["text"][:300].replace("\n", " | "), flush=True)
                    a.sendall(b"yes\n")
                    last = i
                    break
            except OSError:
                pass
        time.sleep(0.3)

if sys.argv[1] == "--approver":
    approver()
s = socket.socket(socket.AF_UNIX)
s.settimeout(900)
s.connect(RUNNER + ".sock")
s.sendall(sys.argv[1].encode() + b"\n")
for line in s.makefile():
    if json.loads(line).get("status") != "approval_required":
        print(line.strip())
        break
