#!/usr/bin/env bash
# Build the port: reimport the art, export a standalone binary, render a preview.
#
#   ./build.sh [release|debug]
#
# This is the whole cycle in one command -- the one that has to run after every
# change, since a script can parse cleanly and still be wrong on screen.
#
# Needs Godot on $PATH or in $GODOT, plus its export templates for the engine
# version in use (~/.local/share/godot/export_templates/<version>/).

set -euo pipefail

MODE="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [ -n "${GODOT:-}" ] && command -v "$GODOT" >/dev/null 2>&1; then
  :
elif command -v godot >/dev/null 2>&1; then
  GODOT=godot
else
  # Godot is not usually on PATH here, so fall back to the usual unpacked
  # location before giving up. Quoted globs so a path with spaces survives.
  GODOT=""
  for candidate in "$HOME"/godot/Godot_v*/Godot_v* /tmp/opencode/godot/Godot_v*; do
    if [ -x "$candidate" ] && [ -f "$candidate" ]; then
      GODOT="$candidate"
      break
    fi
  done
  if [ -z "$GODOT" ]; then
    echo "godot not found. Put it on \$PATH or set GODOT=/path/to/godot" >&2
    exit 1
  fi
fi

echo "==> $("$GODOT" --version)"

# The import cache is what turns the SVGs into textures, so a stale or missing
# cache exports an untextured character. This has to happen before the export,
# not alongside it.
echo "==> importing assets"
"$GODOT" --headless --path "$ROOT/godot" --import >/dev/null 2>&1 || true

echo "==> exporting $MODE"
GODOT="$GODOT" "$ROOT/tools/build.sh" "$MODE"

# A preview of what actually shipped, so the result can be looked at rather than
# taken on trust. The binary is not rendered: it needs a display and the
# screenshot tool already provides one under xvfb.
#
# Judged on the file rather than the exit status -- Godot reports its teardown
# leaks on the way out and exits non-zero even when the frame rendered fine.
echo "==> rendering preview"
rm -f "$ROOT/preview/current_port.png"
GODOT="$GODOT" "$ROOT/tools/screenshot.sh" "$ROOT/preview/current_port.png" \
  >/dev/null 2>&1 || true
if [ -f "$ROOT/preview/current_port.png" ]; then
  echo "  preview/current_port.png"
else
  echo "  preview render failed (needs xvfb-run and a GL context)" >&2
fi

echo
echo "binary: build/linux/HalfneMikuStudio.x86_64"