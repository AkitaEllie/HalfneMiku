#!/usr/bin/env python3
"""Crop the rendered symbol SVGs and install them into the Godot project.

xfl2svg renders each symbol onto a full 800x600 stage canvas. Cropping to the
drawn content keeps the textures small and, more importantly, puts the symbol's
local origin at a known place inside the texture so the rig can place it.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def png_content_bbox(path):
    """Alpha bounding box of a PNG, as (x0, y0, x1, y1). None if fully empty."""
    try:
        from PIL import Image
    except ImportError:
        return None
    with Image.open(path) as im:
        alpha = im.convert("RGBA").split()[3]
        bb = alpha.getbbox()
    return bb


def crop_png(src, dst, bbox):
    """Crop a PNG to `bbox` (x0, y0, x1, y1) and return the destination."""
    from PIL import Image
    with Image.open(src) as im:
        im.crop(bbox).save(dst)
    return dst


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: install_godot.py <workdir> <godot-root>")
    work, godot = sys.argv[1], sys.argv[2]

    with open(os.path.join(work, "rig.json"), encoding="utf-8") as fh:
        data = json.load(fh)

    # Symbols the rig references, plus the composites that contribute their own
    # shapes even though they also contain clips.
    used = {node["symbol"] for node in data["rig"]}
    used |= {s["name"] for s in data["render"] if s.get("ownShapes")}
    parts_dir = os.path.join(godot, "assets", "parts")
    shutil.rmtree(parts_dir, ignore_errors=True)
    os.makedirs(parts_dir, exist_ok=True)

    parts, stage = [], {}
    for sym in data["render"]:
        # Only symbols actually used by the rig are shipped.
        if sym["name"] not in used:
            continue
        stem = sym["name"].replace("/", "_")

        # One texture per interleave slot. Leaves have a single slot -1 (behind
        # every clip); composites have one per slot they own art in, so the
        # rig can weave their artwork in among the child clips.
        for slot in (sym.get("slots") or [-1]):
            suffix = "" if slot == -1 else "__slot%+d" % slot
            rendered = os.path.join(work, "svg", stem + suffix + ".svg")
            if not os.path.exists(rendered):
                # This slot had no artwork to draw.
                continue

            part_id = stem + suffix
            dest = os.path.join(parts_dir, part_id + ".svg")
            res = subprocess.run(
                [sys.executable, os.path.join(HERE, "crop_svg.py"), rendered, dest],
                check=True, capture_output=True, text=True)
            vx, vy, vw, vh = (float(x) for x in res.stdout.split())

            parts.append({
                "id": part_id,
                "name": sym["name"],
                "file": "res://assets/parts/%s.svg" % part_id,
                # viewBox min, i.e. where symbol-space (0,0) sits inside the
                # texture. With Sprite2D centred off, a texture pixel draws at
                # `offset`, so offset must equal the viewBox origin.
                "origin": [vx, vy],
                "size": [vw, vh],
                # Position among the clip's own child clips; -1 is in front of
                # none, 0 after the first clip, and so on.
                "slot": slot,
            })

    # The incoming `stage` maps symbol -> labelled presets; the outgoing one
    # maps preset name -> texture. Read the presets off `data` before
    # overwriting it.
    presets_by_symbol: dict = data.get("stage", {})
    stage: dict = {}  # preset name -> texture descriptor
    bg_dir = os.path.join(godot, "assets", "bg")
    shutil.rmtree(bg_dir, ignore_errors=True)
    os.makedirs(bg_dir, exist_ok=True)
    for name, presets in presets_by_symbol.items():
        stem = name.replace("/", "_")
        for preset in presets:
            safe = preset["name"].replace("/", "_").replace(" ", "_")
            # JPEXS supplies the backdrop as PNG (correct gradients and
            # filters, which xfl2svg silently drops). Fall back to the xfl2svg
            # SVG only if FFDEC was not set at extract time.
            png = os.path.join(work, "svg", "%s__%s.png" % (stem, safe))
            if os.path.exists(png):
                dest = os.path.join(bg_dir, "%s__%s.png" % (stem, safe))
                entry = {"file": "res://assets/bg/%s__%s.png" % (stem, safe)}
                bb = png_content_bbox(png)
                if bb:
                    # Crop to the art rather than shipping the padded canvas.
                    # JPEXS draws every preset on the symbol's whole extent, so
                    # the frames share a canvas but the art inside it is what
                    # has to line up. Every preset but `blank` crops to the same
                    # box, which is what keeps them registered with each other.
                    crop_png(png, dest, bb)
                    entry["size"] = [bb[2] - bb[0], bb[3] - bb[1]]
                else:
                    # `blank` is genuinely empty; ship it as-is so the preset
                    # still resolves.
                    shutil.copy(png, dest)
                stage[preset["name"]] = entry
                continue
            rendered = os.path.join(work, "svg", "%s__%s.svg" % (stem, safe))
            if not os.path.exists(rendered):
                continue
            dest = os.path.join(bg_dir, "%s__%s.svg" % (stem, safe))
            res = subprocess.run(
                [sys.executable, os.path.join(HERE, "crop_svg.py"), rendered, dest],
                check=True, capture_output=True, text=True)
            vx, vy, vw, vh = (float(x) for x in res.stdout.split())
            stage[preset["name"]] = {
                "file": "res://assets/bg/%s__%s.svg" % (stem, safe),
                "origin": [vx, vy],
                "size": [vw, vh],
            }
    data["stage"] = stage

    # Expressions: one cropped texture per (set, phase), keyed by name so the
    # rig can swap a texture at runtime instead of baking a single frame.
    expressions = {}
    for name, table in data.get("expressions", {}).items():
        stem = name.replace("/", "_")
        sets = {}
        for entry in table["sets"]:
            phases = {}
            for phase in entry["phases"]:
                part_id = "%s__%s__%s" % (stem, entry["name"], phase)
                rendered = os.path.join(work, "svg", part_id + ".svg")
                if not os.path.exists(rendered):
                    continue
                dest = os.path.join(parts_dir, part_id + ".svg")
                res = subprocess.run(
                    [sys.executable, os.path.join(HERE, "crop_svg.py"), rendered, dest],
                    check=True, capture_output=True, text=True)
                vx, vy, vw, vh = (float(x) for x in res.stdout.split())
                parts.append({
                    "id": part_id,
                    "name": name,
                    "file": "res://assets/parts/%s.svg" % part_id,
                    "origin": [vx, vy],
                    "size": [vw, vh],
                })
                phases[phase] = {
                    "texture": "res://assets/parts/%s.svg" % part_id,
                    # Each frame is cropped on its own, so the origin differs per
                    # expression; a mouth shape is not the same extent as an eye.
                    "origin": [vx, vy],
                }
            if phases:
                sets[entry["name"]] = phases
        if sets:
            expressions[name] = sets
    data["expressions"] = expressions
    # Assigned last: the expression loop appends to `parts`.
    data["parts"] = parts

    os.makedirs(os.path.join(godot, "data"), exist_ok=True)
    with open(os.path.join(godot, "data", "rig.json"), "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1)

    print(f"installed {len(parts)} part textures, {len(stage)} stage images, "
          f"{len(data['rig'])} rig nodes")


if __name__ == "__main__":
    main()