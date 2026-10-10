extends Node2D

## Milestone 1 test build: the stage, the character, and mouse control.
##
## Ported so far: the artwork and the rig (clip hierarchy, lean, IK, and the
## Swinger physics). Audio, mouth shapes and blinking are not in yet, so the
## control point is driven by the mouse or by a demo sweep.

@onready var rig: MikuRig = $Miku

## Drive the rig every frame. The rest pose, with this held false, matches a
## composite render of the original XFL, which is what the preview comparison
## needs -- so tools/screenshot.sh passes --rest-pose, and everything else
## (including the exported build) animates.
var _run_rig := true



## Demo sweep, used until the mouse is moved.
const DEMO_MODE := true

const VIEW := Vector2(800, 600)

## The movie's stage, for the backdrop's own transform. The root timeline
## instances the backdrop at 1.25 about a 640x480 design box (Autofit's legacy
## constant), which together give the 800x600 stage.
const BACKDROP_STAGE := Vector2(640, 480)

## The backdrop's extracted art is still geometrically wrong -- `Backdrop` is a
## composite of composites and xfl2svg mis-renders that nesting -- so this
## transform is the authored one from the SWF, but the art inside it does not
## line up. Do not paper over it with a fudge factor; it has to be composed from
## the leaf symbols instead. See PORTING.md.
const BACKDROP_EXTRACTION_SCALE := 1.0

## Horizontal correction for the backdrop, in pixels.
##
## Centring a preset on its alpha bounding box is not the same as centring the
## stage: the concert-stage art carries cable detail down its left edge that
## stretches the box, so the box centre sits well left of the light beams, which
## are the stage's actual axis. Measured against a Ruffle capture, the beams
## land on an axis of 393 there and 338 with the box centred, which left the
## character standing visibly right of the middle of the stage.
const BACKDROP_NUDGE_X := 41.5

## Vertical correction for the backdrop, in pixels. Found by aligning the
## rendered frame against a Ruffle capture of the original over the floor
## region; it is small, about four pixels, and moves the backdrop down so its
## base sits where the original's does.
const BACKDROP_NUDGE_Y := 4.0

## Residual horizontal correction, in pixels. See _set_backdrop.
const BACKDROP_X_NUDGE := 29.0
const GROUND_Y := 470.0

## Where the character stands, in stage coordinates.

var _elapsed := 0.0
var _frame := 0

# Frame capture, used by tools/record.sh to produce the demo video.
var _record := false
var _record_dir := "user://frames"
var _record_frames := 0
var _record_every := 1

# One-shot PNG capture, used by tools/screenshot.sh to produce previews.
var _shot := ""
var _shot_frame := 0

## Backdrop presets, keyed by name, and the sprite showing the current one.
var _backdrops := {}
var _backdrop_names: Array = []
var _backdrop: Sprite2D
var _backdrop_index := 0

## Where the character stands, so each backdrop can be put under her.
var _miku_centre_x := 0.0
var _miku_feet_y := 0.0

## The bottom bar, a stand-in for the original's runtime-built `UI_Pane`.
var _bar: PanelContainer
var _bar_field: Control

## `ButtonSet.SPACING`, the grid pitch the original lays its buttons out on.
const BAR_SPACING := 45.0
## `ButtonSet.Init`'s default column count. The backdrop set only reaches
## column eight, but the root menu reaches twelve, so the pane is drawn wide
## enough for the widest set the way the original's shared pane is.
const BAR_COLS := 13
## Where the pane sits. The original eases it to y 500 in `Update` and shifts
## it in from the left by `presence * 10 - 5`; this is that settled position on
## an 800x600 stage.
const BAR_X := 82.0
const BAR_Y := 76.0
var _icons: Dictionary = {}
var _thumbnails: Array[Button] = []

## The four `ButtonSet`s `UI_Pane_38.Init` builds, by name. Only one is active
## at a time; `ActivateSet` swaps between them and each set's back button
## returns to the root. The original keeps them all as children of one pane and
## fades `presence`, so they share the pane's position and grid.
var _sets: Dictionary = {}
var _active_set := "root"


## The face set's second row, in `UI_Pane_38.Init`'s order. This is *not* the
## order `MOUTH_SETS` walks for the bracket keys -- the original lays the face
## set out as `["happy","neutral","cat","angry","pout","drool","duck","tongue"]`
## while the keyboard cycle is a different sequence, so the two are kept apart.
const MOUTH_MENU := ["happy", "neutral", "cat", "angry", "pout", "drool", "duck", "tongue"]

