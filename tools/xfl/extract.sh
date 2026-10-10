#!/usr/bin/env bash
# Rebuild the Godot art assets from the original .fla.
#
#   tools/xfl/extract.sh "reference/Halfne Miku.fla"
#
# A .fla is a zip of XFL (plain XML), and this particular archive has a damaged
# central directory, which `zip -FF` repairs.
#
# Art comes from xfl2svg (https://github.com/PluieElectrique/xfl2svg), which
# decodes the XFL edge formats and the twip scaling. This script only supplies
# it with a decompressed directory, renders one SVG per symbol, and crops each
# to its content.
#
# The clip hierarchy is extracted separately by rig_manifest.mjs, because
# xfl2svg renders timelines rather than exposing the display list.
#
# Outputs godot/assets/parts/*.svg, godot/assets/bg/*.svg and godot/data/rig.json.

set -euo pipefail

FLA="${1:-reference/Halfne Miku.fla}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> repairing and unpacking $FLA"
cp "$ROOT/$FLA" "$WORK/broken.zip"
# NB: no -q here. zip -FF scans the archive and emits progress as it goes;
# suppressing it yields an empty file.
zip -FF "$WORK/broken.zip" --out "$WORK/fixed.zip" >/dev/null
mkdir -p "$WORK/xfl"
unzip -q -o "$WORK/fixed.zip" -d "$WORK/xfl"
test -f "$WORK/xfl/DOMDocument.xml" || { echo "unpack failed"; exit 1; }

echo "==> locating xfl2svg"
if [ -n "${XFL2SVG:-}" ] && [ -x "$XFL2SVG" ]; then
  :
elif command -v xfl2svg >/dev/null 2>&1; then
  XFL2SVG="$(command -v xfl2svg)"
elif [ -x "$ROOT/.venv/bin/xfl2svg" ]; then
  XFL2SVG="$ROOT/.venv/bin/xfl2svg"
else
  echo "xfl2svg not found. Install it with:" >&2
  echo "  python3 -m venv .venv && .venv/bin/pip install git+https://github.com/PluieElectrique/xfl2svg" >&2
  exit 1
fi
export XFL2SVG

echo "==> extracting clip hierarchy"
node "$ROOT/tools/xfl/rig_manifest.mjs" "$WORK/xfl" "$WORK/rig.json" Miku

# Composites keep their own shapes (the torso, collar, head base, face) once
# their child clips are removed, and Flash interleaves those shapes *among*
# the clips rather than drawing them all first -- so each composite is sliced
# into one texture per slot. Leaves keep their full artwork.
echo "==> slicing composites by interleave slot"
SLOTS="$(python3 - "$WORK/rig.json" <<'PY'
import json, sys
rig = json.load(open(sys.argv[1]))
slots = set()
for sym in rig["render"]:
    if sym["leaf"] or not sym.get("slots"):
        continue
    slots.update(sym["slots"])
print(",".join(str(s) for s in sorted(slots)))
PY
)"
python3 "$ROOT/tools/xfl/slice_symbols.py" "$WORK/xfl" "$WORK/sliced" "$SLOTS"

echo "==> rendering symbols"
mkdir -p "$WORK/svg"
python3 - "$WORK/rig.json" "$WORK/xfl" "$WORK/svg" "$WORK/sliced" <<'PY'
import json, os, shutil, subprocess, sys, tempfile

rig = json.load(open(sys.argv[1]))
xfl, out, sliced = sys.argv[2], sys.argv[3], sys.argv[4]
tool = os.environ["XFL2SVG"]

for sym in rig["render"]:
    # A pure container (a composite with no shapes of its own, e.g. Arm_R)
    # renders to nothing once its clips are sliced away, so skip it.
    if not sym["leaf"] and not sym.get("ownShapes"):
        continue

    stem = sym["name"].replace("/", "_")
    jobs = []
    if sym["leaf"]:
        jobs = [(sym["slots"][0] if sym.get("slots") else -1, xfl)]
    else:
        jobs = [(s, os.path.join(sliced, "slot%+d" % s)) for s in sym["slots"]]

    for slot, src in jobs:
        # Render exactly one frame. Pinning both ends matters: symbols like Eyes and
        # Mouth are frame-based timelines (45 and 90 frames), and without
        # --last-frame every frame is emitted.
        #
        # xfl2svg names its output after the timeline, sanitised in ways that are
        # not worth predicting ("Miku parts/Ahoge" -> "Miku parts_Ahoge_001.svg"),
        # so render into a scratch dir and take the _001 frame.
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([tool, src, sym["name"], tmp, "--timeline-type", "symbol",
                            "--first-frame", "1", "--last-frame", "1", "--no-background"],
                           check=True, capture_output=True)
            produced = sorted(f for f in os.listdir(tmp) if f.endswith("_001.svg"))
            if not produced:
                raise SystemExit(f"xfl2svg produced no frame 1 for {sym['name']} slot {slot}")
            suffix = "" if slot == -1 else "__slot%+d" % slot
            shutil.move(os.path.join(tmp, produced[0]),
                        os.path.join(out, stem + suffix + ".svg"))

n = len([f for f in os.listdir(out) if f.endswith(".svg")])
print(f"rendered {n} symbol slices")

# Eyes and Mouth are frame-based timelines, and the rig needs one texture per
# expression rather than the single frame pinned above. Render each whole
# timeline once and keep only the frames the expression table names.
if rig.get("expressions"):
    print(f"rendering {len(rig['expressions'])} expression timelines")
    for name, table in rig["expressions"].items():
        stem = name.replace("/", "_")
        wanted = {}
        for entry in table["sets"]:
            for phase, frame in entry["phases"].items():
                wanted[frame] = "%s__%s__%s" % (stem, entry["name"], phase)
        last = max(wanted)
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([tool, xfl, name, tmp, "--timeline-type", "symbol",
                            "--first-frame", "1", "--last-frame", str(last),
                            "--no-background"], check=True, capture_output=True)
            for frame, dest_stem in sorted(wanted.items()):
                src = os.path.join(tmp, "%s_%03d.svg" % (stem, frame))
                if not os.path.exists(src):
                    raise SystemExit(f"no frame {frame} of {name} (wanted {dest_stem})")
                shutil.copy(src, os.path.join(out, dest_stem + ".svg"))
        print(f"  {name}: {len(wanted)} frames -> {last}")

# The backdrop is a timeline of named presets. Render it once per labelled
# frame. These are separate images rather than rig slices: they are stage art,
# and the symbol also carries a guide-layer Miku reference that must not be
# drawn.
if rig.get("stage"):
    for name, presets in rig["stage"].items():
        stem = name.replace("/", "_")
        last = max(p["frame"] for p in presets)
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([tool, xfl, name, tmp, "--timeline-type", "symbol",
                            "--first-frame", "1", "--last-frame", str(last),
                            "--no-background"], check=True, capture_output=True)
            for preset in presets:
                src = os.path.join(tmp, "%s_%03d.svg" % (stem, preset["frame"]))
                if not os.path.exists(src):
                    raise SystemExit("no frame %d of %s (%s)" % (
                        preset["frame"], name, preset["name"]))
                safe = preset["name"].replace("/", "_").replace(" ", "_")
                shutil.copy(src, os.path.join(out, "%s__%s.svg" % (stem, safe)))
        print(f"  {name}: {len(presets)} stage presets -> {last}")
PY

echo "==> cropping and installing"
python3 "$ROOT/tools/xfl/install_godot.py" "$WORK" "$ROOT/godot"

echo "done."
