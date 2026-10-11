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
## The source says 45, but the captures show the rows 43 apart, and 45 would not
## fit two rows of 40 inside the 87-tall pane -- so the measured value is used.
const BAR_SPACING := 43.0
## `ButtonSet.Init`'s default column count. The backdrop set only reaches
## column eight, but the root menu reaches twelve, so the pane is drawn wide
## enough for the widest set the way the original's shared pane is.
const BAR_COLS := 13
## Where the pane sits, measured off the four cropped captures of the original's
## sets, which all agree on 606x107. The stage is 800x600 and the pane sits
## against the bottom of it.
const BAR_LEFT := 94.0
const BAR_BOTTOM := 10.0
## The pane's fixed size, off those captures: 606 wide by 87 tall, with the
## buttons sitting three pixels from its top and bottom edges. All four sets
## measure the same box, so the original's pane does not resize to whichever set
## is up -- it is one size with the sets paging inside it.
const BAR_WIDTH := 606.0
const BAR_HEIGHT := 87.0
## The gap between the pane's border and the buttons in it.
const BAR_PAD := 3.0
## The pane's border width. `custom_minimum_size` is the content box, so the
## drawn box is this much taller and wider than the value set on it.
const BAR_BORDER := 2.0
## A button's own size. The chrome art is 38x38 at its native scale, but the
## original draws it larger than that: measured off the captures, a button
## occupies 42x40 on the grid.
const BAR_BUTTON := Vector2(42, 40)
## How much of the button a shape's artwork fills. The captures show the icons
## and previews sitting slightly proud of a strict fit, so both run a little
## over 1.
const ICON_FILL := 0.74
const PART_FILL := 0.62
## The cursors are scaled 1.5 in the original, which is what makes them read
## larger than the icons beside them.
const CURSOR_FILL := 0.84
## The backdrop thumbnails are the one case that fills its button outright,
## since the `scrollRect` window crops rather than fits.
const THUMB_INSET := 3.0
## The filter `UI_Pane_38.Init` puts on each `mLabel`, in the shader's terms.
const SHADOW_BLUR := 1.1
const SHADOW_ALPHA := 0.5
## The keybind marker's colour and size, read off the captures: a small teal
## character in the button's top-left corner.
const MARKER_COLOR := Color(0.18, 0.55, 0.45)
const MARKER_SIZE := 9
var _icons: Dictionary = {}
var _thumbnails: Array[Button] = []

## The four `ButtonSet`s `UI_Pane_38.Init` builds, by name. Only one is active
## at a time; `ActivateSet` swaps between them and each set's back button
## returns to the root. The original keeps them all as children of one pane and
## fades `presence`, so they share the pane's position and grid.
var _sets: Dictionary = {}
var _active_set := "root"
## Every bound button, as `KeyBind`'s static list. A dictionary per bind, holding
## the button, the key code `ShowKeybind` would print, and what to do on press
## and release.
var _keybinds: Array = []


## The face set's second row, in `UI_Pane_38.Init`'s order. This is *not* the
## order `MOUTH_SETS` walks for the bracket keys -- the original lays the face
## set out as `["happy","neutral","cat","angry","pout","drool","duck","tongue"]`
## while the keyboard cycle is a different sequence, so the two are kept apart.
const MOUTH_MENU := ["happy", "neutral", "cat", "angry", "pout", "drool", "duck", "tongue"]