## The vowel buttons' labels and phases, from `Init`'s `vowels` table. The last
## is the random-phase button, which the original draws as an `Icon` rather than
## a `Mouth` because there is no shape to show for it.
const VOWEL_BUTTONS := [
	["m", "m", "closed"], ["a", "a", "ah"], ["i", "i", "ee"], ["u", "u", "oo"],
	["e", "e", "eh"], ["o", "o", "oh"], ["n", "n", "teeth"], ["?", "random", "random"],
]


func _ready() -> void:
	for args in OS.get_cmdline_user_args():
		var a := String(args)
		if a == "--record":
			_record = true
			_record_frames = 150
		elif a.begins_with("--record-frames="):
			_record_frames = int(a.split("=")[1])
		elif a.begins_with("--shot="):
			_shot = a.split("=")[1]
		elif a == "--rest-pose":
			_run_rig = false

	_build_stage()

	# Stand the character where the original puts her. `Backdrop` carries a
	# guide-layer instance of Miku purely as a placement reference, and that
	# spot is authored in the original's 640x480 stage coordinates -- so scale
	# it to the viewport rather than guessing a ground line.
	await get_tree().process_frame
	var placement: Variant = _placement()
	if placement != null:
		rig.scale = placement["scale"]
		rig.position = placement["pos"]
		# In screen terms: where she stands and where her feet land. The
		# backdrop is placed against these, after she has been positioned.
		var rb: Rect2 = rig.get_rest_bounds()
		_miku_centre_x = rig.position.x + rb.get_center().x * rig.scale.x
		_miku_feet_y = rig.position.y + rb.end.y * rig.scale.y
		print("rig pos=", rig.position, " scale=", rig.scale, " (from root instance)")
		print("miku centre_x=", _miku_centre_x, " feet_y=", _miku_feet_y)
	else:
		# Fall back to centring her by her actual extents.
		var bounds: Rect2 = rig.get_rest_bounds()
		rig.position = Vector2(
			VIEW.x * 0.5 - bounds.get_center().x,
			GROUND_Y - bounds.end.y
		)
		print("rig bounds=", bounds, " position=", rig.position)

	# Now she is placed, the backdrop can go under her.
	_set_backdrop(0)
	_build_bar()


## Where the rig goes on stage: the transform the document's root timeline
## instances it with. The scale is not optional — the FLA's geometry and every
## clip matrix are unscaled, and only the root instance is 1.25.
func _placement() -> Variant:
	var file := FileAccess.open(MikuRig.RIG_PATH, FileAccess.READ)
	if file == null:
		return null
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	var spot = data.get("placement") if typeof(data) == TYPE_DICTIONARY else null
	if spot == null:
		return null
	var stage := Vector2(spot["stage"][0], spot["stage"][1])
	return {
		"pos": Vector2(spot["x"], spot["y"]) * VIEW / stage,
		"scale": Vector2(spot["scale"][0], spot["scale"][1]),
	}


func _build_stage() -> void:
	var sky := ColorRect.new()
	sky.color = Color(0.36, 0.47, 0.66)
	sky.size = VIEW
	sky.z_index = -100
	add_child(sky)

	_backdrops = _load_stage()
	if _backdrops.is_empty():
		return
	# The original picks a backdrop by seeking the Backdrop symbol to a labelled
	# frame; the labels become these presets.
	_backdrop_names = _backdrops.keys()
	_backdrop = Sprite2D.new()
	_backdrop.centered = true
	_backdrop.z_index = -99
	add_child(_backdrop)


