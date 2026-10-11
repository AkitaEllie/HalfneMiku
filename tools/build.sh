#!/usr/bin/env bash
# Export a standalone Linux build of the Godot project.
#
#   tools/build.sh [release|debug]
#
# Needs Godot's export templates installed for the engine version in use
# (~/.local/share/godot/export_templates/<version>/). The output is a single
# self-contained binary with the PCK embedded.

set -euo pipefail

MODE="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PRESET="Linux (x86_64)"
OUT="$ROOT/build/linux/HalfneMikuStudio.x86_64"

command -v "$GODOT" >/dev/null 2>&1 || { echo "godot not found; set GODOT=..." >&2; exit 1; }

# `godot --version` prints e.g. 4.7.2.stable.official.ed1daf0bf, or
# 4.7.2.stable.arch_linux.ed1daf0bf for some builds, but the template directory
# is named for just 4.7.2.stable. Strip the qualifier and anything after it.
VERSION="$("$GODOT" --version | sed -E 's/\.(official|beta|alpha|rc[0-9]*|dev[0-9]*|arch_[a-z]+).*$//')"
TEMPLATES="$HOME/.local/share/godot/export_templates/$VERSION"
if [ ! -f "$TEMPLATES/linux_release.x86_64" ]; then
  echo "export templates missing for $VERSION." >&2
  echo "Download and unzip Godot_v${VERSION}_export_templates.tpz into:" >&2
  echo "  $TEMPLATES" >&2
  exit 1
fi

# The import cache is what turns the SVGs into textures, so a stale or missing
# cache exports an untextured character.
"$GODOT" --headless --path "$ROOT/godot" --import >/dev/null 2>&1 || true

mkdir -p "$(dirname "$OUT")"
FLAG=--export-release
[ "$MODE" = "debug" ] && FLAG=--export-debug

echo "==> exporting $MODE -> $OUT"
"$GODOT" --headless --path "$ROOT/godot" "$FLAG" "$PRESET"

ls -la "$OUT"
echo "run it with: $OUT"