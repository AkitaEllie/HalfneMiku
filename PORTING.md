# Port notes

A Godot 4 / GDScript port of **Halfne Miku Studio**, plus the tooling that
extracts the artwork from the original Flash authoring file.

These notes record how the original behaves, and the traps in the Flash formats
— the things that cause the port to diverge from it. Engine mechanics are not
documented here; see the Godot docs for that.

## Current milestone

The character stands, follows the mouse, and animates its own hair and clothes
via the ported spring physics. Art, rig and face are done.

Ported: art extraction, the 36-clip rig, Swinger physics, mouse follow, the
face (8 eye sets with blink, 8 mouth sets with 7 vowels, held-vowel stack), and
the eight backdrop presets.

Not yet: audio, mouse recording/playback, and the timeline editor UI. See
*Still to do*.

## Layout

```
reference/          originals and ground truth. Never edit these.
  Halfne Miku.fla     the Flash authoring file; art is extracted from it
  *.swf               the compiled original, used to verify geometry and
                      behaviour (JPEXS reads its display lists and scripts)
  reference_swf.png   JPEXS render of the whole character, 274x263 tight-cropped
  DV.gif              the original animation, for eyeballing motion
  as3/                the ActionScript helper classes shipped inside the .fla

tools/              build scripts
  build.sh            export a standalone binary
  screenshot.sh       render one frame to a PNG
  xfl/                extraction pipeline
    extract.sh          one-shot: rebuild all art from the .fla
    rig_manifest.mjs    XFL -> clip hierarchy, interleave slots, expression tables
    slice_symbols.py    per-slot variants of each composite symbol
    crop_svg.py         crops a rendered symbol to its content
    install_godot.py    copies assets into godot/

godot/              the port itself
  assets/bg/*.svg     the eight backdrop presets
preview/             current renders only
legacy/preview/      superseded demo captures from earlier iterations
build/               export output, gitignored
```

## Rebuilding and building

```sh
python3 -m venv .venv
.venv/bin/pip install git+https://github.com/PluieElectrique/xfl2svg
tools/xfl/extract.sh          # defaults to reference/Halfne Miku.fla

tools/screenshot.sh preview/current_port.png
tools/build.sh                # -> build/linux/HalfneMikuStudio.x86_64
```

`extract.sh` repairs the archive with `zip -FF`, renders each symbol through
xfl2svg, slices the composites, and installs cropped textures plus `rig.json`.

`build.sh` needs Godot's export templates in
`~/.local/share/godot/export_templates/<version>/`. The directory is named for
the version without build metadata, i.e. `4.7.2.stable`, not
`4.7.2.stable.official.ed1daf0bf`.

## Composites interleave their art with their clips

A symbol can hold both shapes of its own *and* child clips, and Flash does not
draw all the symbol's own shapes first. It interleaves them:

```
Collar      shape, [tie], shape, shape
Face        [eyes], [mouth], shape
UpperBody   [shirt_R], [shirt_L], shape, shape, shape
Head        [phone_L], [momi_L], shape, [clipBL] ... [ahoge]
```

Baking a composite into one texture destroys that ordering — the collar's front
flap ends up behind the tie, the face behind the eyes. Confirmed against the
SWF, where the compiler split the same symbols into depths 1/2/6 for the back
shape, the tie and the front flap.

So each own shape gets a **slot**: the number of child clips painted before it,
minus one (`-1` = behind every clip). `rig_manifest.mjs` computes those slots,
`slice_symbols.py` writes one variant tree per distinct slot holding just that
slot's shapes, and the rig weaves the slices in among the child clips.

Four composites are affected, and only slots `-1`, `0`, `1` and `5` occur
overall — so slicing is cheap. `Head`'s slot 1 is the microphone, which sits
after `phone_L` and `momi_L` and before `clipBL`, matching SWF depth 5.

**When carving a slice out, sweep every container you walked, not just the ones
holding a kept shape.** Artwork often sits inside a `DOMGroup`'s `<members>`
while the clips sit in the frame's `<elements>`; sweeping only the shape's own
container leaves the clips in the tree and bakes them into the texture. That is
what buried the face: `Face`'s slice came to contain the eyes and mouth
drawings, so a static face covered the live expression clips and blinking
appeared to stack. Check a slice for stray `DOMSymbolInstance` elements after
changing the slicer.

## Eyes and Mouth are frame-based timelines, not one picture

Both reach a given expression by seeking to a *label* and stepping forward a
frame per phase:

```as3
gotoAndStop(mSet);
gotoAndStop(currentFrame + mPhase);
```