## Place a backdrop at its authored size.
##
## `LoadBg` only does `gotoAndStop`, so the presets are drawn 1:1 in the
## symbol's own coordinates — `Autofit` applies to user-loaded images, not to
## these. Scaling to cover instead would zoom each preset by a different amount
## and throw the character off every floor bar one.
func _set_backdrop(index: int) -> void:
	if _backdrop == null or _backdrop_names.is_empty():
		return
	_backdrop_index = posmod(index, _backdrop_names.size())
	var entry: Dictionary = _backdrops[_backdrop_names[_backdrop_index]]
	var tex: Texture2D = load(entry["file"])
	if tex == null:
		push_warning("backdrop preset failed to load: %s" % entry["file"])
		return
	_backdrop.texture = tex
	_backdrop.centered = false
	_backdrop.scale = VIEW / BACKDROP_STAGE * BACKDROP_EXTRACTION_SCALE

	# Put the backdrop's own centre under hers and its floor under her feet,
	# per preset. The symbol origin is no use here: the crop includes the mask
	# rect, which spans x -110..750 and is not centred on the art, and the JPEXS
	# frames carry their own canvas padding. Anchoring on the drawn art instead
	# is what keeps the character standing on each preset's floor, and because
	# JPEXS draws every preset on one canvas the presets also agree with each
	# other.
	var tex_size: Vector2 = tex.get_size()
	if entry.has("origin"):
		# xfl2svg fallback: texel = symbol - origin.
		_backdrop.offset = Vector2(entry["origin"][0], entry["origin"][1]) * _backdrop.scale
	else:
		_backdrop.offset = Vector2.ZERO
	_backdrop.position = Vector2.ZERO
	# The texture is the art (cropped to its own alpha bounds), so the floor is
	# simply its bottom edge. Anchor that under her feet and her centre under
	# its centre.
	_update_thumbnail_highlight()
	_backdrop.offset += Vector2(
		_miku_centre_x - tex_size.x * 0.5 * _backdrop.scale.x + BACKDROP_NUDGE_X,
		_miku_feet_y - tex_size.y * _backdrop.scale.y + BACKDROP_NUDGE_Y
	)


func _cycle_backdrop(step: int) -> void:
	_set_backdrop(_backdrop_index + step)


func _load_stage() -> Dictionary:
	var file := FileAccess.open(MikuRig.RIG_PATH, FileAccess.READ)
	if file == null:
		return {}
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return data.get("stage", {})


## Map a stage position to the rig's control vector, as MainTimeline does.
##
## Flash normalises the pointer against the stage centre and passes it through
## atan, not a plain linear scale:
##
##     p = (mouse - centre) / size
##     control = atan(p * 4) / PI * 2
##
## The curve matters: at the stage edges it reaches +/-0.705 rather than
## +/-1.0, which caps the head lean at about 27 degrees instead of 30, and the
## compression near the centre keeps small movements responsive. A linear map
## both overdrives the lean and feels slack around the middle.
func mouse_control(stage_pos: Vector2, view: Vector2 = VIEW) -> Vector2:
	var p := (stage_pos - view * 0.5) / view
	return Vector2(atan(p.x * 4.0), atan(p.y * 4.0)) * (2.0 / PI)


## The inverse of [method mouse_control]: where a control vector sits on stage.
## The original uses this to draw the recording cursor, and the mouse timeline
## needs it to check a recorded path back into stage space.
func control_to_stage(control: Vector2, view: Vector2 = VIEW) -> Vector2:
	return Vector2(tan(control.x * PI * 0.5) / 4.0, tan(control.y * PI * 0.5) / 4.0) * view + view * 0.5


func _process(delta: float) -> void:
	_elapsed += delta
	_frame += 1

	if DEMO_MODE and not _mouse_moved:
		# Lazy figure-eight sweep so the hair and skirt settle visibly.
		rig.set_control(Vector2(sin(_elapsed * 0.7), cos(_elapsed * 0.41) * 0.55))
	else:
		rig.set_control(mouse_control(get_global_mouse_position(), get_viewport_rect().size))

	if _run_rig:
		rig.update_rig()

	if _record and _frame % _record_every == 0:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute(_record_dir)
		img.save_png("%s/f%04d.png" % [ProjectSettings.globalize_path(_record_dir), _frame])
		if _frame >= _record_frames:
			get_tree().quit()

	# Screenshots are taken once the layout has settled, so the character is in
	# its rest pose rather than mid-sweep.
	if _shot != "":
		_shot_frame += 1
		if _shot_frame == 4:
			await RenderingServer.frame_post_draw
			var shot := get_viewport().get_texture().get_image()
			var dest := ProjectSettings.globalize_path(_shot) if _shot.begins_with("res://") else _shot
			shot.save_png(dest)
			print("wrote ", dest)
			get_tree().quit()


