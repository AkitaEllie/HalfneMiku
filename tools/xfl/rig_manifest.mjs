#!/usr/bin/env node
// Extract the Miku clip hierarchy from an extracted .fla directory.
//
// Geometry decoding is handled by xfl2svg (PluieElectrique); this tool only
// walks the XFL for the display list: which symbols are instanced where, with
// what matrix and registration point. That is what the Godot rig needs in
// order to rebuild the same clip tree Flash had.
//
// Writes rig.json: { parts: [...symbols to render...], rig: [...instances...] }

import fs from "node:fs";
import path from "node:path";

function parseXfl(xml) {
  const root = { tag: "#root", attrs: {}, children: [] };
  const stack = [root];
  const tagRe = /<([A-Za-z_][\w.:-]*)((?:\s+[\w.:-]+\s*=\s*"[^"]*")*)\s*(\/?)>|<\/([A-Za-z_][\w.:-]*)>|<!--[\s\S]*?-->/g;
  let m;
  const unesc = (s) =>
    s.replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
  while ((m = tagRe.exec(xml)) !== null) {
    if (m[4]) { if (stack.length > 1) stack.pop(); continue; }
    if (!m[1]) continue;
    const attrs = {};
    const attrRe = /([\w.:-]+)\s*=\s*"([^"]*)"/g;
    let a;
    while ((a = attrRe.exec(m[2])) !== null) attrs[a[1]] = unesc(a[2]);
    const el = { tag: m[1], attrs, children: [] };
    stack[stack.length - 1].children.push(el);
    if (!m[3]) stack.push(el);
  }
  return root;
}

const findAll = (el, tag, into = []) => {
  for (const c of el.children) {
    if (c.tag === tag) into.push(c);
    findAll(c, tag, into);
  }
  return into;
};

// The display list of a symbol's frame 1, in Flash's paint order: back to
// front, with DOMGroup members flattened into their parent.
//
// A group's own matrix is deliberately left alone -- the caller only renders
// and orders the tree, never re-transforms coordinates, so a nested group
// keeps whatever transform it was authored with.
function frameElements(sym) {
  const tl = findAll(sym, "DOMTimeline")[0];
  if (!tl) return [];
  const layers = tl.children.find((c) => c.tag === "layers");
  if (!layers) return [];
  const out = [];
  const collect = (el) => {
    if (el.tag === "DOMGroup") {
      const members = el.children.find((c) => c.tag === "members");
      if (members) for (const m of members.children) collect(m);
      return;
    }
    out.push(el);
  };
  // XFL lists the topmost layer first; Flash paints bottom-up.
  for (const layer of [...layers.children].reverse()) {
    if (layer.attrs.layerType === "guide" || layer.attrs.visible === "false") continue;
    const frames = layer.children.find((c) => c.tag === "frames");
    if (!frames) continue;
    const first = frames.children.find((c) => c.tag === "DOMFrame");
    const els = first?.children.find((c) => c.tag === "elements");
    if (!els) continue;
    for (const e of els.children) collect(e);
  }
  return out;
}

// Which interleave slot each of a symbol's own shapes sits in.
//
// A symbol's artwork is not necessarily all behind its child clips. Flash
// interleaves them: `Collar` draws its back shape, then the tie, then its
// front flap, so a single flattened texture would put the flap behind the
// tie. A shape's slot is the number of child clips painted before it, minus
// one -- -1 meaning "behind every clip".
function ownShapeSlots(sym) {
  const slots = [];
  let seen = 0;
  for (const el of frameElements(sym)) {
    if (el.tag === "DOMSymbolInstance") seen++;
    else if (el.tag === "DOMShape") slots.push(seen - 1);
  }
  return slots;
}

// XFL geometry, including symbol instance translations, is in twips.
const TWIPS_PER_PX = 20;

// Eyes and Mouth are frame-based timelines rather than one static picture, and
// Flash reaches a given expression by seeking to a *label* and then stepping
// forward by a phase index. Both symbols lay their artwork out as one layer of
// frame spans plus a layer of labels, so the frame for (set, phase) is found by
// taking the label's span and walking the artwork spans that overlap it.
const EXPRESSIONS = {
  "Miku parts/Eyes": ["open", "closed"],
  "Miku parts/Mouth": ["m", "a", "i", "u", "e", "o", "n"],
};

function layersOf(sym) {
  const tl = findAll(sym, "DOMTimeline")[0];
  const layers = tl?.children.find((c) => c.tag === "layers");
  if (!layers) return [];
  return [...layers.children].filter(
    (l) => l.attrs.layerType !== "guide" && l.attrs.visible !== "false"
  );
}

