@tool
class_name MikuRig
extends Node2D

## The Miku character rig: builds the clip hierarchy from the extracted XFL
## data and drives it, ported from the `Miku` symbol's ActionScript.
##
## The clip tree is built from `rig.json` at runtime rather than authored into
## the scene file, so without `@tool` the editor shows an empty `Node2D` where
## the character should be. Everything in here is deterministic setup, so it is
## safe to run in the editor; the animation itself is driven from `main.gd`'s
## `_process`, which does not run there.
##
## Flash called every articulated piece a MovieClip and stored its rest
## transform in `_initForm`. Here each clip is a Node2D whose basis is derived
## from that rest transform; only the origin is rewritten each frame unless a
## clip is rotated or stretched by [method _touch_clip_to].

const RIG_PATH := "res://data/rig.json"

## Clip path -> node, e.g. "head.bangs.L".
var clips := {}
## Rest transform of each clip, mirroring Flash's `_initForm`.
var _init_form := {}
var _swingers := {}

var _control := Vector2.ZERO

## The parsed rig.json, kept so the expression tables outlive _build().
var _rig_data := {}

## The two frame-based expression timelines, ported from `Mouth` and `Eyes`:
## symbol name -> set -> phase -> { texture, origin }.
var _expressions := {}

## The sprite each expression timeline draws into.
var _eye_sprite: Sprite2D
var _mouth_sprite: Sprite2D

## Current expression state, mirroring Mouth.mSet / Eyes.mSet and mPhase.
var _eye_set := "happy"
var _eye_closed := false
var _mouth_set := "happy"
var _mouth_phase := "m"

## Mouth phases held down at once, so releasing one falls back to the next
## still-held vowel rather than to closed. Ported from Miku.StackMouth.
var _mouth_stack: Array[String] = []

const EYES_CLIP := "head.face.eyes"
const MOUTH_CLIP := "head.face.mouth"
const EYES_SYMBOL := "Miku parts/Eyes"
const MOUTH_SYMBOL := "Miku parts/Mouth"


## Apply an expression timeline's (set, phase) to its sprite.
##
## Every frame of these timelines is cropped independently, so each one carries
## its own origin -- swapping a mouth shape means swapping both the texture and
## the offset that keeps it on the symbol's origin.
func _apply_expression(sprite: Sprite2D, symbol: String, set_name: String,
		phase: String) -> bool:
	if sprite == null:
		return false
	var table: Dictionary = _expressions.get(symbol, {})
	var phases: Dictionary = table.get(set_name, {})
	var entry: Dictionary = phases.get(phase, {})
	if entry.is_empty():
		return false
	sprite.texture = load(entry["texture"])
	sprite.offset = Vector2(entry["origin"][0], entry["origin"][1])
	return true


## The texture path for one expression slice, e.g. an eye set's open frame or a
## mouth set's "a" phase. The UI's face and vowel buttons draw themselves from
## these rather than from separate artwork, because the original draws them from
## `Eyes` and `Mouth` instances too. Empty when the set or phase is unknown.
func expression_texture(symbol: String, set_name: String, phase: String) -> String:
	var entry: Dictionary = _expressions.get(symbol, {}).get(set_name, {}) \
		.get(phase, {})
	return entry.get("texture", "")


## Switch the eye expression set, e.g. "happy" or "jaded" (Eyes.ChangeSet).
func set_eye_set(set_name: String) -> void:
	if not _expressions.get(EYES_SYMBOL, {}).has(set_name):
		push_warning("unknown eye set: %s" % set_name)
		return
	_eye_set = set_name
	_refresh_eyes()


## Open or shut the eyes (Eyes.Blink).
func set_eyes_closed(closed: bool) -> void:
	_eye_closed = closed
	_refresh_eyes()


func _refresh_eyes() -> void:
	_apply_expression(_eye_sprite, EYES_SYMBOL, _eye_set,
		"closed" if _eye_closed else "open")


## Switch the mouth expression set, e.g. "happy" or "angry"
## (Mouth.ChangeSet).
func set_mouth_set(set_name: String) -> void:
	if not _expressions.get(MOUTH_SYMBOL, {}).has(set_name):
		push_warning("unknown mouth set: %s" % set_name)
		return
	_mouth_set = set_name
	_refresh_mouth()


## Set the vowel shape directly (Mouth.ChangePhase). "?" picks a random vowel,
## as the original does.
func set_mouth_phase(phase: String) -> void:
	if phase == "?":
		const VOWELS := ["a", "i", "u", "e", "o"]
		phase = VOWELS[randi() % VOWELS.size()]
	_mouth_phase = phase
	_refresh_mouth()


