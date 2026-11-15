extends RefCounted
## Подложка карты-схемы: картинка res://game/world/map_base.png, её пишет
## запекание (tools/bake_world.gd) по сетке рельефа после продавливания дорог
## и маскам forest / conifer. Формат — «Договор задачи 6» в
## docs/vertical-slice.md, описание — docs/map-pipeline.md, тест — test_map_base.
##
## M_PER_PX метров на пиксель, прямоугольник мира rect (WorldDefs.rect_of_chunks):
## пиксель (0, 0) — минимальные X и Z, ось x картинки = мировая X, ось y =
## мировая Z (север, −Z, сверху). Слои:
##   - земля: от LAND_LOW к LAND_HIGH по высоте, мягкая отмывка рельефа светом
##     с северо-запада (по нормали сглаженных высот, без резкости);
##   - лес и хвоя: темнее земли, по сглаженным маскам (conifer — доля хвои в лесу);
##   - вода: ниже WorldDefs.WATER_LEVEL, глубже — темнее, по краю тонкая светлая
##     кромка берега.
## Дорог и построек на подложке нет: их рисует экран карты.

const M_PER_PX := 2.0
const PATH := "res://game/world/map_base.png"

# Цвета приглушённые: поверх читаются дороги и значки, в том числе при
# затемнённом фоне меню. Тон — из палитры лета (docs/visual-style.md).
const LAND_LOW := Color(0.47, 0.53, 0.36) ## поле у воды (приглушённое #738F3D)
const LAND_HIGH := Color(0.62, 0.64, 0.49) ## холмы, светлее
const FOREST := Color(0.33, 0.42, 0.27) ## лиственный лес (приглушённое #3D5E26)
const CONIFER := Color(0.25, 0.34, 0.25) ## хвоя, темнее и холоднее
const WATER := Color(0.38, 0.52, 0.60)
const WATER_DEEP := Color(0.29, 0.43, 0.53)
const SHORE := Color(0.70, 0.75, 0.70) ## светлая кромка берега

const LAND_SPAN_M := 40.0 ## перепад высот от воды, на котором земля светлеет до LAND_HIGH
const WATER_DEEP_M := 6.0 ## глубина, на которой вода темнеет до WATER_DEEP
const SHADE_STRENGTH := 0.45 ## сила отмывки рельефа
const SHADE_Z := 2.0 ## преувеличение высот для отмывки
const SMOOTH_NODES := 2 ## радиус сглаживания высот и масок, узлов сетки
const FOREST_FROM := 0.2 ## маска леса: от этого значения лес начинает проступать...
const FOREST_TO := 0.6 ## ...и к этому виден полностью
const FOREST_STRENGTH := 0.85 ## насколько лес закрывает цвет земли


## Картинка подложки. grid — сетка запекания: {hgt, forest, conifer:
## PackedFloat32Array, w, h: int (узлов по X и Z), x0, z0: float (мировые
## координаты узла 0), step: float (м между узлами)}. rect — прямоугольник мира XZ.
static func render(grid: Dictionary, rect: Rect2) -> Image:
	var gw: int = grid["w"]
	var gh: int = grid["h"]
	var hgt: PackedFloat32Array = grid["hgt"]
	var x0: float = grid["x0"]
	var z0: float = grid["z0"]
	var step: float = grid["step"]
	var forest := _blur(grid["forest"], gw, gh, SMOOTH_NODES)
	var conifer := _blur(grid["conifer"], gw, gh, SMOOTH_NODES)
	var shade := _shade(_blur(hgt, gw, gh, SMOOTH_NODES), gw, gh, step)
	var iw := maxi(1, roundi(rect.size.x / M_PER_PX))
	var ih := maxi(1, roundi(rect.size.y / M_PER_PX))
	var water_level := WorldDefs.WATER_LEVEL
	var img := Image.create(iw, ih, false, Image.FORMAT_RGB8)
	var wet := PackedByteArray()
	wet.resize(iw * ih)
	for py in ih:
		for px in iw:
			# Центр пикселя в мире -> дробный узел сетки.
			var fx := (rect.position.x + (px + 0.5) * M_PER_PX - x0) / step
			var fz := (rect.position.y + (py + 0.5) * M_PER_PX - z0) / step
			var h := _bilinear(hgt, gw, gh, fx, fz)
			var col: Color
			if h < water_level:
				wet[py * iw + px] = 1
				col = WATER.lerp(WATER_DEEP, clampf((water_level - h) / WATER_DEEP_M, 0.0, 1.0))
			else:
				col = LAND_LOW.lerp(LAND_HIGH, smoothstep(0.0, LAND_SPAN_M, h - water_level))
				var f := smoothstep(FOREST_FROM, FOREST_TO, _bilinear(forest, gw, gh, fx, fz))
				var trees := FOREST.lerp(CONIFER, clampf(_bilinear(conifer, gw, gh, fx, fz), 0.0, 1.0))
				col = col.lerp(trees, f * FOREST_STRENGTH)
				var s := 1.0 + SHADE_STRENGTH * _bilinear(shade, gw, gh, fx, fz)
				col = Color(col.r * s, col.g * s, col.b * s)
			img.set_pixel(px, py, col)
	_shore(img, wet)
	return img