## The vowel buttons' labels, phases, tooltips and key codes, from `Init`'s
## `vowels` table: `["m", 0, "closed"], ["a", 65, "ah"], ["i", 68, "ee"],
## ["u", 87, "oo"], ["e", 83, "eh"], ["o", 69, "oh"], ["n", 81, "teeth"]` and the
## random button on SPACE. The first is the closed mouth, which is bound to
## nothing, so it shows the blank marker.
const VOWEL_BUTTONS := [
	["m", 0, "closed", 0], ["a", 65, "ah", 65], ["i", 68, "ee", 68],
	["u", 87, "oo", 87], ["e", 83, "eh", 83], ["o", 69, "oh", 69],
	["n", 81, "teeth", 81], ["?", "random", "random", 32],
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

	# The bound buttons get first refusal, as they do in the original: every
	# `KeyBind` on the stage sees the key before anything else does.
	_dispatch_keybinds(event)

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
	# 615 wide by 107 tall, again off the capture.
	_bar = PanelContainer.new()
	_bar.position = Vector2(BAR_LEFT, VIEW.y - BAR_BOTTOM - BAR_HEIGHT)
	_bar.custom_minimum_size = Vector2(
		BAR_WIDTH - BAR_BORDER * 2.0, BAR_HEIGHT - BAR_BORDER * 2.0)
	_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.12, 0.20, 0.96)
	style.set_corner_radius_all(8)
	style.set_border_width_all(BAR_BORDER)
	style.border_color = Color(1, 1, 1)
	style.set_content_margin_all(BAR_PAD)
	_bar.add_theme_stylebox_override("panel", style)
	add_child(_bar)

	var field := Control.new()
	field.custom_minimum_size = Vector2(BAR_COLS * BAR_SPACING,
			BAR_SPACING + BAR_BUTTON.y)
	field.mouse_filter = Control.MOUSE_FILTER_PASS
	# The pane is taller than the two rows of buttons it holds, and the original
	# centres them in it rather than stacking them against its top edge.
	field.position = Vector2(0, BAR_BORDER + BAR_PAD)
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
		# `face_set.AddButton` then `button.BindToKey(49 + i)`, so the eye sets
		# are the digit row.
		var btn := _make_bound_button("eye-" + eye_set, 49 + i)
		_add_part_preview(btn,
			rig.expression_texture(MikuRig.EYES_SYMBOL, eye_set, "open"), PART_FILL)
		var eye_name: String = eye_set
		btn.pressed.connect(func() -> void: rig.set_eye_set(eye_name))
		_bind_key(btn, eye_name, func() -> void: rig.set_eye_set(eye_name))
		_place_button(page, btn, i + 1, 0)
		i += 1

	i = 0
	for mouth_set in MOUTH_MENU:
		# The mouth sets are not bound at all in the original, so they carry the
		# blank `none` marker.
		var btn := _make_bound_button("mouth-" + mouth_set, 0)
		_add_part_preview(btn,
			rig.expression_texture(MikuRig.MOUTH_SYMBOL, mouth_set, "a"), PART_FILL)
		var mouth_name: String = mouth_set
		btn.pressed.connect(func() -> void: rig.set_mouth_set(mouth_name))
		_place_button(page, btn, i + 1, 1)
		i += 1

	# Blink, which the original places at column ten rather than after the rows,
	# and binds to `64 + 24` -- X.
	var blink := _make_bound_button("blink", 64 + 24)
	_add_shadowed_art(blink, _icons.get("UI/Icon", {}).get("blink", ""), ICON_FILL)
	blink.pressed.connect(func() -> void: rig.set_eyes_closed(true))
	_bind_key(blink, "blink", func() -> void: rig.set_eyes_closed(true))
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
		# `Init`'s vowels table carries the key code for each: 0 for the closed
		# mouth, 65 A, 68 D, 87 W, 83 S, 69 E, and SPACE for the random button.
		var key_code: int = entry[3]
		var btn: Button
		if phase == "?":
			# The random button picks a phase outright rather than holding one,
			# so it stays on `pressed` -- there is nothing to release.
			btn = _make_bound_button("mp-?", key_code)
			_add_shadowed_art(btn,
				_icons.get("UI/Icon", {}).get("random", ""), ICON_FILL)
			btn.pressed.connect(func() -> void: rig.set_mouth_phase("?"))
		else:
			btn = _make_bound_button("mp-" + phase, key_code)
			_add_part_preview(btn,
				rig.expression_texture(MikuRig.MOUTH_SYMBOL, "neutral", phase), PART_FILL)
			# A vowel button is a hold, not a click. `Make_VowelButton` passes
			# the key-down state through as `start` and releases on key-up, so the
			# shape is held for as long as the button is down. Firing it on
			# `pressed` instead would push the phase and pop it in the same
			# frame, leaving the mouth exactly as it started.
			btn.button_down.connect(func() -> void: rig.stack_mouth(phase, true))
			btn.button_up.connect(func() -> void: rig.stack_mouth(phase, false))
			_bind_vowel_key(btn, phase)
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
		# The window crops the sides off, which is what `COVERED` does here, and
		# the backdrop fills its button rather than sitting inside it.
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.position = Vector2(THUMB_INSET, THUMB_INSET)
		pic.size = BAR_BUTTON - Vector2(THUMB_INSET, THUMB_INSET) * 2.0
		var mat := ShaderMaterial.new()
		mat.shader = load("res://assets/shaders/drop_shadow.gdshader")
		mat.set_shader_parameter("blur", SHADOW_BLUR)
		mat.set_shader_parameter("alpha", SHADOW_ALPHA)
		pic.material = mat
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
## `Make_EyesButton` scales an `Eyes` to 0.4 and `Make_VowelButton` a `Mouth` to
## 1.5, and hands the result to `Button.Init` as the label -- but those are scales
## of the part as it sits on the full-size head, not of a cropped slice, so they
## do not transfer. What the original's buttons actually show is the shape
## filling most of the chrome, which is what `fill` reproduces: near-full for a
## mouth, slightly less for an eye set, which reads a touch smaller.
func _add_part_preview(btn: Button, texture_path: String, fill: float) -> void:
	_add_shadowed_art(btn, texture_path, fill)