func _refresh_mouth() -> void:
	_apply_expression(_mouth_sprite, MOUTH_SYMBOL, _mouth_set, _mouth_phase)


## Hold or release a vowel, stacking held vowels (Miku.StackMouth).
##
## Holding "m" clears the stack, which is how the original returns to a closed
## mouth; releasing a vowel falls back to the last one still held.
func stack_mouth(phase: String, down: bool) -> void:
	if down:
		if phase == "m":
			_mouth_stack.clear()
		_mouth_stack.append(phase)
		set_mouth_phase(phase)
		return
	var i := _mouth_stack.find(phase)
	if i != -1:
		_mouth_stack.remove_at(i)
	set_mouth_phase(_mouth_stack[-1] if _mouth_stack.size() > 0 else "m")


## Rest-pose bounds of every sprite in the rig, in this node's local space.
## Used to place the character on the stage without hardcoded offsets.
func get_rest_bounds() -> Rect2:
	var rect := Rect2()
	var first := true
	for path in clips:
		var node: Node2D = clips[path]
		for child in node.get_children():
			if not (child is Sprite2D) or child.texture == null:
				continue
			var local: Rect2 = Rect2(child.offset, child.texture.get_size())
			var r: Rect2 = (node.transform * local) if first else (node.transform * local)
			if first:
				rect = r
				first = false
			else:
				rect = rect.merge(r)
	return rect


func _ready() -> void:
	_build()
	_init_clip_roots()
	_setup_swingers()
	_setup_expressions()


## Load the expression timelines and put the character in the state the
## original initialises to: Eyes.Init sets "happy" then blinks open, and
## Mouth.Init sets "happy" with phase "m" (Mikuh.mMouthStack starts empty).
func _setup_expressions() -> void:
	_expressions = _rig_data.get("expressions", {})
	_eye_sprite = _art_of(EYES_CLIP)
	_mouth_sprite = _art_of(MOUTH_CLIP)
	_eye_set = "happy"
	_eye_closed = false
	_mouth_set = "happy"
	_mouth_phase = "m"
	_mouth_stack.clear()
	_refresh_eyes()
	_refresh_mouth()


func _art_of(path: String) -> Sprite2D:
	var node: Node2D = clips.get(path)
	if node == null:
		push_error("no clip at %s" % path)
		return null
	for child in node.get_children():
		if child is Sprite2D:
			return child
	return null


## Parent/child attachment points, straight from the original Miku.Init.
func _init_clip_roots() -> void:
	_init_clip_root("leg_L", "lower")
	_init_clip_root("leg_R", "lower")
	_init_clip_root("neck", "collar")
	_init_clip_root("collar", "upper")
	_init_clip_root("tail_L", "head")
	_init_clip_root("tail_R", "head")
	_init_clip_root("shoulder_L", "upper")
	_init_clip_root("shoulder_R", "upper")
	_init_clip_root("clipBR", "head")


## Rebuild the clip tree from the manifest, mirroring the original display list.
func _build() -> void:
	# The editor can re-run `_ready` on a scene reload, so clear anything a
	# previous run left behind. Without this the clips would double up.
	for child in get_children():
		remove_child(child)
		child.queue_free()
	clips.clear()
	var file := FileAccess.open(RIG_PATH, FileAccess.READ)
	if file == null:
		push_error("cannot open %s" % RIG_PATH)
		return
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	# Kept for the expression setup, which runs after the clip tree is built.
	_rig_data = data

	# Artwork lookup, keyed by symbol name. A symbol can contribute more than
	# one texture: Flash interleaves a composite's own shapes among its child
	# clips, so each slice records the `slot` it belongs in.
	var slices_by_name := {}
	for part in data["parts"]:
		var slice := {
			"texture": load("res://assets/parts/%s.svg" % part["id"]),
			# Where the part's local origin (0,0) sits inside the cropped texture.
			"origin": Vector2(part["origin"][0], part["origin"][1]),
			"slot": int(part["slot"]) if "slot" in part else -1,
		}
		if not slices_by_name.has(part["name"]):
			slices_by_name[part["name"]] = []
		slices_by_name[part["name"]].append(slice)

	# Artwork cannot be attached yet: a slice belongs *between* two child clips,
	# and the clips are still being added. Collect them and weave afterwards.
	var pending_art := {}

	# rig.json is already ordered parents-before-children by depth.
	for entry in data["rig"]:
		var node := Node2D.new()
		node.name = entry["name"]
		var path: String = entry["path"]
		var depth: int = entry["depth"]

		if depth == 0:
			add_child(node)
		else:
			var parent_path := path.rsplit(".", true, 1)[0]
			clips[parent_path].add_child(node)
		clips[path] = node

		var m: Array = entry["matrix"]
		var tp := Vector2(entry["tp"][0], entry["tp"][1])
		# Flash Matrix(a b c d tx ty) has the same field order as Godot's
		# Transform2D(xx, xy, yx, yy, origin): x axis is (a, b), y axis (c, d).
		var xform := Transform2D(
			Vector2(m[0], m[1]), Vector2(m[2], m[3]), Vector2(m[4], m[5])
		) * Transform2D(0.0, -tp)
		node.transform = xform
		_init_form[path] = xform

		for slice in slices_by_name.get(entry["symbol"], []):
			var sprite := Sprite2D.new()
			var slot: int = slice["slot"]
			sprite.name = "Art" if slot < 0 else "Art%+d" % slot
			sprite.texture = slice["texture"]
			# The texture is cropped to the part's bounds, so its pixel (0,0) is
			# the symbol-space point (origin). With centred off, a texture pixel
			# is drawn at `offset`, hence offset = origin puts the part's own
			# local origin back on the node origin.
			sprite.centered = false
			sprite.offset = slice["origin"]
			if not pending_art.has(path):
				pending_art[path] = []
			pending_art[path].append([slot, sprite])

	_weave_art(pending_art)


