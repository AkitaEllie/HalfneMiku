extends SceneTree

## Renders the generated part SVGs with Godot's own SVG rasterizer and writes a
## contact sheet, so path parsing can be compared against a browser.

func _init() -> void:
	var dir := "res://assets/parts"
	var names: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".svg"):
			names.append(f)
	names.sort()

	var cell := Vector2i(220, 220)
	var cols := 7
	var rows := int(ceil(float(names.size()) / float(cols)))
	var sheet: Image = Image.create_empty(cols * cell.x, rows * cell.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.55, 0.65, 0.8))

	for i in names.size():
		var path: String = dir + "/" + names[i]
		var img: Image = Image.new()
		var err: int = img.load_svg_from_string(FileAccess.get_file_as_string(path), 1.0)
		if err != OK:
			print("FAILED ", path, " err=", err)
			continue
		print("%-34s %dx%d" % [names[i], img.get_width(), img.get_height()])
		img.resize(cell.x - 8, cell.y - 8, Image.INTERPOLATE_LANCZOS)
		var cx: int = (i % cols) * cell.x + 4
		var cy: int = int(i / cols) * cell.y + 4
		sheet.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(cx, cy))

	sheet.save_png("user://svg_sheet.png")
	print("saved sheet")
	quit()