Eyes has 8 sets x open/closed; Mouth has 8 sets x 7 vowels (`m a i u e o n`).
The frame for each (set, phase) is derived from the XFL layer spans rather than
hardcoded, and the pipeline renders each whole timeline once and keeps the
frames that table names.

**The rest pose has a closed mouth, and that is correct.** `Mouth.Init()` sets
`happy`/`m`, while a static frame-1 export of the SWF shows frame 1, which is
the open `a` mouth. So `reference/reference_swf.png` — a JPEXS frame-1 render —
shows an open mouth and the running app does not. The eye art, by contrast,
matches the reference exactly, because `Eyes`' frame 1 *is* `happy`/open.

## The backdrop is a timeline of presets, not a layer

`Backdrop` is a symbol with eight labelled frames — `concert stage`,
`wood stage`, `negi field`, `miku miku`, `desktop`, `attic`, `park`, `blank` —
and `Backdrop.LoadBg` picks one by seeking to the label. So each preset is
rendered as its own image rather than sliced like a composite.

Four details matter:

- **The presets are drawn 1:1, not autofitted.** `Autofit` scales by
  `max(stage_w/img_w, stage_h/img_h)` and centres the overflow — but it is only
  called for a *user-loaded* image. `LoadBg` just seeks to the label, so the
  bundled presets render at their authored size in symbol coordinates. Scaling
  them to cover instead throws the character off every floor bar one, because
  each preset has different content bounds.
- **Place each preset by its symbol origin, not by centring.** Screen position
  is `position + offset + texel * scale`, and a texel is `symbol - origin`, so
  putting symbol coordinates at `symbol * scale` needs
  `offset = origin * scale`. Parts need no such correction because they are
  drawn unscaled; backdrops do, or they land off in a corner.
- **Its `Miku` instance sits on a *guide* layer.** It is a placement reference
  and is never drawn, which is why these render correctly despite `Backdrop`
  being a composite — and why it must not be treated as a rig symbol. It is also
  the authoritative answer to *where the character stands*: `(306.75, 373.3)` in
  the original's 640x480 stage coordinates. Scale that to the viewport rather
  than inventing a ground line, or she floats above the backdrops.
- **A mask layer clips the art to y <= 480**, so sky shows beneath it. That is
  in the original too, and is why the stage has a flat sky colour underneath
  rather than being fully covered.
- **It also accepts a user-supplied image** (`LoadData`), scaled the same way
  and pannable/zoomable with the mouse. That path is not ported.

## Traps in the Flash formats

**A `.fla` is a zip of XFL (plain XML).** No Flash needed. But *this* archive
has a damaged central directory. `zip -FF` repairs it — and must not be given
`-q`, because the progress output *is* the scan; `zip -q -FF` silently writes a
22-byte empty archive.

**Shape geometry is in twips (1/20 px); instance matrix translations are
NOT.** This is the single easiest thing to get wrong, and it was wrong here for
a long time. `<Edge>` coordinates are twips — the tell is the `Backdrop`
symbol, whose outline spans `12801 x 9600`, i.e. exactly 640x480 px. But a
`<DOMSymbolInstance>` `<matrix>`'s `tx`/`ty` are already **pixels**. The basis
(`a b c d`) is unitless as ever.

Dividing the instance translations by 20 collapses every part onto the origin:
the twin tails end up centred on top of the body instead of flanking it, and
the whole figure renders as a head with a curtain of hair.

**Verify geometry against the SWF, not against the FLA.** Both files describe
the same movie. `ffdec -export shape` on the SWF gives one SVG per shape with
exact pixel dimensions, so every part's expected size can be checked directly.

**Shape coordinates come in two encodings.** Legacy `edges="..."` uses absolute
coordinates with `!` moveTo, `|` lineTo and `[` quadratic. CS6 `cubics="..."`
stores one cubic per `<Edge>`: the point after the operator is the segment
start, the three pairs after `(;` are (control1, control2, end), and the
trailing `q`/`Q` chain is a redundant polyline to ignore.

**Numbers may be hex-encoded.** Around 2% of edge attributes use a `#` form
where the integer part is hex and the fraction is two hex digits of 1/256 —
`#FFFFAD.CF` is `65535 + 207/256`. Parsing these as decimal silently produces
plausible-looking but wrong geometry. xfl2svg handles this; it is why the art
is worth taking from a real implementation.

**Skip guide and hidden layers.** `Eyes` carries a guide layer of eyeball
crosshairs that is never drawn but spans roughly +/-876 units.

