extends SceneTree
## Подложка карты-схемы (tools/map_base.gd) на синтетической сетке: размер
## картинки по прямоугольнику мира (2 м/пиксель), вода синее земли, лес темнее
## поля, ориентация (мировая X -> x картинки, Z -> y, пиксель 0 — минимум X и Z),
## а у запечённой res://game/world/map_base.png — размер по world_index.tres.

const H := preload("res://tests/headless/helper.gd")
const MapBase := preload("res://tools/map_base.gd")
const STEP := 4.0
const X0 := -256.0 ## мир не от нуля: проверяем сдвиг
const Z0 := 0.0
const GW := 65 ## 256 м по X
const GH := 129 ## 512 м по Z: картинка не квадратная


func _initialize() -> void:
	_run()


func _run() -> void:
	# Ровная земля на 2 м, озеро-круг у минимальных X и Z (север-запад),
	# лес полосой у больших X в северной половине.
	var hgt := PackedFloat32Array()
	var forest := PackedFloat32Array()
	var conifer := PackedFloat32Array()
	for z in GH:
		for x in GW:
			var wx := X0 + x * STEP
			var wz := Z0 + z * STEP
			var d := Vector2(wx, wz).distance_to(Vector2(X0 + 60.0, Z0 + 60.0))
			hgt.append(-12.0 if d < 40.0 else 2.0)
			forest.append(1.0 if wx > X0 + 150.0 and wz < Z0 + 200.0 else 0.0)
			conifer.append(1.0 if wz < Z0 + 100.0 else 0.0)
	var grid := {"hgt": hgt, "forest": forest, "conifer": conifer, "w": GW, "h": GH,
		"x0": X0, "z0": Z0, "step": STEP}
	var rect := Rect2(X0, Z0, (GW - 1) * STEP, (GH - 1) * STEP)
	var img := MapBase.render(grid, rect)
	H.check("размер: прямоугольник мира / 2 м", img.get_width() == 128 and img.get_height() == 256,
		"%d × %d" % [img.get_width(), img.get_height()])
	H.check("без mipmap", not img.has_mipmaps())

	var water := _at(img, rect, X0 + 60.0, Z0 + 60.0)
	var field := _at(img, rect, X0 + 60.0, Z0 + 400.0)
	var leafy := _at(img, rect, X0 + 220.0, Z0 + 160.0)
	var pine := _at(img, rect, X0 + 220.0, Z0 + 40.0)
	H.info("вода %s, поле %s, лес %s, хвоя %s" % [water.to_html(false), field.to_html(false),
		leafy.to_html(false), pine.to_html(false)])
	H.check("вода синее земли", water.b - water.r > field.b - field.r + 0.1 and water.b > field.b)
	H.check("лес темнее поля", leafy.get_luminance() < field.get_luminance() - 0.05)
	H.check("хвоя темнее листвы", pine.get_luminance() < leafy.get_luminance())
	# Ориентация: озеро в левом верхнем углу картинки, лес — в правом верхнем.
	H.check("ориентация: вода у минимальных X и Z — слева сверху",
		_is_water(img.get_pixel(30, 30)) and not _is_water(img.get_pixel(30, 200))
		and not _is_water(img.get_pixel(100, 30)))
	H.check("ориентация: лес у больших X и малых Z — справа сверху",
		img.get_pixel(110, 80).get_luminance() < img.get_pixel(110, 180).get_luminance() - 0.05)
	# Кромка: от середины озера к берегу есть пиксель светлее и воды, и поля.
	var rim := water
	for d in range(0, 46, 2):
		var c := _at(img, rect, X0 + 60.0 + d, Z0 + 60.0)
		if c.get_luminance() > rim.get_luminance():
			rim = c
	H.check("светлая кромка берега", rim.get_luminance() > field.get_luminance() + 0.05,
		rim.to_html(false))
	# Отмывка: склон к северо-западу светлее склона к юго-востоку.
	var slope := PackedFloat32Array()
	for z in GH:
		for x in GW:
			slope.append(20.0 - absf(x - 32) * 0.8)
	grid["hgt"] = slope
	grid["forest"] = _zeros()
	grid["conifer"] = _zeros()
	var hill := MapBase.render(grid, rect)
	H.check("отмывка: склон к западу светлее склона к востоку",
		hill.get_pixel(32, 128).get_luminance() > hill.get_pixel(96, 128).get_luminance() + 0.03)

	# Запечённая подложка — по прямоугольнику мира из сводки.
	var index: WorldIndex = load("res://game/world/world_index.tres")
	var world := WorldDefs.rect_of_chunks(index.chunk_coords)
	var baked := Image.load_from_file(ProjectSettings.globalize_path(MapBase.PATH))
	H.check("запечённая подложка по прямоугольнику мира", baked != null
		and baked.get_size() == Vector2i(world.size / MapBase.M_PER_PX),
		"%s, мир %s" % [baked.get_size() if baked else "нет файла", world])
	H.finish(self)


func _at(img: Image, rect: Rect2, wx: float, wz: float) -> Color:
	return img.get_pixel(int((wx - rect.position.x) / MapBase.M_PER_PX), int((wz - rect.position.y) / MapBase.M_PER_PX))


func _is_water(c: Color) -> bool:
	return c.b > c.g and c.b > c.r


func _zeros() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	return a
