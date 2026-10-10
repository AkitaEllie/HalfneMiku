#!/usr/bin/env python3
"""Crop an xfl2svg output to its drawn content.

xfl2svg emits a full-stage canvas (800x600) with the symbol's art sitting in
symbol space. As a Godot texture that wastes most of the pixels, and leaves the
part's local origin far from the node origin.

This rewrites the viewBox to the content bounds and reports where the symbol's
own origin (0,0) ends up inside the cropped texture, which is what the rig
needs for the sprite offset.
"""
import re
import sys
import xml.etree.ElementTree as ET

SVG = "http://www.w3.org/2000/svg"
XLINK = "http://www.w3.org/1999/xlink"
ET.register_namespace("", SVG)
ET.register_namespace("xlink", XLINK)
SVG = "{%s}" % SVG
XLINK = "{%s}" % XLINK
NUM = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")


def parse_matrix(s):
    v = [float(x) for x in NUM.findall(s or "")]
    if len(v) < 6:
        return (1, 0, 0, 1, 0, 0)
    return tuple(v[:6])


def mul(p, q):
    a, b, c, d, tx, ty = p
    A, B, C, D, TX, TY = q
    return (a * A + b * C, a * B + b * D, c * A + d * C, c * B + d * D,
            a * TX + b * TY + tx, c * TX + d * TY + ty)


def apply(m, x, y):
    a, b, c, d, tx, ty = m
    return (a * x + c * y + tx, b * x + d * y + ty)


def path_points(d):
    """Yield every coordinate pair appearing in path data.

    Deliberately simple: it samples the control points too, which only makes
    the bounds conservative, never wrong.
    """
    for mm in re.finditer(r"([MLCQZmlcqz])([^MLCQZmlcqz]*)", d or ""):
        cmd = mm.group(1)
        nums = [float(x) for x in NUM.findall(mm.group(2))]
        n = {"M": 2, "L": 2, "Q": 4, "C": 6}.get(cmd.upper(), 0)
        if not n:
            continue
        for i in range(0, len(nums) - n + 1, 2):
            yield nums[i], nums[i + 1]


def content_bbox(root):
    # Map every <use> target to the transforms it is instantiated under.
    uses = []

    def collect(el, mat):
        for c in el:
            tag = c.tag.replace(SVG, "")
            m = mul(mat, parse_matrix(c.get("transform"))) if c.get("transform") else mat
            if tag == "use":
                uses.append((c.get(f"{XLINK}href") or c.get("href") or "", m))
            elif tag in ("path", "polyline", "polygon", "line"):
                uses.append((None, m, c))
            else:
                collect(c, m)

    collect(root, (1, 0, 0, 1, 0, 0))

    # Direct geometry (paths inline in the body).
    direct = []
    for el in root.iter(SVG + "path"):
        direct.append((el, (1, 0, 0, 1, 0, 0)))

    # Geometry referenced by <use>: everything in <defs> is drawn once per use.
    defs = root.find(SVG + "defs")
    if defs is not None:
        by_id = {}
        for g in defs.iter():
            if g.get("id"):
                by_id[g.get("id")] = g
        for href, m, *rest in uses:
            if href is None:
                continue
            target = by_id.get(href.lstrip("#"))
            if target is None:
                continue
            for p in target.iter(SVG + "path"):
                direct.append((p, m))
        for item in uses:
            if len(item) == 3:
                pass

    minx = miny = float("inf")
    maxx = maxy = float("-inf")
    for p, m in direct:
        for x, y in path_points(p.get("d")):
            tx, ty = apply(m, x, y)
            minx, maxx = min(minx, tx), max(maxx, tx)
            miny, maxy = min(miny, ty), max(maxy, ty)
    if minx == float("inf"):
        return None
    return minx, miny, maxx, maxy


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: crop_svg.py <in.svg> <out.svg>")
    src, dst = sys.argv[1], sys.argv[2]
    tree = ET.parse(src)
    root = tree.getroot()

    # xfl2svg paints the stage colour across the whole canvas unless
    # --no-background is given. Once cropped, that rect would become an opaque
    # box around the art, so drop any canvas-sized rect either way.
    for rect in list(root.findall(SVG + "rect")):
        if rect.get("x") in (None, "0") and rect.get("y") in (None, "0"):
            root.remove(rect)

    bb = content_bbox(root)
    if bb is None:
        raise SystemExit(f"no geometry in {src}")

    pad = 1.0
    vx, vy = bb[0] - pad, bb[1] - pad
    vw, vh = bb[2] - bb[0] + pad * 2, bb[3] - bb[1] + pad * 2
    root.set("viewBox", f"{vx:.4f} {vy:.4f} {vw:.4f} {vh:.4f}")
    root.set("width", f"{vw:.4f}")
    root.set("height", f"{vh:.4f}")
    tree.write(dst, encoding="unicode", xml_declaration=False)
    print(f"{vx:.4f} {vy:.4f} {vw:.4f} {vh:.4f}")


if __name__ == "__main__":
    main()