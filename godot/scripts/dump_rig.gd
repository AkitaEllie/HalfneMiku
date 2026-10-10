extends SceneTree

## Headless diagnostics: prints the rest-pose extent of every rig clip so the
## layout can be compared against the original Flash stage.

func _init() -> void:
	var scene: PackedScene = load("res://scenes/miku.tscn")
	var rig: Node2D = scene.instantiate()
	root.add_child(rig)

	await process_frame

	var rig_rect := Rect2()
	var first := true
	for path in rig.clips.keys():
		var node: Node2D = rig.clips[path]
		var r: Rect2 = node.get_global_transform() * _children_rect(node)
		if first:
			rig_rect = r
			first = false
		else:
			rig_rect = rig_rect.merge(r)
		print("%-18s x[%8.1f %8.1f] y[%8.1f %8.1f]  %7.1f x %7.1f" % [
			path, r.position.x, r.end.x, r.position.y, r.end.y, r.size.x, r.size.y])

	print("\nWHOLE RIG: pos=(%.1f, %.1f) size=%.1f x %.1f" % [
		rig_rect.position.x, rig_rect.position.y, rig_rect.size.x, rig_rect.size.y])
	print("centre=(%.1f, %.1f)" % [rig_rect.get_center().x, rig_rect.get_center().y])
	quit()


## Bounds of a clip's own sprite, if it has one.
func _children_rect(node: Node2D) -> Rect2:
	for child in node.get_children():
		if child is Sprite2D and child.texture:
			var s: Sprite2D = child
			var sz := s.texture.get_size()
			return Rect2(s.offset, sz)
	return Rect2(Vector2.ZERO, Vector2.ZERO)