# HalfneMiku
Halfne Miku Studio

(from https://johnsu.deviantart.com/art/Halfne-Miku-Studio-396850314):
""Halfne Miku Studio" is a very basic dancing program with the goal of allowing you to entertain yourself as you listen to music and pretend Miku is singing and dancing to it, because either you can't find any videos of it, or you don't know how to make them yourself (but you at least know how to wave a mouse to a beat and tap a space bar to some notes!)."

If you just wanted to edit this to mod characters into it, just check out the 'Miku' symbol in the library and mess with the parts. The physics and attachments for those parts are set up in Layer1 of that symbol

Most of the actionscript is scattered throughout the .fla file (saved in Adobe Flash CS6 format) with a couple generic helper .as3 files to accompany it. My apologies to anyone who has to wade through this - I had never intended this to be a large project, so it's not organized for friendly development.

-John Su

---

## This repository

A **Godot 4 / GDScript port** of Halfne Miku Studio, written from the original
Flash files in `reference/`. The artwork is extracted from the author's `.fla`,
so the character is still the original vector art rather than a re-draw.

Flash is end-of-life, so the point of the port is to keep the thing runnable on
a current machine and to make the rig legible and editable as code.

`PORTING.md` is the working notes: how the pipeline works, and the traps in the
Flash formats that will bite anyone extending it.

### Status

Ported: the art pipeline, the 36-clip rig (attachments, lean, IK), the Swinger
spring physics, mouse follow, and the face — 8 eye sets with blinking and 8 mouth
sets with 7 vowels.

Not yet: audio, mouse recording/playback, the scrolling backdrop, and the
timeline editor UI.

### Quick start

Rebuild the art from the `.fla` (needs
[xfl2svg](https://github.com/PluieElectrique/xfl2svg)):

```sh
python3 -m venv .venv
.venv/bin/pip install git+https://github.com/PluieElectrique/xfl2svg
tools/xfl/extract.sh
cd godot && godot --headless --import
```

Then either run the project from the editor, or build a standalone binary:

```sh
tools/build.sh            # -> build/linux/HalfneMikuStudio.x86_64
```

Exporting needs Godot's export templates for your engine version in
`~/.local/share/godot/export_templates/`. `tools/screenshot.sh <out.png>`
renders a single frame, and `tools/build.sh debug` produces a debug build.

### Controls

Move the mouse to make Miku follow it. `X` blinks (hold). `A` `S` `W` `E` `D` `Q`
are mouth vowels (hold; they stack, and releasing falls back to the last one
held). `Space` picks a random vowel. `1`-`8` choose an eye set, `[` and `]`
cycle mouth sets. `Escape` quits.

### Layout

`reference/` holds the originals and is never edited. `godot/` is the port.
`tools/` holds the extraction and build scripts. `preview/` holds current
renders, `legacy/` holds superseded ones.

### Credits and licensing

Halfne Miku Studio is by [John Su](https://johnsu.deviantart.com/art/Halfne-Miku-Studio-396850314),
and Miku Hatsune is by Crypton/Future Media. The original `.fla`, `.swf`, `.gif`
and helper `.as3` files are redistributed unmodified under the terms in
`LICENSE` — this port is a derived work and inherits those terms. No assets here
were redrawn; they come straight out of the author's files.