## Attach each clip's artwork at the slot Flash painted it in.
##
## Slot -1 is in front of no clip, slot 0 sits after the first child clip, and
## so on. The clip children are already in Flash's paint order, so interleaving
## by slot reproduces the original display list.
func _weave_art(pending_art: Dictionary) -> void:
	for path in pending_art:
		var node: Node2D = clips[path]
		var clips_here: Array = node.get_children()
		var art_by_slot := {}
		for entry in pending_art[path]:
			art_by_slot[entry[0]] = entry[1]

		var ordered := []
		for slot in range(-1, clips_here.size()):
			if art_by_slot.has(slot):
				ordered.append(art_by_slot[slot])
			if slot + 1 < clips_here.size():
				ordered.append(clips_here[slot + 1])
		# Slices past the last clip cannot be interleaved; they belong on top.
		for slot in art_by_slot:
			if slot >= clips_here.size():
				ordered.append(art_by_slot[slot])

		# The clip nodes are already children; the art sprites are not yet.
		for child in clips_here:
			node.remove_child(child)
		for child in ordered:
			node.add_child(child)


func _setup_swingers() -> void:
	var grav := Vector2(0, 5)
	_swingers["tail_L"] = _make_swinger("tail_L", Vector2(0, 128), grav)
	_swingers["tail_R"] = _make_swinger("tail_R", Vector2(0, 128), grav)

	# Bangs swing more freely than the tails.
	grav.y = 64
	_swingers["head.bangs.L"] = _make_swinger("head.bangs.L", Vector2(0, 128), grav)
	_swingers["head.bangs.L"].constrain(Vector2(-1, 8), Vector2(1, 8))
	_swingers["head.bangs.M"] = _make_swinger("head.bangs.M", Vector2(0, 100), grav)
	_swingers["head.bangs.R"] = _make_swinger("head.bangs.R", Vector2(0, 128), grav)
	_swingers["head.bangs.R"].constrain(Vector2(-1, 8), Vector2(1, 8))

	var momi_l := _make_swinger("head.momi_L", Vector2(0, 64), Vector2(0.5, 8))
	momi_l.stretchiness(0.5)
	var momi_r := _make_swinger("head.momi_R", Vector2(0, 64), Vector2(-1, 8))
	momi_r.stretchiness(0.5)

	_swingers["collar.tie"] = _make_swinger("collar.tie", Vector2(0, 32), Vector2(0, 2))
	var skirt := _make_swinger("lower.skirt", Vector2(0, 20), Vector2(0, 2))
	skirt.constrain(Vector2(-1, 7), Vector2(1, 7))

	var ahoge := _make_swinger("head.ahoge", Vector2(0, -32), Vector2(-12, -12))
	ahoge.stretchiness(0.0)

	_swingers["upper.shirt_L"] = _make_swinger("upper.shirt_L", Vector2(0, 16), Vector2(-2, 4))
	_swingers["upper.shirt_R"] = _make_swinger("upper.shirt_R", Vector2(0, 16), Vector2(2, 4))

	var belt := _make_swinger("lower.belt", Vector2(0, 8), Vector2(1, 4))
	belt.stretchiness(0.0)


func _make_swinger(path: String, centre: Vector2, acc: Vector2) -> Swinger:
	var sw := Swinger.new(clips[path], self, centre)
	sw.accelerate(acc)
	return sw


## Control input, both axes in the range -1..1. -1 on x is "left".
func set_control(control: Vector2) -> void:
	_control = control


