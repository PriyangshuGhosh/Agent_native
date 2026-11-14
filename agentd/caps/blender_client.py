# Talks to the bridge inside the person's running Blender. Usage: client.py list | inspect <file> | light <file> ... | exec <file> <script>
import json, os, socket, sys

def ask(req):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(120)
    s.connect("/tmp/agentd-blender-%d.sock" % os.getuid())
    s.sendall((json.dumps(req) + "\n").encode())
    r = json.loads(s.makefile().readline())
    if "error" in r:
        sys.exit(r["error"])
    return r["result"]

op = sys.argv[1]
if op == "list":
    print(json.dumps(ask({"op": "list"})))
else:
    if not any(d["path"] == sys.argv[2] for d in ask({"op": "list"})):
        sys.exit("that file is not open in Blender")
    if op == "inspect":
        print(json.dumps(ask({"op": "inspect"})))
    elif op == "light":
        ask({"op": "light", "args": sys.argv[3:9]})
    elif op == "exec":
        ask({"op": "exec", "code": open(sys.argv[3]).read()})
    else:
        sys.exit("unknown operation")
