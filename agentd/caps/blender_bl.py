# Runs inside Blender (--background --python bl.py -- <op> ...), in the sandbox.
import json, sys
import bpy

def describe():
    """The scene as data: what the world model stores for a .blend file."""
    objs = bpy.data.objects
    return {"objects": [{"name": o.name, "type": o.type, "location": [round(v, 3) for v in o.location]} for o in objs],
            "object_count": len(objs), "lights": [o.name for o in objs if o.type == "LIGHT"],
            "cameras": [o.name for o in objs if o.type == "CAMERA"], "meshes": [o.name for o in objs if o.type == "MESH"],
            "materials": [m.name for m in bpy.data.materials], "active_camera": bpy.context.scene.camera.name if bpy.context.scene.camera else None,
            "engine": bpy.context.scene.render.engine, "has_world": bpy.context.scene.world is not None,
            "modified": bpy.data.is_dirty}

def add_light(name, kind, x, y, z, strength):
    data = bpy.data.lights.new(name=name, type=kind)
    data.energy = float(strength)
    obj = bpy.data.objects.new(name, data)
    obj.location = (float(x), float(y), float(z))
    bpy.context.scene.collection.objects.link(obj)

if __name__ == "__main__":
    a = sys.argv[sys.argv.index("--") + 1:]
    op = a[0]
    if op == "inspect":
        print(json.dumps(describe()))
    elif op == "render":
        s = bpy.context.scene
        if s.camera is None:  # a camera exists but was never made the active one: use it
            s.camera = next((o for o in bpy.data.objects if o.type == "CAMERA"), None)
        if s.camera is None:
            sys.exit("the scene has no camera")
        s.render.engine = "CYCLES"
        s.cycles.device = "CPU"
        s.cycles.samples = int(a[3])
        s.cycles.use_denoising = False  # Debian's build has no OpenImageDenoise
        s.render.resolution_percentage = int(a[2])
        s.render.image_settings.file_format = "PNG"
        s.render.filepath = a[1]
        s.render.use_file_extension = False
        bpy.ops.render.render(write_still=True)
    else:
        if op == "new":
            for o in list(bpy.data.objects):
                bpy.data.objects.remove(o, do_unlink=True)
        if op in ("new", "edit"):
            exec(compile(open(a[2]).read(), "script", "exec"), {"bpy": bpy})
        elif op == "light":
            add_light(*a[2:8])
        else:
            sys.exit("unknown operation")
        bpy.ops.wm.save_as_mainfile(filepath=a[1], check_existing=False, copy=False)