var _mouse_moved := false


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_moved = true


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or event.echo:
		return

	# These two are *held*, so they need the release as much as the press.
	# Gating the whole handler on `event.pressed` (as this used to) meant the
	# release never arrived and the eyes latched shut for good.
	if event.keycode == KEY_X:
		rig.set_eyes_closed(event.pressed)
		get_viewport().set_input_as_handled()
		return
	if VOWEL_KEYS.has(event.keycode):
		rig.stack_mouth(VOWEL_KEYS[event.keycode], event.pressed)
		get_viewport().set_input_as_handled()
		return

	# The rest are momentary.
	if not event.pressed:
		return

	# Only Escape leaves. This used to quit on any key, which is a debugging
	# convenience that turns the exported build into a guessing game -- and it
	# contradicts the original, where no key exits. Escape is Escape's job
	# there too: it dismisses the help overlay (HelpInterface.OnKeyDown).
	if event.keycode == KEY_ESCAPE:
		get_tree().quit()
	elif event.keycode == KEY_SPACE:
		rig.set_mouth_phase("?")
		get_viewport().set_input_as_handled()
	elif event.keycode >= KEY_1 and event.keycode <= KEY_8:
		_cycle_set(EYE_SETS, (event.keycode - KEY_1) % EYE_SETS.size())
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_TAB:
		# The original hides the pane with its own HIDE toggle; Tab is ours.
		_toggle_bar()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_BRACKETLEFT or event.keycode == KEY_BRACKETRIGHT:
		# The mouth has its own, disjoint list of sets, so it gets its own
		# keys rather than sharing the eye row.
		var step := 1 if event.keycode == KEY_BRACKETRIGHT else -1
		_mouth_set_index = posmod(_mouth_set_index + step, MOUTH_SETS.size())
		rig.set_mouth_set(MOUTH_SETS[_mouth_set_index])
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_B and event.pressed:
		# The original cycles backdrops from the UI panel; there is no panel yet.
		_cycle_backdrop(1)
		get_viewport().set_input_as_handled()


## Mouth vowels, as Miku_4.UpdateKey binds them: A/S/W/E/D/Q. Note the UI
## buttons bind these differently (UI_Pane_38 uses the kana row, a/i/u/e/o on
## A/D/W/S/E); the keyboard handler is the one that reads the keyboard.
const VOWEL_KEYS := {
	KEY_A: "a", KEY_S: "i", KEY_W: "u", KEY_E: "e", KEY_D: "o", KEY_Q: "n",
}

## Eyes and Mouth have disjoint expression sets, so they are cycled separately.
const EYE_SETS := ["happy", "jaded", "o_o", "*_*", "@_@", "sideglance", "eheh", "pumped"]
const MOUTH_SETS := ["happy", "neutral", "cat", "angry", "duck", "drool", "tongue", "pout"]

var _mouth_set_index := 0

## Set both faces to a named expression, used by the number keys.
func _cycle_set(sets: Array, index: int) -> void:
	if sets == EYE_SETS:
		rig.set_eye_set(sets[index])
	else:
		rig.set_mouth_set(sets[index])

## The bottom bar.
##
## The original does not contain this as artwork: `UI_Pane` is an empty symbol
## and `UI_Pane_38.Init` builds the whole thing at runtime from `Button`, `Icon`
## and `ButtonSet`, paging between a root menu, face, vowel and backdrop set.
##
## `ButtonSet` lays its buttons out on an absolute grid rather than in
## containers -- `Display` seeks each button to
## `column * presence * SPACING + SPACING / 2`, with `SPACING` 45 and eight
## columns -- and scales the whole set by its animated `presence`. So this
## places children by hand instead of using `HBoxContainer`, which would wrap
## and re-flow where the original never does.
##
## This builds the pane and all four sets. The original keeps them as four
## `ButtonSet` children of one pane and swaps which is active, so they share
## this pane and this grid and differ only in what is on them.
func _build_bar() -> void:
	_load_icons()
	# Sized from the grid rather than the other way round: the original's widest
	# set is thirteen columns, and the pane is drawn around whichever set is up.
	_bar = PanelContainer.new()
	_bar.position = Vector2(BAR_X, VIEW.y - BAR_Y)
	_bar.custom_minimum_size = Vector2(BAR_COLS * BAR_SPACING + 36.0, BAR_SPACING * 2.0 + 16.0)
	_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.12, 0.20, 0.96)
	style.set_corner_radius_all(8)
	style.set_border_width_all(2)
	style.border_color = Color(0.30, 0.80, 0.72)
	style.set_content_margin_all(8)
	_bar.add_theme_stylebox_override("panel", style)
	add_child(_bar)

	var field := Control.new()
	field.custom_minimum_size = Vector2(BAR_COLS * BAR_SPACING, BAR_SPACING * 2.0)
	field.mouse_filter = Control.MOUSE_FILTER_PASS
	_bar.add_child(field)
	_bar_field = field

	for set_name in ["root", "face", "vowel", "backdrop"]:
		var page := Control.new()
		page.mouse_filter = Control.MOUSE_FILTER_PASS
		field.add_child(page)
		_sets[set_name] = page

	_build_root_set()
	_build_face_set()
	_build_vowel_set()
	_build_backdrop_set()
	_activate_set("root")