**XFL frames are sparse, so honour `index` and `duration`.** `Eyes` draws 16
frames across a 45-frame timeline, and each label-layer frame spans 5. Counting
sibling `<DOMFrame>` elements instead of reading their indices gives the wrong
frame for every expression.

**An empty `<elements/>` does not mean empty artwork.** The label layer in both
`Eyes` and `Mouth` carries an `<elements>` element with no children. Testing
for the tag's presence rather than its contents turns the labels into "artwork"
and shifts every phase.

**Flash `Matrix(a b c d tx ty)` has the same field order as Godot's
`Transform2D(xx, xy, yx, yy, origin)`** — x axis `(a, b)`, y axis `(c, d)` — so
instance matrices port across without conversion.

**Every cropped part must put symbol-space `(0, 0)` at its node's origin.**
Otherwise parts sit at the wrong offset from where Flash places them, which
scatters the figure in a way that is hard to attribute. Each expression frame is
cropped independently, so each carries its own origin — an open mouth is not the
same extent as a shut one, and swapping textures means swapping origins too.

**xfl2svg needs `--no-background`.** Otherwise it paints the stage colour
across the whole canvas; once cropped that becomes an opaque box around every
part.

**Pin the frame when rendering a symbol, but not a timeline.** `--first-frame 1`
alone still emits every frame, so `--last-frame 1` is needed too — otherwise
the cropper picks up a blink frame at random. The expression timelines
deliberately do the opposite: render every frame once, then keep the ones the
expression table names.

## Original behaviour worth matching

**Mouse control goes through `atan`, not a straight line.**
`MainTimeline.OnEnterFrame` normalises the pointer against the stage centre and
then bends it:

```as3
var p = new Point((mouseX - W/2)/W, (mouseY - H/2)/H);
p.x = Math.atan(p.x * 4) / Math.PI * 2;
p.y = Math.atan(p.y * 4) / Math.PI * 2;
```

So control tops out at +/-0.705 at the stage edges, not +/-1.0, which caps the
head lean at about 27 degrees instead of 30. A linear `(mouse - centre) * 2` is
wrong in both range and feel. The original also has an exact inverse of this
mapping (`InverseTransformControl`), which the recording cursor needs.

**No key exits the app.** The original quits on nothing; Escape dismisses the
help overlay (`HelpInterface.OnKeyDown`) and every other key is bound to a
feature. Keys bound to unported features should stay inert rather than become
traps.

**Held bindings must return to rest on release.** Blink and the mouth vowels are
held, not toggled — releasing `X` has to reopen the eyes, and releasing a vowel
falls back to the last one still held (`Miku.StackMouth`). Latching either one
would leave the character in a state it can never leave.

**Vowel key bindings are inconsistent in the original.** `Miku_4.UpdateKey`
maps A/S/W/E/D/Q to a/i/u/e/o, while the UI buttons (`UI_Pane_38`) use the kana
row: a/i/u/e/o on A/D/W/S/E. The keyboard handler wins, since that is the path a
keystroke actually takes.

## Verifying

Reference renders come from the SWF, which JPEXS can read:

```sh
java -jar ffdec.jar -export sprite <dir> reference/halfne_miku_studio_by_johnsu_d6k9vnu.swf
# DefineSprite_215_HalfneMiku_fla.Miku_4/1.png is the whole character, 281x263
```

That render is the ground truth to compare against; tight-cropped it is 274x263,
which is what the port also tight-crops to.

**A changed texture is not evidence that anything changed on screen.** Verifying
that an expression swap selected the expected file proves the lookup ran and
nothing more — an expression can be correctly chosen and completely invisible.
Render frames and diff the pixels. That is the only check that would have caught
the buried face, and it is what caught it.

Two headless helpers are useful for eyeballing:

```sh
cd godot
godot --headless --script scripts/svg_sheet.gd   # every part texture, sized
godot --headless --script scripts/dump_rig.gd     # every clip's rest bounds
```

## Still to do

- **Audio** — there is none to port: the SWF has no sound tags and the `.fla`
  no media. The feature is loading a *user-supplied* MP3 and playing it in sync
  with the timeline (`Timeline.mSound`, `mFileRef`), which is the "pretend Miku
  is singing along" case from the author's description. Blocked on the
  transport, though playing a file with no sync at all is trivial in Godot.
- **Mouse recording** — `AxisTrack_46` (100 ms sample grid, interpolated
  playback) plus the ease ramp that lets a recorded path blend back into live
  mouse control. The recorder itself is self-contained; only the transport
  behind it is not.
- **Timeline editor UI** — and with it the real transport, key recording and
  audio sync.
- **Enter** — bound to play/pause in the original; inert here until a transport
  exists.