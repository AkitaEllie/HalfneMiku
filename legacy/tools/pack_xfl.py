#!/usr/bin/env python3
"""Repack an extracted .fla directory into a single-file XFL.

An uncompressed XFL is one XML document: DOMDocument.xml with every
<Include itemID="..."/> replaced by the matching LIBRARY/<name>.xml symbol.
This is the same layout Flash's "Export Uncompressed XFL" produces, which is
what third-party XFL readers expect.
"""
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

XFL_NS = "http://ns.adobe.com/xfl/2008/"
ET.register_namespace("", XFL_NS)


def build_single_file_xfl(src_dir):
    dom_path = os.path.join(src_dir, "DOMDocument.xml")
    tree = ET.parse(dom_path)
    root = tree.getroot()

    lib_dir = os.path.join(src_dir, "LIBRARY")
    symbols = {}
    for dirpath, _dirnames, filenames in os.walk(lib_dir):
        for fn in filenames:
            if not fn.endswith(".xml"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, src_dir).replace(os.sep, "/")
            sym = ET.parse(full).getroot()
            symbols[sym.get("itemID")] = (rel, sym)

    symbols_root = root.find(f"{{{XFL_NS}}}symbols")
    if symbols_root is None:
        raise SystemExit("no <symbols> in DOMDocument.xml")

    # Map library itemID -> library item name.
    by_id = {item_id: rel for item_id, (rel, _sym) in symbols.items()}

    missing = []
    for inc in list(symbols_root):
        if inc.tag != f"{{{XFL_NS}}}Include":
            continue
        item_id = inc.get("itemID")
        if item_id not in symbols:
            missing.append(item_id)
            continue
        _rel, sym = symbols[item_id]
        idx = list(symbols_root).index(inc)
        symbols_root.remove(inc)
        symbols_root.insert(idx, sym)

    if missing:
        raise SystemExit(f"{len(missing)} includes unresolved: {missing[:5]}")

    out = ET.tostring(root, encoding="unicode", xml_declaration=True)
    return out


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: pack_xfl.py <extracted-fla-dir> <out.xfl>")
    src, dst = sys.argv[1], sys.argv[2]
    xml = build_single_file_xfl(src)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(xml)
    print(f"wrote {dst} ({os.path.getsize(dst)} bytes)")


if __name__ == "__main__":
    main()