## Светлая кромка: пиксели воды, у которых рядом (3 × 3) есть суша.
static func _shore(img: Image, wet: PackedByteArray) -> void:
	var iw := img.get_width()
	var ih := img.get_height()
	for py in ih:
		for px in iw:
			if wet[py * iw + px] == 0:
				continue
			var dry := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var qx := clampi(px + dx, 0, iw - 1)
					var qy := clampi(py + dy, 0, ih - 1)
					dry += 1 - wet[qy * iw + qx]
			if dry > 0:
				img.set_pixel(px, py, img.get_pixel(px, py).lerp(SHORE, minf(1.0, 0.35 + dry * 0.12)))


## Отмывка в узлах сетки: освещённость склона светом с северо-запада минус
## освещённость ровного места (ровное = 0, к свету > 0, от света < 0).
static func _shade(hgt: PackedFloat32Array, gw: int, gh: int, step: float) -> PackedFloat32Array:
	var light := Vector3(-1.0, 1.4, -1.0).normalized() # на северо-запад (−X, −Z) и вверх
	var flat := light.y
	var out := PackedFloat32Array()
	out.resize(gw * gh)
	for z in gh:
		for x in gw:
			var dx := hgt[z * gw + mini(x + 1, gw - 1)] - hgt[z * gw + maxi(x - 1, 0)]
			var dz := hgt[mini(z + 1, gh - 1) * gw + x] - hgt[maxi(z - 1, 0) * gw + x]
			var n := Vector3(-dx * SHADE_Z, 2.0 * step, -dz * SHADE_Z).normalized()
			out[z * gw + x] = n.dot(light) - flat
	return out


## Сглаживание сетки квадратом (2r+1)² двумя проходами (по X и по Z).
static func _blur(src: PackedFloat32Array, gw: int, gh: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(gw * gh)
	var out := PackedFloat32Array()
	out.resize(gw * gh)
	var k := 1.0 / (2 * r + 1)
	for z in gh:
		for x in gw:
			var sum := 0.0
			for d in range(-r, r + 1):
				sum += src[z * gw + clampi(x + d, 0, gw - 1)]
			tmp[z * gw + x] = sum * k
	for z in gh:
		for x in gw:
			var sum := 0.0
			for d in range(-r, r + 1):
				sum += tmp[clampi(z + d, 0, gh - 1) * gw + x]
			out[z * gw + x] = sum * k
	return out


## Значение сетки в дробном узле (билинейно, за краем — край).
static func _bilinear(arr: PackedFloat32Array, gw: int, gh: int, fx: float, fz: float) -> float:
	fx = clampf(fx, 0.0, gw - 1.0)
	fz = clampf(fz, 0.0, gh - 1.0)
	var ix := mini(floori(fx), gw - 2)
	var iz := mini(floori(fz), gh - 2)
	var tx := fx - ix
	var tz := fz - iz
	var a := lerpf(arr[iz * gw + ix], arr[iz * gw + ix + 1], tx)
	var b := lerpf(arr[(iz + 1) * gw + ix], arr[(iz + 1) * gw + ix + 1], tx)
	return lerpf(a, b, tz)