// Each DOMFrame covers `duration` timeline frames starting at `index`.
// XFL frames are sparse, so the index has to be honoured rather than counting
// sibling elements -- Eyes draws 16 frames across a 45-frame timeline.
// A frame span, plus the elements it holds. Used for guide-layer placement
// references, where the whole point is to read an instance's matrix.
function frameSpans(layer) {
  const frames = layer.children.find((c) => c.tag === "frames");
  if (!frames) return [];
  const out = [];
  for (const f of frames.children.filter((c) => c.tag === "DOMFrame")) {
    const start = num(f, "index", 0) + 1;
    const els = f.children.find((c) => c.tag === "elements");
    out.push({
      start,
      end: start + num(f, "duration", 1) - 1,
      name: f.attrs.name,
      labelled: f.attrs.labelType === "name",
      // The label layer also carries an (empty) <elements>, so the presence of
      // the tag is not enough -- it has to actually hold something.
      hasArt: !!els?.children.length,
      els: els?.children,
    });
  }
  return out;
}

// The labelled frames of a symbol, in timeline order. `Backdrop` uses these to
// pick out its eight named presets; `Eyes`/`Mouth` build expression tables
// from them.
function labelFrames(sym) {
  const out = [];
  for (const layer of layersOf(sym)) {
    for (const span of frameSpans(layer)) {
      if (span.labelled && span.name) out.push({ name: span.name, frame: span.start });
    }
  }
  return out;
}

function expressionTable(sym, phaseNames) {
  const art = [];
  const labels = [];
  for (const layer of layersOf(sym)) {
    for (const span of frameSpans(layer)) {
      if (span.labelled) labels.push(span);
      if (span.hasArt) art.push(span);
    }
  }
  const sets = [];
  for (const label of labels) {
    const phases = {};
    // Flash seeks to the label's frame, then steps forward one frame per
    // phase. The first phase is therefore the label frame itself -- even when
    // the artwork span containing it started earlier -- and each later phase is
    // the start of the next artwork span inside the set.
    const spans = art
      .filter((s) => s.end >= label.start && s.start <= label.end)
      .sort((a, b) => a.start - b.start);
    spans.forEach((span, i) => {
      if (i >= phaseNames.length) return;
      phases[phaseNames[i]] = i === 0 ? label.start : span.start;
    });
    if (Object.keys(phases).length) sets.push({ name: label.name, phases });
  }
  return sets.length ? { sets } : null;
}

const num = (el, key, dflt) => (el?.attrs?.[key] === undefined ? dflt : parseFloat(el.attrs[key]));

function matrixOf(inst) {
  const m = inst.children.find((c) => c.tag === "matrix")?.children.find((c) => c.tag === "Matrix");
  const g = (k, d) => num(m, k, d);
  return [g("a", 1), g("b", 0), g("c", 0), g("d", 1), g("tx", 0), g("ty", 0)];
}