## The root menu: `Init` puts expressions, lipsyncing and backgrounds across the
## first row, and studio, keybinds and help on the second.
func _build_root_set() -> void:
	var page: Control = _sets["root"]
	# The three that have somewhere to go. The original's other three fire
	# studio, keybind and help events, which have no ported equivalent yet.
	_make_nav_button(page, "face", "expressions", 1, 0, "face")
	_make_nav_button(page, "vowel", "lipsyncing", 2, 0, "vowel")
	_make_nav_button(page, "background", "backgrounds", 3, 0, "backdrop")
	_place_button(page, _make_icon_button("studio", "toggle studio"), 1, 1)
	_place_button(page, _make_icon_button("key", "keybinds"), 11, 1)
	_place_button(page, _make_icon_button("help", "help"), 12, 1)


## A root-menu button that opens another set.
func _make_nav_button(page: Control, icon_name: String, tooltip: String,
		column: int, row: int, target: String) -> void:
	var btn := _make_icon_button(icon_name, tooltip)
	btn.pressed.connect(func() -> void: _activate_set(target))
	_place_button(page, btn, column, row)


## The face set: `MakeBackButton`, then the eight eye sets on row zero, the
## eight mouth sets on row one, and blink at column ten.
##
## Each button's artwork is a miniature `Eyes` or `Mouth` at 0.4 or 1.5, drawn
## from the same slices the rig itself uses rather than a separate icon.
func _build_face_set() -> void:
	var page: Control = _sets["face"]
	_place_button(page, _make_back_button("face"), 0, 0)

	var i := 0
	for eye_set in EYE_SETS:
		var btn := _make_part_button("Eye Set: " + eye_set)
		_add_part_preview(btn,
			rig.expression_texture(MikuRig.EYES_SYMBOL, eye_set, "open"), 0.4)
		var eye_name: String = eye_set
		btn.pressed.connect(func() -> void: rig.set_eye_set(eye_name))
		_place_button(page, btn, i + 1, 0)
		i += 1

	i = 0
	for mouth_set in MOUTH_MENU:
		var btn := _make_part_button("Mouth Shape " + mouth_set)
		_add_part_preview(btn,
			rig.expression_texture(MikuRig.MOUTH_SYMBOL, mouth_set, "a"), 1.5)
		var mouth_name: String = mouth_set
		btn.pressed.connect(func() -> void: rig.set_mouth_set(mouth_name))
		_place_button(page, btn, i + 1, 1)
		i += 1

	# Blink, which the original places at column ten rather than after the rows.
	var blink := _make_icon_button("blink", "blink")
	blink.pressed.connect(func() -> void: rig.set_eyes_closed(true))
	_place_button(page, blink, 10, 0)


## The vowel set: `MakeBackButton` then the eight vowel buttons. Each shows a
## `Mouth` in that shape, except the last, which is the random-phase button and
## uses an `Icon` because there is no single shape to draw for it.
func _build_vowel_set() -> void:
	var page: Control = _sets["vowel"]
	_place_button(page, _make_back_button("vowel"), 0, 0)

	var i := 0
	for entry in VOWEL_BUTTONS:
		var phase: String = entry[0]
		var btn: Button
		if phase == "?":
			btn = _make_icon_button("random", "Random Mouth Shape")
		else:
			btn = _make_part_button("Mouth Shape " + entry[2])
			_add_part_preview(btn,
				rig.expression_texture(MikuRig.MOUTH_SYMBOL, "neutral", phase), 1.5)
		btn.pressed.connect(func() -> void:
			if phase == "?":
				rig.set_mouth_phase("?")
			else:
				rig.stack_mouth(phase, true)
				rig.stack_mouth(phase, false))
		_place_button(page, btn, i + 1, 0)
		i += 1


