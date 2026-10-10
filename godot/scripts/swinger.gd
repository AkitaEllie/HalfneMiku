class_name Swinger
extends RefCounted

## Damped pendulum used for the hair, skirt, tie and other loose parts.
##
## Port of the `Swinger` helper class from the original Flash source. A point
## ("centre of mass") attached to [member obj] is simulated in the coordinate
## space of [member context]; the resulting swing is written back as the
## object's rotation and vertical scale.

const DAMP := 0.95
const DEFAULT_STRETCHINESS := 0.9

## The swinging display object (a Node2D in the port).
var obj: Node2D
## The space the simulation runs in; in Flash this was the root Miku clip.
var context: Node2D

var _centre := Vector2.ZERO   # centre of mass, in obj local space
var _vel := Vector2.ZERO       # velocity of the centre of mass
var _pos := Vector2.ZERO       # position of the centre of mass, in context space
var _acc := Vector2.ZERO       # constant acceleration
var _damp := DAMP
var _base_ang := 0.0
var _stretchiness := DEFAULT_STRETCHINESS
var _constraint: Array[Vector2] = []
var _has_constraint := false


func _init(p_obj: Node2D, p_space: Node2D, centre: Vector2) -> void:
	obj = p_obj
	context = p_space
	_centre = centre
	_base_ang = centre.angle()
	_pos = _local_to_local(centre, obj, context)


func accelerate(acc: Vector2) -> void:
	_acc = acc


func stretchiness(value: float) -> void:
	_stretchiness = value


## Confine the swing to the wedge between two directions.
func constrain(min_hang: Vector2, max_hang: Vector2) -> void:
	_constraint = [min_hang.normalized(), max_hang.normalized()]
	_has_constraint = true


func update() -> void:
	var new_pos := _pos

	# Gravity expressed in the simulated space, with translation stripped so
	# only the linear part of the context transform matters.
	var loc_mat := _linear_part(obj.get_parent() as Node2D, context)
	var loc_acc: Vector2 = loc_mat * _acc

	_vel += loc_acc
	_vel *= _damp
	new_pos += _vel

	# The part is tethered, so pull it back toward its rest length.
	var loc_pos := _context_to_local(new_pos)
	var max_len := _centre.length()
	var stretch_pct := loc_pos.length() / max_len
	if stretch_pct > 1.0:
		# Undo the stretch caused by this frame's acceleration.
		if loc_acc.length() > 0.0:
			var stretch_dir := loc_pos.normalized()
			var acc_stretch := loc_acc.dot(stretch_dir) * _damp
			if acc_stretch > 0.0:
				new_pos -= stretch_dir * acc_stretch
				loc_pos = _context_to_local(new_pos)
				stretch_pct = loc_pos.length() / max_len

		# Then allow a little elasticity.
		stretch_pct = 1.0 + maxf(0.0, (stretch_pct - 1.0) - 0.1) * _stretchiness
		loc_pos = loc_pos.normalized() * (stretch_pct * max_len)
		new_pos = _local_to_context(loc_pos)

	if _has_constraint:
		loc_pos = _project_into_wedge(loc_pos)
		new_pos = _local_to_context(loc_pos)

	_vel = new_pos - _pos
	_pos = new_pos

	var ang := loc_pos.angle()
	obj.rotation = ang - _base_ang
	obj.scale.y = loc_pos.length() / max_len


## Push a point back inside the wedge formed by the two constraint vectors.
func _project_into_wedge(p: Vector2) -> Vector2:
	var cv := _constraint[0]
	var dot := p.x * cv.y - p.y * cv.x
	if dot < 0.0:
		p += Vector2(-dot * cv.y, dot * cv.x)

	cv = _constraint[1]
	dot = -p.x * cv.y + p.y * cv.x
	if dot < 0.0:
		p += Vector2(dot * cv.y, -dot * cv.x)

	return p


## The rotation/scale part of the transform taking [param from] to
## [param to], with translation removed.
func _linear_part(from: Node2D, to: Node2D) -> Transform2D:
	var m := (from.global_transform as Transform2D).affine_inverse() * (to.global_transform as Transform2D)
	m.origin = Vector2.ZERO
	return m


func _local_to_local(point: Vector2, from: Node2D, to: Node2D) -> Vector2:
	return to.get_global_transform().affine_inverse() * (from.get_global_transform() * point)


func _local_to_context(point: Vector2) -> Vector2:
	return _local_to_local(point + obj.position, obj.get_parent() as Node2D, context)


func _context_to_local(point: Vector2) -> Vector2:
	var p := _local_to_local(point, context, obj.get_parent() as Node2D)
	return p - obj.position