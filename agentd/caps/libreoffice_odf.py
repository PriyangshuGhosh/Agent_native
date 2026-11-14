# Reads a document's structure straight from the file (ODF or OOXML zip); LibreOffice is not started.
import json, re, sys, zipfile
from xml.etree import ElementTree as ET

z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
def text_of(e):
    return "".join(e.itertext())
out = {"title": None, "headings": [], "paragraphs": 0, "tables": 0, "words": 0, "text": ""}
if "content.xml" in names:  # ODF
    T = "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}"
    root = ET.fromstring(z.read("content.xml"))
    paras = [text_of(e) for e in root.iter() if e.tag in (T + "p", T + "h")]
    out["headings"] = [text_of(e) for e in root.iter(T + "h")]
    out["tables"] = sum(1 for _ in root.iter("{urn:oasis:names:tc:opendocument:xmlns:table:1.0}table"))
    if "meta.xml" in names:
        t = ET.fromstring(z.read("meta.xml")).find(".//{http://purl.org/dc/elements/1.1/}title")
        out["title"] = t.text if t is not None else None
elif "word/document.xml" in names:  # OOXML text
    W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    root = ET.fromstring(z.read("word/document.xml"))
    paras = [text_of(e) for e in root.iter(W + "p")]
    out["tables"] = sum(1 for _ in root.iter(W + "tbl"))
    if "docProps/core.xml" in names:
        t = ET.fromstring(z.read("docProps/core.xml")).find(".//{http://purl.org/dc/elements/1.1/}title")
        out["title"] = t.text if t is not None else None
else:
    sys.exit("not a recognised document")
paras = [p for p in paras if p.strip()]
out["paragraphs"] = len(paras)
out["text"] = "\n".join(paras)[:4000]
out["words"] = len(re.findall(r"\S+", " ".join(paras)))
print(json.dumps(out))