## One of the backdrop set's `Cursors` buttons.
##
## The original scales these 1.5, which is what makes them read a little larger
## than the `Icon` buttons beside them.
func _make_cursor_button(cursor_name: String) -> Control:
	var btn := _make_icon_button("", cursor_name)
	var file: String = _icons.get("UI/Cursors", {}).get(cursor_name, "")
	# `cursor.scaleX = cursor.scaleY = 1.5`, which is what makes these read
	# larger than the `Icon` buttons beside them.
	_add_shadowed_art(btn, file, CURSOR_FILL)
	return btn


## Places a control on the `ButtonSet` grid, in the original's terms.
##
## `ButtonSet.Display` puts a button at `column * presence * SPACING +
## SPACING / 2`, so the cell centre is half a spacing in from the origin and the
## button is centred on it -- hence the -19 that takes a 38-wide button back to
## its own top-left corner.
func _place_button(parent: Control, node: Control, column: int, row: int) -> void:
	node.position = Vector2(
		column * BAR_SPACING + BAR_SPACING * 0.5 - BAR_BUTTON.x * 0.5,
		row * BAR_SPACING + BAR_SPACING * 0.5 - BAR_BUTTON.y * 0.5)
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


## Draws a control's artwork inside it with the original's drop shadow.
##
## `UI_Pane_38.Init` puts a `DropShadowFilter(2, 45, 0, 0.5, 8, 8, 1)` on every
## `mLabel` it builds -- the backdrop thumbnails, the eye sets, the vowel shapes,
## the backdrop transforms -- so the art sits proud of the pane rather than flat
## on it. `Button.icon` cannot take a material, so the art goes in as a child.
##
## `fill` is how much of the button the shape takes. The icons read a little
## larger than the art's own bounds in the captures, so they are drawn past a
## strict fit rather than letterboxed inside it.
func _add_shadowed_art(btn: Button, texture_path: String, fill: float) -> void:
	if texture_path == "":
		return
	var pic := TextureRect.new()
	pic.texture = load(texture_path)
	if pic.texture == null:
		return
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var natural := pic.texture.get_size()
	if natural.x <= 0.0 or natural.y <= 0.0:
		return
	var inset := 5.0
	var room := BAR_BUTTON - Vector2(inset, inset)
	var fit := minf(room.x / natural.x, room.y / natural.y)
	var size := natural * fit * fill
	pic.position = BAR_BUTTON * 0.5 - size * 0.5
	pic.size = size
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/drop_shadow.gdshader")
	mat.set_shader_parameter("blur", SHADOW_BLUR)
	mat.set_shader_parameter("alpha", SHADOW_ALPHA)
	pic.material = mat
	btn.add_child(pic)


## `Button.Init`: a chrome button carrying a keybind and a name.
##
## The original gives every button a `KeyBind`, and `Button.OnRebind` pushes the
## key's name onto the button's marker through `mBind.ShowKeybind`. `key_code`
## is zero for the buttons that are not bound at all -- back, and the custom
## background tools -- and those show the `none` frame, which is blank.
func _make_bound_button(bind_id: String, key_code: int) -> Button:
	var btn := Button.new()
	btn.tooltip_text = bind_id
	_apply_chrome(btn)
	_add_key_marker(btn, key_code)
	return btn


## The marker a bound button carries in its top-left corner.
##
## `keycode_display_57.ShowKeybind` picks one of `keycode_display`'s frames from
## the key's character code and writes that character into a live `TextField`.
## Only `mouse` and the four `Arrow_*` frames hold vector art; the frames the
## lettering appears in are empty in the .fla, so the glyph is a label here --
## which is also what lets a rebind show something different.
func _add_key_marker(btn: Button, key_code: int) -> void:
	var mark := Label.new()
	mark.text = _key_marker_text(key_code)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.add_theme_color_override("font_color", MARKER_COLOR)
	mark.add_theme_font_size_override("font_size", MARKER_SIZE)
	mark.add_theme_constant_override("line_spacing", 0)
	# Top-left, tucked inside the chrome the way `Button.RefreshState` leaves it.
	mark.position = Vector2(4, 2)
	mark.size = Vector2(16, 14)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	mark.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	mark.visible = mark.text != ""
	btn.add_child(mark)
	btn.set_meta("key_code", key_code)


