# Loaded into the person's own Blender (blender file.blend --python blender_bridge.py). Opens a control socket and
# serves one request per timer tick on Blender's main thread, so changes appear in the open window and stay undoable.
# Requests are JSON lines: {"op": "list"} | {"op": "inspect"} | {"op": "light", "args": [...]} | {"op": "exec", "code": "..."}.
# With --background (tests) there is no event loop, so it serves in a plain loop instead.
import json, os, socket, sys
import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blender_bl as bl

PATH = "/tmp/agentd-blender-%d.sock" % os.getuid()
if os.path.exists(PATH):
    os.unlink(PATH)
srv = socket.socket(socket.AF_UNIX)
srv.bind(PATH)
os.chmod(PATH, 0o600)
srv.listen(4)

def handle(req):
    op = req.get("op")
    if op == "list":
        return [{"path": bpy.data.filepath, "modified": bpy.data.is_dirty}] if bpy.data.filepath else []
    if op == "inspect":
        return bl.describe()
    if op == "light":
        bl.add_light(*req["args"])
    elif op == "exec":
        exec(compile(req["code"], "script", "exec"), {"bpy": bpy})
    else:
        raise ValueError("unknown operation")
    if not bpy.app.background:
        bpy.ops.ed.undo_push(message="agent: " + op)   # the person can undo it with Ctrl+Z
    return {"ok": True}

def serve_one(block):
    srv.setblocking(block)
    try:
        c, _ = srv.accept()
    except BlockingIOError:
        return
    with c:
        c.settimeout(30)
        try:
            reply = {"result": handle(json.loads(c.makefile().readline()))}
        except Exception as e:  # report to the caller; never take the person's Blender down
            reply = {"error": "%s: %s" % (type(e).__name__, e)}
        c.sendall((json.dumps(reply) + "\n").encode())

if bpy.app.background:
    while True:
        serve_one(True)
else:
    def tick():
        serve_one(False)
        return 0.1
    bpy.app.timers.register(tick, persistent=True)
