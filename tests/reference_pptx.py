"""Read-only independent OOXML inspector used only by native tests."""
from __future__ import annotations

from copy import deepcopy
import io
import posixpath
import re
import shutil
import zipfile
from lxml import etree as ET

NS = {"a": "http://schemas.openxmlformats.org/drawingml/2006/main",
      "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
      "c": "http://schemas.openxmlformats.org/drawingml/2006/chart",
      "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}
PARSER = ET.XMLParser(resolve_entities=False, no_network=True, remove_blank_text=False)


def xml(data):
    return ET.fromstring(data, parser=PARSER)


def relationships(z, part):
    path = posixpath.join(posixpath.dirname(part), "_rels", posixpath.basename(part) + ".rels")
    if path not in z.namelist():
        return []
    return [(r.get("Id"), r.get("Type", "").rsplit("/", 1)[-1],
             posixpath.normpath(posixpath.join(posixpath.dirname(part), r.get("Target", ""))).lstrip("/"))
            for r in xml(z.read(path)) if r.get("TargetMode") != "External"]


def inspect_deck(data):
    try:
        z = zipfile.ZipFile(io.BytesIO(data) if isinstance(data, (bytes, bytearray)) else data)
    except zipfile.BadZipFile:
        raise ValueError("有効なPPTXファイルではありません。")
    with z:
        if "ppt/presentation.xml" not in z.namelist():
            raise ValueError("PowerPoint形式のファイルではありません。")
        rels = {rid: target for rid, kind, target in relationships(z, "ppt/presentation.xml") if kind == "slide"}
        pres = xml(z.read("ppt/presentation.xml"))
        slide_paths = [rels[s.get("{%s}id" % NS["r"])] for s in pres.findall("p:sldIdLst/p:sldId", NS)]
        units, slides, seen = [], [], {}
        for number, path in enumerate(slide_paths, 1):
            root = xml(z.read(path))
            slide = {"number": number, "path": path, "units": [], "images": len(root.findall(".//p:pic", NS))}
            queue = [(path, "slide")]
            # Chart/SmartArt text is also editable. Preserve original notes by default.
            for _, kind, target in relationships(z, path):
                if kind in {"chart", "diagramData", "diagramDrawing", "notesSlide"}:
                    queue.append((target, "notes" if kind == "notesSlide" else "shared" if kind == "slideLayout" else kind))
                    if kind == "diagramData":
                        for _, child_kind, child in relationships(z, target):
                            if child_kind == "diagramDrawing":
                                queue.append((child, child_kind))
            for part, kind in queue:
                if part not in z.namelist():
                    continue
                if part in seen:
                    for idx in seen[part]:
                        units[idx]["slides"].append(number)
                        slide["units"].append(units[idx]["id"])
                    continue
                seen[part] = []
                tree = xml(z.read(part))
                # Paragraphs include groups, table cells, and rich chart text.
                paragraphs = tree.findall(".//a:p", NS)
                for pindex, p in enumerate(paragraphs):
                    if p.findall(".//a:fld", NS):
                        continue  # Dynamic slide numbers/dates must keep their fields.
                    texts = p.findall(".//a:t", NS)
                    source = "".join(t.text or "" for t in texts)
                    if not source.strip():
                        continue
                    idx = len(units)
                    units.append({"id": f"u{idx}", "part": part, "index": pindex, "kind": kind,
                                  "source": source, "translation": "", "slides": [number],
                                  "status": "pending", "error": "", "rich": len(texts) > 1})
                    seen[part].append(idx)
                    slide["units"].append(f"u{idx}")
                # Chart series/category caches use c:v rather than a:t.
                if kind == "chart":
                    for vindex, v in enumerate(tree.findall(".//c:strCache/c:pt/c:v", NS)):
                        source = v.text or ""
                        if not source.strip():
                            continue
                        idx = len(units)
                        units.append({"id": f"u{idx}", "part": part, "index": vindex, "kind": "chart-cache",
                                      "source": source, "translation": "", "slides": [number],
                                      "status": "pending", "error": "", "rich": False})
                        seen[part].append(idx)
                        slide["units"].append(f"u{idx}")
            slides.append(slide)
        return {"slides": slides, "units": units, "slide_count": len(slides),
                "image_count": sum(s["images"] for s in slides)}
