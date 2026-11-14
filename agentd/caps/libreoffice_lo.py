# Drives a private headless LibreOffice over UNO inside the sandbox. Usage: lo.py <create|replace|script> <file> ...
import os, subprocess, sys, time
import uno
from com.sun.star.beans import PropertyValue

FILTERS = {"odt": "writer8", "docx": "MS Word 2007 XML", "ods": "calc8", "xlsx": "Calc MS Excel 2007 XML", "odp": "impress8", "pptx": "Impress MS PowerPoint 2007 XML"}

def prop(n, v):
    p = PropertyValue(); p.Name = n; p.Value = v
    return p

def desktop():
    pipe = "agentd%d" % os.getpid()
    office = subprocess.Popen(["soffice", "--headless", "--invisible", "--norestore", "--nologo", "--accept=pipe,name=%s;urp;" % pipe],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    local = uno.getComponentContext()
    resolver = local.ServiceManager.createInstanceWithContext("com.sun.star.bridge.UnoUrlResolver", local)
    for _ in range(150):
        try:
            ctx = resolver.resolve("uno:pipe,name=%s;urp;StarOffice.ComponentContext" % pipe)
            return office, ctx.ServiceManager.createInstanceWithContext("com.sun.star.frame.Desktop", ctx)
        except Exception:
            time.sleep(0.2)
    sys.exit("LibreOffice did not start")

def save(doc, path):
    ext = path.rsplit(".", 1)[-1].lower()
    if ext not in FILTERS:
        sys.exit("unsupported format ." + ext)
    doc.storeToURL(uno.systemPathToFileUrl(path), (prop("FilterName", FILTERS[ext]), prop("Overwrite", True)))

def replace(doc, find, repl):
    d = doc.createReplaceDescriptor()
    d.SearchString, d.ReplaceString = find, repl
    if doc.replaceAll(d) == 0:
        sys.exit("the text to replace was not found")

def live(op, args):
    """Operations on the LibreOffice the human has open (started with --accept=pipe,name=agentd-live). Nothing is saved."""
    import json, re
    local = uno.getComponentContext()
    resolver = local.ServiceManager.createInstanceWithContext("com.sun.star.bridge.UnoUrlResolver", local)
    ctx = resolver.resolve("uno:pipe,name=agentd-live;urp;StarOffice.ComponentContext")
    desk = ctx.ServiceManager.createInstanceWithContext("com.sun.star.frame.Desktop", ctx)
    docs = [d for d in desk.Components if getattr(d, "URL", "")]
    if op == "live-list":
        print(json.dumps([{"path": uno.fileUrlToSystemPath(d.URL), "modified": d.isModified()} for d in docs if d.URL.startswith("file://")]))
        return
    doc = next((d for d in docs if d.URL == uno.systemPathToFileUrl(args[0])), None)
    if doc is None:
        sys.exit("that file is not open in LibreOffice")
    if op == "live-inspect":
        text = doc.Text.getString() if hasattr(doc, "Text") else ""
        paras = [p for p in text.split("\n") if p.strip()]
        print(json.dumps({"title": doc.DocumentProperties.Title or None, "modified": doc.isModified(), "paragraphs": len(paras),
                          "words": len(re.findall(r"\S+", text)), "text": "\n".join(paras)[:4000]}))
    elif op == "live-replace":
        replace(doc, args[1], args[2])
    elif op == "live-script":
        exec(compile(open(args[1]).read(), "script", "exec"), {"doc": doc, "uno": uno, "prop": prop})
    else:
        sys.exit("unknown operation")

if sys.argv[1].startswith("live-"):
    live(sys.argv[1], sys.argv[2:])
    sys.exit(0)

op, path = sys.argv[1], sys.argv[2]
office, desk = desktop()
try:
    if op == "create":
        doc = desk.loadComponentFromURL("private:factory/swriter", "_blank", 0, (prop("Hidden", True),))
        doc.DocumentProperties.Title = sys.argv[3]
        text = doc.Text
        cur = text.createTextCursor()
        cur.ParaStyleName = "Title"
        text.insertString(cur, sys.argv[3], False)
        for line in sys.argv[4].split("\n"):
            text.insertControlCharacter(cur, 0, False)  # PARAGRAPH_BREAK
            cur.ParaStyleName = "Text body"
            text.insertString(cur, line, False)
    else:
        doc = desk.loadComponentFromURL(uno.systemPathToFileUrl(path), "_blank", 0, (prop("Hidden", True),))
        if doc is None:
            sys.exit("LibreOffice could not open the file")
        if op == "replace":
            replace(doc, sys.argv[3], sys.argv[4])
        elif op == "script":
            exec(compile(open(sys.argv[3]).read(), "script", "exec"), {"doc": doc, "uno": uno, "prop": prop})
        else:
            sys.exit("unknown operation")
    save(doc, path)
    doc.close(True)
finally:
    try:
        desk.terminate()
    except Exception:
        pass
    office.kill()
