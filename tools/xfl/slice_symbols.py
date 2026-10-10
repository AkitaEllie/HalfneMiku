#!/usr/bin/env python3
"""Produce copies of the XFL with each composite symbol reduced to one slot.

Several symbols contain both shapes of their own and child clips, and Flash
interleaves the two rather than always painting a symbol's own art first:

    Collar      shape, [tie], shape, shape
    Face        [eyes], [mouth], shape
    UpperBody   [shirt_R], [shirt_L], shape, shape, shape
    Head        [phone_L], [momi_L], shape, [clipBL] ... [ahoge]

Baking a composite into one texture therefore loses the ordering -- the
collar's front flap would end up behind the tie, and the face behind the eyes.
Each shape is instead assigned a *slot*, the number of child clips painted
before it minus one, and the symbol is rendered once per slot.

This script writes one variant tree per distinct slot value, where every
composite symbol has been reduced to just the shapes in that slot. All the
variants agree on which slot a shape belongs to, so a single pass per slot
covers every composite at once -- the four composites above only need the
variants for slots -1, 0 and 1.
"""
import os
import shutil
import sys
import xml.etree.ElementTree as ET

XFL = "{http://ns.adobe.com/xfl/2008/}"
ET.register_namespace("", XFL[1:-1])

SKIP_LAYER = ("guide", "hidden")


def flatten(container, out, visited):
    """Flatten a frame's elements, remembering which container each sits in."""
    visited.add(container)
    for child in list(container):
        if child.tag == XFL + "DOMGroup":
            members = child.find(XFL + "members")
            if members is not None:
                flatten(members, out, visited)
        else:
            out.append((container, child))


def element_slots(container):
    """([(container, element, slot)], visited) for a frame's elements."""
    items = []
    visited = set()
    flatten(container, items, visited)
    out, seen = [], 0
    for holder, el in items:
        if el.tag == XFL + "DOMSymbolInstance":
            seen += 1
        elif el.tag == XFL + "DOMShape":
            out.append((holder, el, seen - 1))
    return out, visited


def drop_empty_groups(root):
    """Remove groups left with no shapes once their slot was carved out.

    The whole group has to go, not just its <members>: xfl2svg assumes the
    last child of a DOMGroup is always a <members> and indexes into it.
    """
    for _ in range(8):  # nested groups collapse outermost-last
        empty = [g for g in root.iter(XFL + "DOMGroup")
                 if not any(s.tag == XFL + "DOMShape" for s in g.iter())]
        if not empty:
            break
        for group in empty:
            for node in root.iter():
                if group in list(node):
                    node.remove(group)
                    break


def slice_symbol(path, wanted):
    """Keep only this symbol's shapes belonging to `wanted`, drop every clip."""
    tree = ET.parse(path)
    root = tree.getroot()

    # A leaf has no clips to interleave with, so all of its shapes already sit
    # behind nothing; slicing it would only destroy artwork in the other
    # variants.
    if not any(True for _ in root.iter(XFL + "DOMSymbolInstance")):
        return False

    touched = False
    for layers in list(root.iter(XFL + "layers")):
        for layer in list(layers):
            if layer.get("layerType") in SKIP_LAYER or layer.get("visible") == "false":
                continue
            frames = layer.find(XFL + "frames")
            if frames is None:
                continue
            first = frames.find(XFL + "DOMFrame")
            if first is None:
                continue
            els = first.find(XFL + "elements")
            if els is None:
                continue

            entries, visited = element_slots(els)
            if not entries:
                continue
            touched = True

            keep = {id(shape) for _, shape, slot in entries if slot == wanted}
            # Every container walked while flattening has to be swept, not just
            # the ones holding a kept shape: clips usually sit in <elements>
            # while the artwork sits in a nested group's <members>, so sweeping
            # only the shape's own container leaves the clips in the tree and
            # bakes them into the texture.
            for holder in {id(h): h for h in visited}.values():
                for child in list(holder):
                    if child.tag == XFL + "DOMSymbolInstance":
                        holder.remove(child)
                    elif child.tag == XFL + "DOMShape" and id(child) not in keep:
                        holder.remove(child)

    if not touched:
        return False
    drop_empty_groups(root)
    tree.write(path, encoding="unicode", xml_declaration=True)
    return True


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: slice_symbols.py <xfl-dir> <out-root> <slot,slot,...>")
    src, out_root, slots = sys.argv[1], sys.argv[2], sys.argv[3]
    wanted_slots = [int(s) for s in slots.split(",")]

    made = []
    for slot in wanted_slots:
        dst = os.path.join(out_root, "slot%+d" % slot)
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(src, dst)
        # Carving a slot out of *every* symbol would be wasteful: only the
        # composites that own shapes are sliced, and leaves are left alone so
        # they still render their full artwork.
        lib = os.path.join(dst, "LIBRARY")
        for dirpath, _dirs, files in os.walk(lib):
            for fn in files:
                if fn.endswith(".xml"):
                    slice_symbol(os.path.join(dirpath, fn), slot)
        made.append(dst)
    print("sliced variants for slots %s -> %s"
          % (wanted_slots, ", ".join(os.path.basename(d) for d in made)))


if __name__ == "__main__":
    main()