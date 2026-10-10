#!/usr/bin/env bash
# Render one frame of the Godot project to a PNG.
#
#   tools/screenshot.sh <out.png> [width] [height]
#
# Used to produce the previews in preview/ and to eyeball rig changes without
# exporting a build. The project has to actually render, so this needs a real
# display; xvfb-run provides one when there is no X server around.

set -euo pipefail

OUT="${1:?usage: screenshot.sh <out.png> [width] [height]}"
W="${2:-800}"
H="${3:-600}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

RUN=()
if ! command -v "$GODOT" >/dev/null 2>&1; then
  echo "godot not found; set GODOT=/path/to/godot" >&2
  exit 1
fi
if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
  RUN=(xvfb-run -a)
fi

mkdir -p "$(dirname "$OUT")"
# --rest-pose holds the rig still so the capture is comparable to a render of
# the original; left running, the demo sweep would move it.
"${RUN[@]}" "$GODOT" --path "$ROOT/godot" --resolution "${W}x${H}" \
  -- --rest-pose --shot="$(realpath -m "$OUT")"