function main() {
  const [xflDir, outFile, rootName = "Miku"] = process.argv.slice(2);
  if (!xflDir || !outFile) {
    console.error("usage: rig_manifest.mjs <extracted-fla-dir> <out.json> [rootSymbol]");
    process.exit(1);
  }

  const dom = parseXfl(fs.readFileSync(path.join(xflDir, "DOMDocument.xml"), "utf8"));

  // Index every library symbol by its itemID. The files are named after the
  // symbol path (LIBRARY/Miku parts/Ahoge.xml), not the id, so walk the tree.
  const byId = new Map();
  const libRoot = path.join(xflDir, "LIBRARY");
  const walkLib = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walkLib(full);
      else if (entry.name.endsWith(".xml")) {
        const doc = parseXfl(fs.readFileSync(full, "utf8"));
        const item = findAll(doc, "DOMSymbolItem")[0];
        if (item?.attrs.itemID) byId.set(item.attrs.itemID, item);
      }
    }
  };
  if (fs.existsSync(libRoot)) walkLib(libRoot);

  // Map library path -> symbol element, for resolving instance references.
  const byName = new Map();
  for (const item of byId.values()) byName.set(item.attrs.name, item);

  const timelineOf = (sym) =>
    findAll(sym, "DOMTimeline")[0];

  const instances = [];
  const seen = new Set();

  const walk = (sym, parentPath, depth) => {
    const tl = timelineOf(sym);
    if (!tl) return;
    const layers = tl.children.find((c) => c.tag === "layers");
    if (!layers) return;
    // XFL lists the topmost layer first; Godot draws later siblings on top, so
    // walk bottom-up to preserve Flash's paint order.
    for (const layer of [...layers.children].reverse()) {
      // Guide and hidden layers hold placement aids that are never drawn.
      if (layer.attrs.layerType === "guide" || layer.attrs.visible === "false") continue;
      const frames = layer.children.find((c) => c.tag === "frames");
      if (!frames) continue;
      const first = frames.children.find((c) => c.tag === "DOMFrame");
      const els = first?.children.find((c) => c.tag === "elements");
      if (!els) continue;
      for (const e of els.children) {
        const list = e.tag === "DOMSymbolInstance" ? [e]
          : e.tag === "DOMGroup" ? (e.children.find((c) => c.tag === "members")?.children || [])
          : [];
        for (const inst of list) {
          if (inst.tag !== "DOMSymbolInstance") continue;
          const name = inst.attrs.name || "unnamed";
          const symbol = inst.attrs.libraryItemName;
          const p = parentPath ? `${parentPath}.${name}` : name;
          const m = matrixOf(inst);
          const tp = inst.children.find((c) => c.tag === "transformationPoint")
        ?.children.find((c) => c.tag === "Point");
          instances.push({
            path: p,
            name,
            symbol,
            depth,
            matrix: [m[0], m[1], m[2], m[3], m[4], m[5]],
            tp: [num(tp, "x", 0) / TWIPS_PER_PX, num(tp, "y", 0) / TWIPS_PER_PX],
          });
          const child = byName.get(symbol);
          if (child && !seen.has(child)) {
            seen.add(child);
            walk(child, p, depth + 1);
          }
        }
      }
    }
  };

  const root = byName.get(rootName);
  if (!root) throw new Error(`root symbol not found: ${rootName}`);
  seen.add(root);
  walk(root, "", 0);

  // Symbols to render as part textures: the leaves the rig references.
  const used = new Set(instances.map((i) => i.symbol));
  const render = [];
  for (const name of byName.keys()) {
    if (!used.has(name)) continue;
    const sym = byName.get(name);
    const isLeaf = findAll(sym, "DOMSymbolInstance").length === 0;
    // Shapes belonging to this symbol itself, not to the clips it contains,
    // split by the slot they interleave into.
    const allSlots = ownShapeSlots(sym);
    const ownShapes = allSlots.length;
    const slots = [...new Set(allSlots)].sort((a, b) => a - b);
    render.push({ name, leaf: isLeaf, ownShapes, slots, stage: false });
  }

  // The backdrop is a timeline of named presets rather than one picture, so it
  // is rendered per labelled frame instead of being sliced like a composite.
  // Its `Miku` instance sits on a guide layer and is never drawn, so these
  // renders contain the backdrop only.
  const stage = {};
  const backdrop = byName.get("Backdrop");
  if (backdrop) {
    const presets = labelFrames(backdrop);
    if (presets.length) stage["Backdrop"] = presets;
  }

// Where the character goes on stage. The document's own root timeline instances
// it at a=1.25, tx=383.45, ty=466.65 -- a scale that is easy to miss, since the
// FLA's geometry and the rig matrices are all unscaled. Read it from there
// rather than hardcoding, and use the document's stage size rather than
// Backdrop.Autofit's legacy 640x480, which only applies to user-loaded images.
let placement = null;
const stageSize = [num(dom, "width", 800), num(dom, "height", 600)];
for (const tl of findAll(dom, "DOMTimeline")) {
  for (const layer of findAll(tl, "DOMLayer")) {
    for (const inst of findAll(layer, "DOMSymbolInstance")) {
      if (inst.attrs.libraryItemName !== rootName) continue;
      const m = matrixOf(inst);
      placement = { x: m[4], y: m[5], scale: [m[0], m[3]], stage: stageSize };
    }
  }
}

  // Frame-based expressions, keyed by symbol. These are not part textures: the
  // rig picks one per state at runtime instead of baking a single frame.
  const expressions = {};
  for (const [name, phases] of Object.entries(EXPRESSIONS)) {
    const sym = byName.get(name);
    if (!sym) continue;
    const table = expressionTable(sym, phases);
    if (table) expressions[name] = table;
  }

  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(
    outFile,
    JSON.stringify({ root: rootName, render, rig: instances, expressions, stage, placement }, null, 1)
  );
  console.log(
    `rig: ${instances.length} instances, ${render.length} symbols to render, ` +
      `${Object.keys(expressions).length} expression timelines, ` +
      `${Object.values(stage).flat().length} stage presets` +
      (placement ? `, stage placement ${placement.x},${placement.y}` : '')
  );
}

main();