## The backdrop set: `MakeBackButton`, the eight presets, and the four
## custom-background buttons.
func _build_backdrop_set() -> void:
	var page: Control = _sets["backdrop"]
	_place_button(page, _make_back_button("backdrop"), 0, 0)

	# One thumbnail per preset, at columns one through eight. The original
	# scales each `Backdrop` to 40/640 and windows it through a
	# `scrollRect(70, 0, 500, 480)`, which crops the sides off rather than
	# fitting the whole image; matching that keeps the thumbnails framed the way
	# the original frames them instead of showing more of each backdrop.
	var i := 0
	for preset_name in _backdrop_names:
		var entry: Dictionary = _backdrops[preset_name]
		var tex: Texture2D = load(entry["file"])
		if tex == null:
			continue
		var thumb := Button.new()
		var idx := i
		thumb.tooltip_text = "Background: " + preset_name
		_apply_chrome(thumb)
		thumb.pressed.connect(func() -> void: _set_backdrop(idx))
		var pic := TextureRect.new()
		pic.texture = tex
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.position = Vector2(5, 7)
		pic.size = Vector2(28, 26)
		thumb.add_child(pic)
		_place_button(page, thumb, i + 1, 0)
		_thumbnails.append(thumb)
		i += 1

	# The original's four custom-background buttons, on the second row. `move`
	# and `zoom` are `Cursors` frames scaled 1.5 rather than `Icon` frames --
	# `UI_Pane_38.Init` builds those two from `Cursors` and leaves the rest on
	# `Icon` -- so they are drawn from the other symbol at the original's scale.
	_place_button(page, _make_icon_button("my_pictures", "my_pictures"), 1, 1)
	_place_button(page, _make_cursor_button("move"), 2, 1)
	_place_button(page, _make_cursor_button("zoom"), 3, 1)
	_place_button(page, _make_icon_button("expand", "expand"), 4, 1)

	_update_thumbnail_highlight()


## `MakeBackButton`: every submenu's column-zero button returns to the root.
func _make_back_button(_set_name: String) -> Control:
	var btn := _make_icon_button("back", "back")
	btn.pressed.connect(func() -> void: _activate_set("root"))
	return btn


## `ActivateSet`. The original cross-fades `presence` between sets and hides the
## ones that are out; here the active one is simply shown.
func _activate_set(set_name: String) -> void:
	_active_set = set_name
	for name in _sets:
		_sets[name].visible = name == set_name


## A chrome button with no icon of its own, for the sets whose artwork is a
## miniature `Eyes` or `Mouth` rather than an `Icon` frame. `Make_EyesButton`
## and `Make_VowelButton` build these as a `Button` with the part as its
## `mLabel`, which is what `_add_part_preview` fills in.
func _make_part_button(tooltip: String) -> Button:
	var btn := Button.new()
	btn.tooltip_text = tooltip
	_apply_chrome(btn)
	return btn


## Puts a miniature expression slice inside a chrome button, as the original's
## `mLabel`.
##
## The original scales these before handing them over -- 0.4 for an eye set, 1.5
## for a mouth -- and the slice carries the offsets it had on the head, so both
## are undone here: the scale is applied to the drawn size to get the same
## relative size the original shows, then the result is fitted inside the chrome
## rather than overflowing it. Fitting rather than clipping matters because a
## mouth slice is wider than tall and the button is not square.
func _add_part_preview(btn: Button, texture_path: String, part_scale: float) -> void:
	if texture_path == "":
		return
	var pic := TextureRect.new()
	pic.texture = load(texture_path)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The original draws the part at its natural size times `part_scale`; inside
	# a 38x40 button that only fits if the texture is fitted, so the scale is
	# kept as a weight between the fitted size and the natural size.
	var natural := pic.texture.get_size()
	var fit := minf(28.0 / natural.x, 30.0 / natural.y) if natural.x > 0.0 else 1.0
	var scale := minf(fit * part_scale * 2.0, 1.0)
	pic.position = Vector2(19, 20) - natural * scale * 0.5
	pic.size = natural * scale
	btn.add_child(pic)


## One of the backdrop set's `Cursors` buttons.
##
## The original scales these 1.5, which is what makes them read a little larger
## than the `Icon` buttons beside them.
func _make_cursor_button(cursor_name: String) -> Control:
	var btn := _make_icon_button("", cursor_name)
	var file: String = _icons.get("UI/Cursors", {}).get(cursor_name, "")
	if file != "":
		var tex: Texture2D = load(file)
		var pic := TextureRect.new()
		pic.texture = tex
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# `cursor.scaleX = cursor.scaleY = 1.5`, inset to stay inside the chrome.
		pic.position = Vector2(7, 8)
		pic.size = Vector2(24, 24)
		btn.add_child(pic)
	return btn


