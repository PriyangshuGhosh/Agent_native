#!/usr/bin/python3
"""Sends each line to a broker socket, showing one reply between them, then prints replies until it closes.
Used inside the test guests by tests/test-debian-vm.sh and tests/test-txn-recovery.sh: usage <socket> <line>..."""
import socket, sys

s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
f = s.makefile()
for i, l in enumerate(sys.argv[2:]):
    s.sendall(l.encode() + b"\n")
    if i + 3 < len(sys.argv):
        print(f.readline(), end="", flush=True)
for l in f:
    print(l, end="", flush=True)
