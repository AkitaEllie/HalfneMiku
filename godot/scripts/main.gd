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
		rig.position = placement
		print("rig position=", rig.position, " (from guide reference)")
	else:
		# Fall back to centring her by her actual extents.
		var bounds: Rect2 = rig.get_rest_bounds()
		rig.position = Vector2(
			VIEW.x * 0.5 - bounds.get_center().x,
			GROUND_Y - bounds.end.y
		)
		print("rig bounds=", bounds, " position=", rig.position)


## Where the rig's origin belongs on screen, from the guide-layer reference.
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
	return Vector2(spot["x"], spot["y"]) * VIEW / stage


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
	_cycle_backdrop(0)


## Fit a backdrop over the stage and centre it, the way `Backdrop.Autofit`
## does: scale by max(stage/image) on each axis so it covers rather than
## contains, then centre the overflow.
func _set_backdrop(index: int) -> void:
	if _backdrop == null or _backdrop_names.is_empty():
		return
	_backdrop_index = posmod(index, _backdrop_names.size())
	var entry: Dictionary = _backdrops[_backdrop_names[_backdrop_index]]
	_backdrop.texture = load(entry["file"])
	var size := Vector2(entry["size"][0], entry["size"][1])
	_backdrop.scale = Vector2.ONE * maxf(VIEW.x / size.x, VIEW.y / size.y)
	_backdrop.position = VIEW * 0.5


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