## The character `ShowKeybind` would put in its `TextField`.
##
## Letters and digits go in as themselves; space is named because the key is a
## modifier rather than a character; anything else falls back to the code's
## string, which is what the original's lookup miss does.
func _key_marker_text(key_code: int) -> String:
	if key_code <= 0:
		return ""
	if (key_code >= 65 and key_code <= 90) or (key_code >= 48 and key_code <= 57):
		return String.chr(key_code)
	if key_code == 32:
		return "Space"
	if key_code >= 96 and key_code <= 105:
		return "Num%d" % (key_code - 96)
	if key_code >= 112 and key_code <= 123:
		return "F%d" % (key_code - 111)
	match key_code:
		8: return "Backspace"
		9: return "Tab"
		13: return "Enter"
		16: return "Ctrl"
		27: return "Esc"
		19: return "Pause"
		20: return "Caps"
		33: return "PgUp"
		34: return "PgDn"
		35: return "End"
		36: return "Home"
		37: return "<-"
		38: return "^"
		39: return "->"
		40: return "v"
		45: return "Ins"
		46: return "Del"
		144: return "NumLock"
		145: return "ScrLock"
	return str(key_code)


## Points a bound button at a new key and redraws its marker, which is what
## `KeyBind.Rebind` does when it fires `CHANGE` and `Button.OnRebind` catches.
func _rebind(btn: Button, key_code: int) -> void:
	btn.set_meta("key_code", key_code)
	for child in btn.get_children():
		if child is Label:
			child.text = _key_marker_text(key_code)
			child.visible = child.text != ""


## Registers a bound button so its own key fires it, as `KeyBind.SetListener`
## does for the whole set at once.
##
## The button already has a mouse path wired by its caller; this adds the
## keyboard one. The owning set is found from the button's place in the tree
## rather than from `_active_set`, which is still `root` while the sets are
## being built.
func _bind_key(btn: Button, bind_id: String, action: Callable) -> void:
	_keybinds.append({
		"id": bind_id,
		"button": btn,
		"key": int(btn.get_meta("key_code", 0)),
		"action": action,
	})


## The vowel buttons are held keys, so their keyboard path has to press and
## release like the mouse one rather than firing once.
func _bind_vowel_key(btn: Button, phase: String) -> void:
	_keybinds.append({
		"id": "mp-" + phase,
		"button": btn,
		"key": int(btn.get_meta("key_code", 0)),
		"action": func() -> void: rig.stack_mouth(phase, true),
		"release": func() -> void: rig.stack_mouth(phase, false),
	})


## Feeds a key event to whichever bind owns it, which is what `KeyBind`'s
## `OnKeyDown` and `OnKeyUp` do for every bind on the stage.
##
## A bind on a set that is not showing is skipped: the original's keybinds stay
## live whatever is on screen, but here a hidden set's buttons would swallow keys
## with no visible effect, which is worse than the fidelity.
func _dispatch_keybinds(event: InputEventKey) -> void:
	for bind in _keybinds:
		if int(bind["key"]) != event.keycode:
			continue
		var btn: Button = bind["button"]
		if not is_instance_valid(btn) or not btn.is_visible_in_tree():
			continue
		if event.pressed:
			bind["action"].call()
		elif bind.has("release"):
			bind["release"].call()


## A chrome button wearing the original's chrome.
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
		# Drawn as a child rather than through `Button.icon` so the shadow
		# material can be applied, and so the icon can be sized independently of
		# the button's own layout.
		_add_shadowed_art(btn, file, ICON_FILL)
	return btn


## Gives a button the original's `UI/Button` artwork.
##
## Frame 3 is the only state carrying art in the .fla, and it is clean -- the
## compiled SWF bakes `UI/keycode_display` into it, which is the bound-key
## glyph `Button.OnRebind` draws at runtime rather than part of the chrome. So
## all three states share it, and hover and press are a tint plus the original's
## two-pixel nudge instead of separate artwork.
func _apply_chrome(btn: Button) -> void:
	btn.custom_minimum_size = BAR_BUTTON
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