## Places a control on the `ButtonSet` grid, in the original's terms.
##
## `ButtonSet.Display` puts a button at `column * presence * SPACING +
## SPACING / 2`, so the cell centre is half a spacing in from the origin and the
## button is centred on it -- hence the -19 that takes a 38-wide button back to
## its own top-left corner.
func _place_button(parent: Control, node: Control, column: int, row: int) -> void:
	node.position = Vector2(
		column * BAR_SPACING + BAR_SPACING * 0.5 - 19.0,
		row * BAR_SPACING + BAR_SPACING * 0.5 - 20.0)
	parent.add_child(node)


func _load_icons() -> void:
	var file := FileAccess.open(MikuRig.RIG_PATH, FileAccess.READ)
	if file == null:
		return
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(data) != TYPE_DICTIONARY:
		return
	var frames = data.get("frames", {})
	for symbol in frames:
		var entry: Dictionary = {}
		for label in frames[symbol]:
			entry[label] = frames[symbol][label]["file"]
		_icons[symbol] = entry


## A button wearing the original's chrome.
##
## `Button.RefreshState` seeks to frame 1 (normal), 2 (hover or down) or 3 (both,
## which also nudges the icon two pixels down), so the three textures are used
## as button-state backgrounds and the icon is a child that shifts on press.
func _make_icon_button(icon_name: String, tooltip: String) -> Control:
	var btn := Button.new()
	btn.tooltip_text = tooltip
	_apply_chrome(btn)
	var file: String = _icons.get("UI/Icon", {}).get(icon_name, "")
	if file != "":
		btn.icon = load(file)
		btn.expand_icon = true
	return btn


## Gives a button the original's `UI/Button` artwork.
##
## Frame 3 is the only state carrying art in the .fla, and it is clean -- the
## compiled SWF bakes `UI/keycode_display` into it, which is the bound-key
## glyph `Button.OnRebind` draws at runtime rather than part of the chrome. So
## all three states share it, and hover and press are a tint plus the original's
## two-pixel nudge instead of separate artwork.
func _apply_chrome(btn: Button) -> void:
	btn.custom_minimum_size = Vector2(38, 40)
	var f: String = _icons.get("UI/Button", {}).get("normal", "")
	if f == "":
		return
	var base := StyleBoxTexture.new()
	base.texture = load(f)
	# Keep the rounded corners crisp and let the middle stretch.
	base.texture_margin_left = 10
	base.texture_margin_right = 10
	base.texture_margin_top = 10
	base.texture_margin_bottom = 10
	base.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	base.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	btn.add_theme_stylebox_override("normal", base)
	btn.add_theme_stylebox_override("focus", base)

	var over := base.duplicate() as StyleBoxTexture
	over.modulate_color = Color(1.25, 1.25, 1.25)
	btn.add_theme_stylebox_override("hover", over)

	var down := base.duplicate() as StyleBoxTexture
	down.modulate_color = Color(0.92, 0.92, 0.92)
	down.content_margin_top = 2
	btn.add_theme_stylebox_override("pressed", down)


## Lights the thumbnail for the backdrop in use.
##
## The original distinguishes it with the button's own keybind state rather than
## a tint -- the selected preset's `Button` holds its key down -- so the chrome
## is what brightens, not the picture inside it.
func _update_thumbnail_highlight() -> void:
	for i in _thumbnails.size():
		var thumb := _thumbnails[i]
		var lit := i == _backdrop_index
		var f: String = _icons.get("UI/Button", {}).get("normal", "")
		if f != "":
			var box := StyleBoxTexture.new()
			box.texture = load(f)
			box.texture_margin_left = 10
			box.texture_margin_right = 10
			box.texture_margin_top = 10
			box.texture_margin_bottom = 10
			box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
			box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
			if lit:
				box.modulate_color = Color(1.25, 1.25, 1.25)
			thumb.add_theme_stylebox_override("normal", box)
			thumb.add_theme_stylebox_override("focus", box)
		for child in thumb.get_children():
			if child is TextureRect:
				child.modulate = Color(1, 1, 1) if lit else Color(0.88, 0.88, 0.92)


func _toggle_bar() -> void:
	if _bar != null:
		_bar.visible = not _bar.visible