func update_rig() -> void:
	var right := _control.x
	var fwd := _control.y

	var side_ang := right * PI / 2.0
	var fwd_ang := fwd * PI / 2.0
	var side_sin := sin(side_ang)
	var side_cos := cos(side_ang)
	var fwd_sin := sin(fwd_ang)
	var lean := 1.0 - (0.5 - fwd_sin * 0.5) * side_cos

	# Head
	var head: Node2D = clips["head"]
	var m0: Transform2D = _init_form["head"]
	_set_origin(head, m0.origin + Vector2(side_sin * 4, 10 * lean))
	head.rotation = deg_to_rad(side_sin * 30.0)

	# Upper body
	var upper: Node2D = clips["upper"]
	m0 = _init_form["upper"]
	_set_origin(upper, m0.origin + Vector2(side_sin * 5, 4 * lean))
	upper.rotation = deg_to_rad(-side_sin * 15.0)

	# Lower body
	var lower: Node2D = clips["lower"]
	m0 = _init_form["lower"]
	_set_origin(lower, m0.origin + Vector2(side_sin * 10, 4 * lean))

	_maintain_clip_root(clips["collar"])

	# Neck follows the head.
	m0 = _init_form["neck"]
	_maintain_clip_root(clips["neck"])
	_touch_clip_to(clips["neck"], Vector2(0, -10), Vector2(head.position.x, head.position.y))

	# Arms
	var arm_l: Node2D = clips["arm_L"]
	m0 = _init_form["arm_L"]
	_set_origin(arm_l, m0.origin + Vector2((sin(side_ang - 0.5) + 0.75) * 5, -(0 - side_cos) * 10))

	var arm_r: Node2D = clips["arm_R"]
	m0 = _init_form["arm_R"]
	_set_origin(arm_r, m0.origin + Vector2((sin(side_ang + 0.5) - 0.75) * 5, -(0 - side_cos) * 10))

	# Shoulders reach up to the arms.
	_maintain_clip_root(clips["shoulder_L"])
	_touch_clip_to(clips["shoulder_L"], Vector2(0, 24), Vector2(arm_l.position.x, arm_l.position.y))
	_maintain_clip_root(clips["shoulder_R"])
	_touch_clip_to(clips["shoulder_R"], Vector2(0, 24), Vector2(arm_r.position.x, arm_r.position.y))

	# Legs stay pinned at the foot.
	var foot_pos := Vector2(0, 40)
	m0 = _init_form["leg_L"]
	_maintain_clip_root(clips["leg_L"])
	_touch_clip_to(clips["leg_L"], foot_pos, m0 * foot_pos)
	m0 = _init_form["leg_R"]
	_maintain_clip_root(clips["leg_R"])
	_touch_clip_to(clips["leg_R"], foot_pos, m0 * foot_pos)

	_maintain_clip_root(clips["tail_L"])
	_maintain_clip_root(clips["tail_R"])
	_maintain_clip_root(clips["clipBR"])
	clips["clipBR"].rotation = head.rotation

	for swinger in _swingers.values():
		swinger.update()


## Rewrite only the clip's origin, preserving its rotation and scale.
func _set_origin(node: Node2D, origin: Vector2) -> void:
	var t := node.transform
	t.origin = origin
	node.transform = t


## Keep a clip anchored to the same point on its root object, even when that
## root object has moved. Mirrors Flash's initClipRoot/maintainClipRoot pair.
func _maintain_clip_root(node: Node2D) -> void:
	var key := node.get_instance_id()
	if not _root_points.has(key):
		return
	var root_obj: Node2D = clips[_root_paths[key]]
	var pos: Vector2 = root_obj.to_global(_root_points[key])
	pos = node.get_parent().to_local(pos)
	_set_origin(node, pos)


var _root_paths := {}
var _root_points := {}


## Record that [param path] hangs off the origin of [param root_path].
## Must be called while every clip is still in its rest pose.
func _init_clip_root(path: String, root_path: String) -> void:
	var node: Node2D = clips[path]
	var root_obj: Node2D = clips[root_path]
	_root_points[node.get_instance_id()] = root_obj.to_local(node.to_global(Vector2.ZERO))
	_root_paths[node.get_instance_id()] = root_path


## Rotate and stretch a clip so its local tip lands on a destination point given
## in the clip's parent's space.
func _touch_clip_to(node: Node2D, local_tip: Vector2, dest: Vector2) -> void:
	var dp: Vector2 = node.to_local(node.get_parent().to_global(dest))
	node.rotation += dp.angle() - local_tip.angle()
	node.scale.y *= dp.length() / local_tip.length()