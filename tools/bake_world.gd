extends SceneTree
## Запекает карту в мир для игры: рельеф Terrain3D и сцены-чанки.
## Источники: базовый рельеф game/world/terrain/base (правится кистями в
## Godot, см. WorldTerrain) и карта из Blender art/map/map.blend (дороги,
## маски леса, постройки, места). Вся цепочка одной командой — tools/export_map.sh:
##   1. blender --background art/map/map.blend --python tools/blender/export_map.py
##      -> art/map/export/ (маски, дороги, старт, объекты);
##   2. godot --path . -s res://tools/bake_world.gd   (этот скрипт)
##      -> game/world/terrain/baked (рельеф с дорогами),
##         game/world/chunks/chunk_X_Z.tscn (дороги, лес, постройки),
##         game/world/world.tscn (всё вместе, для обзора),
##         game/world/world_index.tres (что грузит игра, см. WorldIndex),
##         game/world/map_base.png (подложка карты-схемы, tools/map_base.gd).
##
## Что делает: собирает из линий дорог сеть (концы ближе NODE_MERGE_M — один
## узел, конец у середины другой дороги — Т-перекрёсток), кладёт дороги на
## рельеф (сглаженный профиль, ограничение уклона), выравнивает под ними
## землю и рисует покрытие текстурой рельефа (грунтовка — только рельеф, у
## шоссе поверх лежит лента асфальта RoadPath), расставляет растительность по
## маскам из Blender,
## ставит объекты из коллекции Props (tools/map_props.gd, docs/map-pipeline.md)
## и режет дороги, лес и объекты на чанки по 256 м. Вокруг объектов и точек доставок
## растительность не ставится — прогалины, tools/map_clearings.gd. Места и точки доставок (Places, Spots,
## tools/map_places.gd) идут только в world_index.tres, высота — по рельефу.
##
## Чанки и запечённый рельеф ПЕРЕЗАПИСЫВАЮТСЯ целиком: правятся базовый
## рельеф и карта в Blender, а не они.
## Запускать без --headless: в headless MultiMesh не отдаёт данные и
## растительность сохранится пустой.

const MaterialBuilder := preload("res://tools/material_builder.gd")
const MapProps := preload("res://tools/map_props.gd")
const MapPlaces := preload("res://tools/map_places.gd")
const MapClearings := preload("res://tools/map_clearings.gd")
const MapBase := preload("res://tools/map_base.gd")
const TerrainAssets := preload("res://tools/terrain_assets.gd")
const EXPORT_DIR := "res://art/map/export/"
const ASSETS := "res://game/world/assets/"
const CHUNKS := "res://game/world/chunks/"
const WORLD_SCENE := "res://game/world/world.tscn"

const CS := WorldDefs.CHUNK_SIZE
const GRID_STEP := 4.0
const GRID_N := 64 ## клеток сетки масок на сторону чанка
const WATER_LEVEL := WorldDefs.WATER_LEVEL
const ROAD_MIN_Y := WATER_LEVEL + 0.8 ## ниже дорога не опускается: у причала полотно у самой воды
const ROAD_SAMPLE_M := 4.0
const NODE_MERGE_M := 8.0
const ROAD_MAX_GRADE := 0.14
const ROAD_SHOULDER_M := 1.5 ## ровная обочина за краем покрытия
const ROAD_BLEND_M := 14.0 ## дальше рельеф плавно возвращается к своей высоте
const DECK_SINK_M := 0.1 ## рельеф под лентой шоссе ниже неё, чтобы не просвечивал
const DECK_SINK_INSET_M := 1.0 ## у кромки рельеф вровень с лентой
const HIGHWAY_WEIGHT := 30.0 ## на стыке высоту задаёт шоссе, грунтовка подстраивается
const CAP_WEIGHT := 0.02 ## вес торца куска дороги: за концом высоту задаёт дорога, идущая дальше
const SAND_BELOW_M := WATER_LEVEL + 1.2 ## ниже — песок вместо поля
const AUTO_SLOPE := 2.5 ## auto_slope материала рельефа (tools/terrain_assets.gd)
const FOREST_TINT := Color(0.53, 0.66, 0.62) ## земля под лесом темнее поля (множитель цвета)
const SMOOTH_RADIUS := 10
const SMOOTH_PASSES := 3
const PAD_LIFT_M := 0.05 ## площадка развязки шоссе — над лентами (WorldDefs.ROAD_LIFT_M)
const VEG_STEP := 7.0
const VEG_SEED := 42
const CONTROL_EVERY := 5 ## каждая 5-я точка оси (~20 м) — точка кривой RoadPath

var _assets: Dictionary = {}
var _chunk_min := Vector2i.ZERO
var _chunks_n := Vector2i.ZERO
var _gw: int = 0 ## точек сетки по X
var _gh: int = 0 ## точек сетки по Z
var _x0: float = 0.0
var _z0: float = 0.0
var _w: int = 0 ## точек рельефа Terrain3D по X (1 на метр)
var _h: int = 0 ## точек рельефа Terrain3D по Z
var _hm := PackedFloat32Array() ## высоты рельефа, 1 точка на метр; после _stamp_roads — с дорогами
var _hgt := PackedFloat32Array() ## те же высоты на сетке масок (GRID_STEP): профили дорог, подложка карты
var _forest := PackedFloat32Array()
var _conifer := PackedFloat32Array()
var _rocks := PackedFloat32Array()
var _edge_dist := PackedFloat32Array() ## расстояние до края ближайшей дороги, м
var _roads: Array = [] ## [{points: PackedVector3Array, type: int}]
var _nodes: Array = [] ## [{pos: Vector3, degree: int, highway: bool}]
var _start := Transform3D()
var _props: Dictionary = {} ## чанк -> [объект из MapProps.parse]
var _places: Array[Dictionary] = [] ## MapPlaces.parse, для WorldIndex.places
var _spots: Array[Dictionary] = [] ## MapPlaces.parse, для WorldIndex.spots
var _clearings: Array[Dictionary] = [] ## MapClearings: без растительности


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame # в _initialize дерево ещё не готово (нужны глобальные координаты)
	if DisplayServer.get_name() == "headless":
		push_warning("Запуск в headless: растительность сохранится пустой. Запускайте с окном.")
	var data := _load_export()
	if data.is_empty():
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ASSETS))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CHUNKS))
	if not TerrainAssets.ensure():
		quit(1)
		return
	_bake_assets()
	_build_roads(data["roads"])
	var pieces := _split_roads()
	var road_tex := _stamp_roads(pieces)
	_hgt = _grid_from_hm()
	_bake_terrain(road_tex)
	_place_start(data.get("start"))
	var props := _group_props(data.get("props", []))
	# Высота мест и точек — по рельефу после выравнивания под дорогами.
	var ground := _ground
	var rect := Rect2(_x0, _z0, _chunks_n.x * CS, _chunks_n.y * CS)
	_places = MapPlaces.parse(data.get("places", []), "Places", MapPlaces.PLACE_RADIUS_M, ground, rect)
	_spots = MapPlaces.parse(data.get("spots", []), "Spots", MapPlaces.SPOT_RADIUS_M, ground, rect)
	_clearings.append_array(MapClearings.from_spots(_spots))
	print("дорог: %d участков, узлов: %d, объектов: %d, мест: %d, точек: %d" % [
		_roads.size(), _nodes.size(), props, _places.size(), _spots.size()])

	_clear_chunks()
	var coords: Array[Vector2i] = []
	for cz in _chunks_n.y:
		for cx in _chunks_n.x:
			var cc := _chunk_min + Vector2i(cx, cz)
			coords.append(cc)
			_bake_chunk(cc, pieces.get(cc, []))
	print("чанков: %d" % coords.size())
	_bake_world(coords)
	print("мир сохранён: %s" % WORLD_SCENE)
	_bake_map_base(coords)
	quit(0)


# --- Данные из Blender --------------------------------------------------------

func _load_export() -> Dictionary:
	var json_path := EXPORT_DIR + "map.json"
	if not FileAccess.file_exists(json_path):
		push_error("Нет %s — сначала экспорт из Blender (tools/export_map.sh)" % json_path)
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if not data is Dictionary:
		push_error("Не удалось прочитать %s" % json_path)
		return {}
	if not is_equal_approx(float(data["chunk_size"]), CS) or not is_equal_approx(float(data["grid_step"]), GRID_STEP):
		push_error("Экспорт с другим размером чанка или шагом сетки")
		return {}
	_chunk_min = Vector2i(int(data["chunk_min"][0]), int(data["chunk_min"][1]))
	_chunks_n = Vector2i(int(data["chunks"][0]), int(data["chunks"][1]))
	_gw = _chunks_n.x * GRID_N + 1
	_gh = _chunks_n.y * GRID_N + 1
	_x0 = _chunk_min.x * CS
	_z0 = _chunk_min.y * CS
	if int(data["grid"][0]) != _gw or int(data["grid"][1]) != _gh:
		push_error("Размер сетки в экспорте не совпадает с числом чанков")
		return {}
	_forest = _load_mask("forest")
	_conifer = _load_mask("conifer")
	_rocks = _load_mask("rocks")
	if _forest.size() != _gw * _gh:
		push_error("Размер масок не совпадает с сеткой")
		return {}
	# Высоты — из базового рельефа Terrain3D (правится в Godot), а не из Blender.
	if DirAccess.get_files_at(WorldTerrain.BASE_DIR).is_empty():
		push_error("Нет базового рельефа %s — сначала tools/import_terrain.gd" % WorldTerrain.BASE_DIR)
		return {}
	_w = _chunks_n.x * int(CS)
	_h = _chunks_n.y * int(CS)
	_hm = WorldTerrain.read_map(WorldTerrain.BASE_DIR, Terrain3DRegion.TYPE_HEIGHT,
		Rect2i(int(_x0), int(_z0), _w, _h)).get_data().to_float32_array()
	for i in _hm.size():
		if is_nan(_hm[i]):
			_hm[i] = 0.0
	_hgt = _grid_from_hm()
	return data


## Высоты рельефа на сетке масок: узел сетки — точка рельефа под ним (крайний
## ряд сетки лежит за последней точкой рельефа и берёт её высоту).
func _grid_from_hm() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_gw * _gh)
	var step := int(GRID_STEP)
	for gz in _gh:
		var pz := mini(gz * step, _h - 1)
		for gx in _gw:
			out[gz * _gw + gx] = _hm[pz * _w + mini(gx * step, _w - 1)]
	return out


## Высота рельефа в мировой точке (билинейно по точкам Terrain3D, за краем — край).
func _ground(x: float, z: float) -> float:
	var fx := clampf(x - _x0, 0.0, _w - 1.0)
	var fz := clampf(z - _z0, 0.0, _h - 1.0)
	var ix := mini(floori(fx), _w - 2)
	var iz := mini(floori(fz), _h - 2)
	var tx := fx - ix
	var tz := fz - iz
	var a := lerpf(_hm[iz * _w + ix], _hm[iz * _w + ix + 1], tx)
	var b := lerpf(_hm[(iz + 1) * _w + ix], _hm[(iz + 1) * _w + ix + 1], tx)
	return lerpf(a, b, tz)


func _load_mask(mask_name: String) -> PackedFloat32Array:
	var bytes := FileAccess.get_file_as_bytes(EXPORT_DIR + mask_name + ".u8")
	var out := PackedFloat32Array()
	out.resize(bytes.size())
	for i in bytes.size():
		out[i] = bytes[i] / 255.0
	return out


## Значение сетки в мировой точке (билинейно, за краем — край).
func _sample(arr: PackedFloat32Array, x: float, z: float) -> float:
	var fx := clampf((x - _x0) / GRID_STEP, 0.0, _gw - 1.0)
	var fz := clampf((z - _z0) / GRID_STEP, 0.0, _gh - 1.0)
	var ix := mini(floori(fx), _gw - 2)
	var iz := mini(floori(fz), _gh - 2)
	var tx := fx - ix
	var tz := fz - iz
	var a := lerpf(arr[iz * _gw + ix], arr[iz * _gw + ix + 1], tx)
	var b := lerpf(arr[(iz + 1) * _gw + ix], arr[(iz + 1) * _gw + ix + 1], tx)
	return lerpf(a, b, tz)


static func _hash4(a: int, b: int, c: int, d: int) -> int:
	var h: int = a * 374761393 + b * 668265263 + c * 1442695041 + d * 1274126177
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return h


static func _rand01(i: int, j: int, salt: int) -> float:
	return float(_hash4(VEG_SEED, i, j, salt) & 0xFFFFFF) / 16777216.0


# --- Ресурсы ------------------------------------------------------------------

func _save(res: Resource, file: String) -> Resource:
	var path := ASSETS + file
	var err := ResourceSaver.save(res, path, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
	assert(err == OK, "не удалось сохранить %s" % path)
	res.take_over_path(path)
	return res


func _bake_assets() -> void:
	var mb := MaterialBuilder.new()
	_assets["highway"] = _save(mb.highway, "highway.res")
	_assets["asphalt_plain"] = _save(mb.asphalt_plain, "asphalt_plain.res")
	_assets["dirt_road"] = _save(mb.dirt_road, "dirt_road.res")
	_assets["water"] = _save(mb.water, "water.tres")
	_assets["rock"] = _save(mb.rock_mesh, "rock.tres")
	_assets["bush"] = _save(mb.bush_mesh, "bush.tres")


# --- Дорожная сеть -------------------------------------------------------------

## Линии из Blender -> участки между узлами с высотами.
func _build_roads(src: Array) -> void:
	# 1. Линии в плоскости XZ.
	var lines: Array = [] ## [{pts: PackedVector2Array, type, cyclic, a, b}]
	for r: Dictionary in src:
		var pts := PackedVector2Array()
		for p in r["points"]:
			var v := Vector2(float(p[0]), float(p[1]))
			if pts.is_empty() or pts[pts.size() - 1].distance_to(v) > 0.05:
				pts.append(v)
		if r["cyclic"] and pts.size() > 2 and pts[0].distance_to(pts[pts.size() - 1]) < 0.05:
			pts.remove_at(pts.size() - 1)
		if pts.size() < 2:
			continue
		var t := WorldDefs.RoadType.DIRT if r["type"] == "dirt" else WorldDefs.RoadType.HIGHWAY
		lines.append({"pts": pts, "type": t, "cyclic": bool(r["cyclic"]), "a": -1, "b": -1})

	# 2. Узлы: концы ближе NODE_MERGE_M сливаются.
	var nodes := PackedVector2Array()
	for ln: Dictionary in lines:
		if ln["cyclic"]:
			continue
		var pts: PackedVector2Array = ln["pts"]
		ln["a"] = _node_for(nodes, pts[0])
		ln["b"] = _node_for(nodes, pts[pts.size() - 1])

	# 3. Т-перекрёстки: узел рядом с серединой чужой дороги делит её.
	for ni in nodes.size():
		var i := 0
		while i < lines.size():
			var ln: Dictionary = lines[i]
			if ln["a"] == ni or ln["b"] == ni:
				i += 1
				continue
			var hit := _project(ln["pts"], nodes[ni])
			var pts: PackedVector2Array = ln["pts"]
			var total := _poly_length(pts, ln["cyclic"])
			var inner: bool = ln["cyclic"] or (hit["s"] > NODE_MERGE_M and hit["s"] < total - NODE_MERGE_M)
			if hit["dist"] < NODE_MERGE_M and inner:
				nodes[ni] = hit["pos"]
				var parts := _split_line(ln, hit, ni)
				lines.remove_at(i)
				for k in parts.size():
					lines.insert(i + k, parts[k])
				i += parts.size()
			else:
				i += 1

	# 4. Замкнутые дороги без перекрёстков — один узел в первой точке.
	for ln: Dictionary in lines:
		if ln["cyclic"]:
			var pts: PackedVector2Array = ln["pts"]
			var n := _node_for(nodes, pts[0])
			pts.append(pts[0])
			ln["pts"] = pts
			ln["cyclic"] = false
			ln["a"] = n
			ln["b"] = n

	# 5. Узлы: высота, степень, тип. Концы линий — ровно в узлах.
	_nodes.clear()
	for p in nodes:
		var y := 0.0
		for k in 5: # среднее по кругу: узел не садится на кочку
			var off := Vector2.ZERO if k == 0 else Vector2(6.0, 0.0).rotated(k * TAU / 4.0)
			y += _sample(_hgt, p.x + off.x, p.y + off.y) / 5.0
		_nodes.append({"pos": Vector3(p.x, maxf(y, ROAD_MIN_Y), p.y), "degree": 0, "highway": false, "highways": 0})
	for ln: Dictionary in lines:
		for end in ["a", "b"]:
			var nd: Dictionary = _nodes[ln[end]]
			nd["degree"] += 1
			if ln["type"] == WorldDefs.RoadType.HIGHWAY:
				nd["highway"] = true
				nd["highways"] += 1
		var pts: PackedVector2Array = ln["pts"]
		pts[0] = nodes[ln["a"]]
		pts[pts.size() - 1] = nodes[ln["b"]]
		ln["pts"] = pts

	# 6. Равномерная выборка и профиль высоты.
	_roads.clear()
	for ln: Dictionary in lines:
		var flat := _resample(ln["pts"], ROAD_SAMPLE_M)
		if flat.size() < 2:
			continue
		var ha: float = _nodes[ln["a"]]["pos"].y
		var hb: float = _nodes[ln["b"]]["pos"].y
		var h := _road_profile(flat, ha, hb)
		var pts3 := PackedVector3Array()
		for k in flat.size():
			pts3.append(Vector3(flat[k].x, h[k], flat[k].y))
		_roads.append({"points": pts3, "type": ln["type"]})


func _node_for(nodes: PackedVector2Array, p: Vector2) -> int:
	for i in nodes.size():
		if nodes[i].distance_to(p) < NODE_MERGE_M:
			return i
	nodes.append(p)
	return nodes.size() - 1


static func _poly_length(pts: PackedVector2Array, cyclic: bool) -> float:
	var acc := 0.0
	for k in range(1, pts.size()):
		acc += pts[k].distance_to(pts[k - 1])
	if cyclic:
		acc += pts[0].distance_to(pts[pts.size() - 1])
	return acc


## Ближайшая точка линии: {seg (индекс начала отрезка), pos, dist, s}.
static func _project(pts: PackedVector2Array, p: Vector2) -> Dictionary:
	var best := {"seg": 0, "pos": pts[0], "dist": INF, "s": 0.0}
	var acc := 0.0
	for k in range(1, pts.size()):
		var a := pts[k - 1]
		var b := pts[k]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := q.distance_to(p)
		if d < best["dist"]:
			best = {"seg": k - 1, "pos": q, "dist": d, "s": acc + a.distance_to(q)}
		acc += a.distance_to(b)
	return best


## Делит линию в точке hit, новые концы — узел ni. Замкнутая становится одной
## открытой линией из узла в узел, открытая — двумя.
static func _split_line(ln: Dictionary, hit: Dictionary, ni: int) -> Array:
	var pts: PackedVector2Array = ln["pts"]
	var seg: int = hit["seg"]
	var p: Vector2 = hit["pos"]
	if ln["cyclic"]:
		var ring := PackedVector2Array([p])
		ring.append_array(pts.slice(seg + 1))
		ring.append_array(pts.slice(0, seg + 1))
		ring.append(p)
		return [{"pts": ring, "type": ln["type"], "cyclic": false, "a": ni, "b": ni}]
	var first := pts.slice(0, seg + 1)
	first.append(p)
	var second := PackedVector2Array([p])
	second.append_array(pts.slice(seg + 1))
	return [
		{"pts": first, "type": ln["type"], "cyclic": false, "a": ln["a"], "b": ni},
		{"pts": second, "type": ln["type"], "cyclic": false, "a": ni, "b": ln["b"]},
	]


## Точки через ~step по длине линии (концы сохраняются).
static func _resample(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var cum := PackedFloat32Array([0.0])
	for k in range(1, pts.size()):
		cum.append(cum[k - 1] + pts[k].distance_to(pts[k - 1]))
	var total := cum[cum.size() - 1]
	if total < 0.5:
		return PackedVector2Array()
	var n := maxi(2, ceili(total / step))
	var out := PackedVector2Array()
	var j := 0
	for k in n + 1:
		var s := total * k / n
		while j < pts.size() - 2 and cum[j + 1] < s:
			j += 1
		var seg := cum[j + 1] - cum[j]
		var t := clampf((s - cum[j]) / seg, 0.0, 1.0) if seg > 0.0001 else 0.0
		out.append(pts[j].lerp(pts[j + 1], t))
	return out


## Высоты вдоль дороги: рельеф -> сглаживание -> концы в узлах -> предел уклона.
func _road_profile(flat: PackedVector2Array, ha: float, hb: float) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(flat.size())
	for k in flat.size():
		h[k] = _sample(_hgt, flat[k].x, flat[k].y)
	for _pass in SMOOTH_PASSES:
		h = _smooth(h, SMOOTH_RADIUS)
	var last := h.size() - 1
	var e0 := ha - h[0]
	var e1 := hb - h[last]
	for k in h.size():
		h[k] = maxf(h[k] + lerpf(e0, e1, float(k) / last), ROAD_MIN_Y)
	h[0] = ha
	h[last] = hb
	var step := flat[0].distance_to(flat[1])
	var dmax := ROAD_MAX_GRADE * step
	for k in range(1, last):
		h[k] = clampf(h[k], h[k - 1] - dmax, h[k - 1] + dmax)
	for k in range(last - 1, 0, -1):
		h[k] = clampf(h[k], h[k + 1] - dmax, h[k + 1] + dmax)
	return h


static func _smooth(src: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(src.size())
	var n := src.size()
	for i in n:
		var sum := 0.0
		for k in range(i - radius, i + radius + 1):
			sum += src[clampi(k, 0, n - 1)]
		out[i] = sum / (radius * 2 + 1)
	return out


## Вдавливает дороги в рельеф _hm (1 точка на метр) и заполняет _edge_dist.
## Возвращает покрытие по точкам рельефа: 0 — нет, иначе номер текстуры
## (на грунтовке — грунт, под лентой шоссе — асфальт, у его кромки и на
## обочине — грунт).
## Высота у дороги — среднее по всем дорогам рядом с весом, быстро падающим
## от края полотна (у шоссе вес больше): на самом полотне это его профиль,
## а на стыке грунтовка плавно подходит к асфальту, без ступеньки.
## Дороги берутся по готовым кривым кусков и с той же выборкой, что у RoadPath:
## земля ложится ровно под ленту шоссе, без расхождений на перегибах профиля.
func _stamp_roads(pieces: Dictionary) -> PackedByteArray:
	var count := _w * _h
	var edge := PackedFloat32Array() # расстояние до края ближайшего полотна
	edge.resize(count)
	edge.fill(INF)
	var sum_w := PackedFloat32Array()
	sum_w.resize(count)
	var sum_wy := PackedFloat32Array()
	sum_wy.resize(count)
	var road_tex := PackedByteArray()
	road_tex.resize(count)
	var under_deck := PackedByteArray() # точка под лентой шоссе, не у кромки
	under_deck.resize(count)
	var deck_y := PackedFloat32Array() # под лентой шоссе высота строго её, без смешения
	deck_y.resize(count)
	deck_y.fill(INF)
	# Ближайшая точка текущего куска дороги для каждой задетой точки рельефа.
	var cur_e := PackedFloat32Array()
	cur_e.resize(count)
	cur_e.fill(INF)
	var cur_y := PackedFloat32Array()
	cur_y.resize(count)
	# Точка лежит за торцом куска (а не сбоку от него). Куски стыкуются на
	# границах чанков и в узлах: там высоту задаёт кусок, мимо которого точка
	# лежит сбоку, иначе на уклоне торец соседа тянул бы землю к своей высоте.
	var cur_cap := PackedByteArray()
	cur_cap.resize(count)
	for list: Array in pieces.values():
		for piece: Dictionary in list:
			var pts := _deck_points(piece["curve"], piece["origin"])
			var highway: bool = piece["type"] == WorldDefs.RoadType.HIGHWAY
			var hw: float = WorldDefs.ROAD_WIDTHS[piece["type"]] * 0.5
			var reach := hw + ROAD_SHOULDER_M + ROAD_BLEND_M
			var touched := PackedInt32Array()
			for k in pts.size() - 1:
				var a := pts[k]
				var b := pts[k + 1]
				var ax := a.x - _x0
				var az := a.z - _z0
				var sx := b.x - a.x
				var sz := b.z - a.z
				var len2 := maxf(sx * sx + sz * sz, 0.0001)
				var px0 := maxi(floori(minf(ax, ax + sx) - reach), 0)
				var px1 := mini(ceili(maxf(ax, ax + sx) + reach), _w - 1)
				var pz0 := maxi(floori(minf(az, az + sz) - reach), 0)
				var pz1 := mini(ceili(maxf(az, az + sz) + reach), _h - 1)
				for pz in range(pz0, pz1 + 1):
					for px in range(px0, px1 + 1):
						var t_raw := ((px - ax) * sx + (pz - az) * sz) / len2
						var t := clampf(t_raw, 0.0, 1.0)
						var dx := px - (ax + sx * t)
						var dz := pz - (az + sz * t)
						var e := sqrt(dx * dx + dz * dz) - hw
						var i := pz * _w + px
						if e < cur_e[i] and e < ROAD_SHOULDER_M + ROAD_BLEND_M:
							if cur_e[i] == INF:
								touched.append(i)
							cur_e[i] = e
							cur_y[i] = lerpf(a.y, b.y, t)
							cur_cap[i] = 1 if (k == 0 and t_raw < 0.0) or (k == pts.size() - 2 and t_raw > 1.0) else 0
			for i in touched:
				var e := cur_e[i]
				var cap := cur_cap[i] == 1
				var wt := (HIGHWAY_WEIGHT if highway else 1.0) / pow(maxf(e, 0.0) + 0.3, 3.0)
				if cap:
					wt *= CAP_WEIGHT
				sum_w[i] += wt
				sum_wy[i] += wt * cur_y[i]
				edge[i] = minf(edge[i], e)
				if highway:
					if e <= 0.5 and (not cap or deck_y[i] == INF):
						deck_y[i] = cur_y[i]
					# Асфальт рельефа — только под лентой (если она вдали мерцает, под
					# ней тот же цвет), у кромки и на обочине — грунт.
					if e <= -DECK_SINK_INSET_M:
						road_tex[i] = WorldTerrain.TEX_ASPHALT
						under_deck[i] = 1
					elif e <= ROAD_SHOULDER_M and road_tex[i] == 0:
						road_tex[i] = WorldTerrain.TEX_DIRT
				elif e <= 0.0 and road_tex[i] != WorldTerrain.TEX_ASPHALT:
					road_tex[i] = WorldTerrain.TEX_DIRT
				cur_e[i] = INF

	for i in count:
		if sum_w[i] <= 0.0:
			continue
		var y := deck_y[i] if deck_y[i] != INF else sum_wy[i] / sum_w[i]
		_hm[i] = lerpf(y, _hm[i], smoothstep(ROAD_SHOULDER_M, ROAD_SHOULDER_M + ROAD_BLEND_M, edge[i]))
		if under_deck[i] == 1:
			_hm[i] -= DECK_SINK_M

	# Расстояние до дороги на сетке масок — для растительности.
	_edge_dist.resize(_gw * _gh)
	var step := int(GRID_STEP)
	for gz in _gh:
		var pz := mini(gz * step, _h - 1)
		for gx in _gw:
			_edge_dist[gz * _gw + gx] = minf(edge[pz * _w + mini(gx * step, _w - 1)], 1e6)
	return road_tex


## Пишет рельеф для игры (WorldTerrain.BAKED_DIR): высоты с дорогами, покрытие
## и цвет. Покрытие и цвет, нарисованные кистью в базовом рельефе, сохраняются;
## поверх — дороги, песок у воды (где покрытие не задано рукой) и тёмная
## земля под лесом.
func _bake_terrain(road_tex: PackedByteArray) -> void:
	var rect := Rect2i(int(_x0), int(_z0), _w, _h)
	var ctrl := WorldTerrain.read_map(WorldTerrain.BASE_DIR, Terrain3DRegion.TYPE_CONTROL, rect) \
		.get_data().to_float32_array()
	var color_img := WorldTerrain.read_map(WorldTerrain.BASE_DIR, Terrain3DRegion.TYPE_COLOR, rect)
	var color := color_img.get_data()
	var auto_px := Terrain3DUtil.as_float(Terrain3DUtil.enc_auto(true))
	var tex_px := PackedFloat32Array()
	for id in 32:
		tex_px.append(Terrain3DUtil.as_float(Terrain3DUtil.enc_base(id)))
	for pz in _h:
		for px in _w:
			var i := pz * _w + px
			if road_tex[i] != 0:
				ctrl[i] = tex_px[road_tex[i]]
			elif ctrl[i] == auto_px and _hm[i] < SAND_BELOW_M:
				ctrl[i] = tex_px[WorldTerrain.TEX_SAND]
			# Под лесом темнее только поле: дороги, песок и скала на склонах
			# остаются своего цвета (доля поля — как в автошейдере материала).
			var fw := _sample(_forest, _x0 + px, _z0 + pz) if ctrl[i] == auto_px else 0.0
			if fw > 0.01:
				var dx := (_hm[pz * _w + mini(px + 1, _w - 1)] - _hm[pz * _w + maxi(px - 1, 0)]) * 0.5
				var dz := (_hm[mini(pz + 1, _h - 1) * _w + px] - _hm[maxi(pz - 1, 0) * _w + px]) * 0.5
				fw *= clampf(1.0 - 2.0 * AUTO_SLOPE * (1.0 - 1.0 / sqrt(1.0 + dx * dx + dz * dz)), 0.0, 1.0)
				var c := i * 4
				color[c] = int(color[c] * lerpf(1.0, FOREST_TINT.r, fw))
				color[c + 1] = int(color[c + 1] * lerpf(1.0, FOREST_TINT.g, fw))
				color[c + 2] = int(color[c + 2] * lerpf(1.0, FOREST_TINT.b, fw))

	var dir_abs := ProjectSettings.globalize_path(WorldTerrain.BAKED_DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	for f in DirAccess.get_files_at(WorldTerrain.BAKED_DIR):
		DirAccess.remove_absolute(dir_abs.path_join(f))
	var terrain := WorldTerrain.create(WorldTerrain.BAKED_DIR)
	terrain.collision_mode = Terrain3DCollision.DISABLED
	terrain.save_16_bit = true # высоты с точностью ~2 мм, файлы втрое меньше
	get_root().add_child(terrain)
	terrain.data.import_images([
		Image.create_from_data(_w, _h, false, Image.FORMAT_RF, _hm.to_byte_array()),
		Image.create_from_data(_w, _h, false, Image.FORMAT_RF, ctrl.to_byte_array()),
		Image.create_from_data(_w, _h, false, Image.FORMAT_RGBA8, color),
	], Vector3(_x0, 0.0, _z0), 0.0, 1.0)
	terrain.data.save_directory(WorldTerrain.BAKED_DIR)
	print("рельеф: %d×%d м, регионов %d -> %s" % [_w, _h, terrain.data.get_region_count(), WorldTerrain.BAKED_DIR])
	terrain.free()


## Старт: ближайшая к PlayerStart точка дороги, правая полоса, по ходу пустышки.
func _place_start(start: Variant) -> void:
	var want := Vector2.ZERO
	var fwd2 := Vector2(1, 0)
	if start is Dictionary:
		want = Vector2(float(start["pos"][0]), float(start["pos"][2]))
		fwd2 = Vector2(float(start["forward"][0]), float(start["forward"][1])).normalized()
	else:
		var pts0: PackedVector3Array = _roads[0]["points"]
		var mid := pts0[pts0.size() / 2]
		want = Vector2(mid.x, mid.z)
	var best_d := INF
	var best_r := 0
	var best_k := 0
	for ri in _roads.size():
		var pts: PackedVector3Array = _roads[ri]["points"]
		for k in range(1, pts.size() - 1):
			var d := Vector2(pts[k].x, pts[k].z).distance_to(want)
			if d < best_d:
				best_d = d
				best_r = ri
				best_k = k
	var pts: PackedVector3Array = _roads[best_r]["points"]
	var p := pts[best_k]
	var dir := pts[best_k + 1] - pts[best_k - 1]
	dir.y = 0.0
	dir = dir.normalized()
	if Vector2(dir.x, dir.z).dot(fwd2) < 0.0:
		dir = -dir
	var right := Vector3(-dir.z, 0.0, dir.x)
	var lane := 2.6 if _roads[best_r]["type"] == WorldDefs.RoadType.HIGHWAY else 1.6
	_start = Transform3D(Basis.looking_at(dir, Vector3.UP), p + right * lane + Vector3.UP * 1.2)


## Режет каждую дорогу по границам чанков. Результат: чанк -> куски
## {curve (в координатах чанка), origin (угол чанка), type, uv}.
func _split_roads() -> Dictionary:
	var out := {}
	for r: Dictionary in _roads:
		var pts := _insert_border_points(r["points"])
		var dists := PackedFloat32Array([0.0])
		for k in range(1, pts.size()):
			dists.append(dists[k - 1] + pts[k].distance_to(pts[k - 1]))
		var tangents := PackedVector3Array()
		for k in pts.size():
			var a := pts[maxi(k - 1, 0)]
			var b := pts[mini(k + 1, pts.size() - 1)]
			tangents.append((b - a).normalized())
		var start := 0
		for k in range(1, pts.size()):
			var ck := WorldDefs.chunk_of((pts[k - 1] + pts[k]) * 0.5)
			var last := k == pts.size() - 1
			var next_ck := ck if last else WorldDefs.chunk_of((pts[k] + pts[k + 1]) * 0.5)
			if last or next_ck != ck:
				if not out.has(ck):
					out[ck] = []
				var origin := Vector3(ck.x * CS, 0.0, ck.y * CS)
				out[ck].append({
					"curve": _make_curve(pts.slice(start, k + 1), tangents.slice(start, k + 1), origin),
					"origin": origin,
					"type": r["type"],
					"uv": dists[start],
				})
				start = k
	return out


## Точки полотна в глобальных координатах — как их строит RoadPath (шаг SAMPLE_M,
## кубическая интерполяция кривой); между ними полотно плоское.
static func _deck_points(curve: Curve3D, origin: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	var length := curve.get_baked_length()
	var n := maxi(2, ceili(length / RoadPath.SAMPLE_M))
	for k in n + 1:
		out.append(curve.sample_baked(length * k / n, true) + origin)
	return out


## Вставляет точки пересечения с границами чанков (x или z кратны CHUNK_SIZE).
static func _insert_border_points(src: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array([src[0]])
	for k in range(1, src.size()):
		var a := src[k - 1]
		var b := src[k]
		var ts: Array[float] = []
		for axis in [0, 2]:
			var va: float = a[axis]
			var vb: float = b[axis]
			var lo := minf(va, vb)
			var hi := maxf(va, vb)
			var line := ceilf(lo / CS) * CS
			while line < hi:
				if line > lo:
					ts.append((line - va) / (vb - va))
				line += CS
		ts.sort()
		for t in ts:
			if t > 0.02 and t < 0.98:
				out.append(a.lerp(b, t))
		out.append(b)
	return out


static func _make_curve(pts: PackedVector3Array, tangents: PackedVector3Array, origin: Vector3) -> Curve3D:
	var idx: Array[int] = []
	for k in range(0, pts.size(), CONTROL_EVERY):
		idx.append(k)
	var last := pts.size() - 1
	if idx[idx.size() - 1] != last:
		if last - idx[idx.size() - 1] < 2 and idx.size() > 1:
			idx[idx.size() - 1] = last
		else:
			idx.append(last)
	var curve := Curve3D.new()
	curve.bake_interval = 1.0
	for n in idx.size():
		var k := idx[n]
		var p := pts[k]
		var t := tangents[k]
		var d_prev := p.distance_to(pts[idx[n - 1]]) if n > 0 else 0.0
		var d_next := p.distance_to(pts[idx[n + 1]]) if n < idx.size() - 1 else 0.0
		curve.add_point(p - origin, -t * d_prev / 3.0, t * d_next / 3.0)
	return curve


# --- Объекты (Props) -------------------------------------------------------------

## Раскладывает объекты по чанкам (по позиции пустышки). Объекты вне мира
## пропускаются. Возвращает, сколько объектов попало в чанки.
func _group_props(src: Variant) -> int:
	_props.clear()
	_clearings.clear()
	if not src is Array:
		return 0
	var rect := Rect2(_x0, _z0, _chunks_n.x * CS, _chunks_n.y * CS)
	var n := 0
	for prop in MapProps.parse(src):
		var p: Vector3 = prop["transform"].origin
		if not rect.has_point(Vector2(p.x, p.z)):
			push_warning("Props/%s: вне мира (%.0f, %.0f) — пропускаю" % [prop["name"], p.x, p.z])
			continue
		var cc := WorldDefs.chunk_of(p)
		if not _props.has(cc):
			_props[cc] = []
		_props[cc].append(prop)
		_clearings.append_array(MapClearings.from_props([prop]))
		n += 1
	return n


# --- Чанк ----------------------------------------------------------------------

func _clear_chunks() -> void:
	var dir := ProjectSettings.globalize_path(CHUNKS)
	for f in DirAccess.get_files_at(CHUNKS):
		DirAccess.remove_absolute(dir.path_join(f))


func _bake_chunk(cc: Vector2i, pieces: Array) -> void:
	var origin := Vector3(cc.x * CS, 0.0, cc.y * CS)
	var base := "chunk_%d_%d" % [cc.x, cc.y]
	var root := WorldChunk.new()
	root.name = "Chunk_%d_%d" % [cc.x, cc.y]
	root.coord = cc

	var roads := Node3D.new()
	roads.name = "Roads"
	root.add_child(roads)
	var n := 0
	for piece in pieces:
		var rp := RoadPath.new()
		rp.name = "Road%d" % n
		n += 1
		rp.road_type = piece["type"]
		rp.uv_offset_m = piece["uv"]
		rp.curve = piece["curve"]
		roads.add_child(rp)

	var junctions := Node3D.new()
	junctions.name = "Junctions"
	root.add_child(junctions)
	n = 0
	var rect := Rect2(origin.x, origin.z, CS, CS)
	for nd: Dictionary in _nodes:
		var np: Vector3 = nd["pos"]
		# Площадка нужна только на развязке шоссе: закрывает наложение лент.
		# Остальные перекрёстки — рельеф.
		if nd["highways"] < 3 or not rect.has_point(Vector2(np.x, np.z)):
			continue
		var j := RoadJunction.new()
		j.name = "Junction%d" % n
		n += 1
		j.position = np - origin + Vector3(0.0, PAD_LIFT_M, 0.0)
		junctions.add_child(j)

	var veg_root := Node3D.new()
	veg_root.name = "Vegetation"
	root.add_child(veg_root)
	var veg := _vegetation(cc)
	# Деревья: MultiMesh без меша — только расстановка, меши даёт набор деревьев слоя.
	_add_layer(veg_root, cc, "Conifers", null, veg["conifer"], 520.0, true, 0.35, 6.0, 0.0,
		VegetationLayer.TreePreset.CONIFER_FOREST)
	_add_layer(veg_root, cc, "Trees", null, veg["leafy"], 520.0, true, 0.35, 6.0, 0.0,
		VegetationLayer.TreePreset.LEAFY_FOREST)
	_add_layer(veg_root, cc, "Rocks", _assets["rock"], veg["rocks"], 380.0, true, 0.8, 0.9, 1.0)
	_add_layer(veg_root, cc, "Bushes", _assets["bush"], veg["bushes"], 220.0, false, 0.0, 0.0, 0.0)

	var props := Node3D.new()
	props.name = "Props"
	root.add_child(props)
	for prop: Dictionary in _props.get(cc, []):
		props.add_child(MapProps.build(prop, origin, _ground))

	_set_owner(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, WorldDefs.chunk_scene_path(cc))
	assert(err == OK)
	root.free()


## Подложка карты-схемы (tools/map_base.gd) по рельефу с дорогами.
func _bake_map_base(coords: Array[Vector2i]) -> void:
	var grid := {"hgt": _hgt, "forest": _forest, "conifer": _conifer, "w": _gw, "h": _gh,
		"x0": _x0, "z0": _z0, "step": GRID_STEP}
	var img := MapBase.render(grid, WorldDefs.rect_of_chunks(coords))
	var err := img.save_png(MapBase.PATH)
	if err != OK:
		push_error("Не удалось сохранить подложку %s: %s" % [MapBase.PATH, error_string(err)])
	print("подложка карты: %s, %d × %d" % [MapBase.PATH, img.get_width(), img.get_height()])


## Растительность чанка по маскам из Blender (forest, conifer, rocks),
## кроме прогалин вокруг объектов и точек доставок.
func _vegetation(cc: Vector2i) -> Dictionary:
	var conifer: Array[Transform3D] = []
	var leafy: Array[Transform3D] = []
	var rocks: Array[Transform3D] = []
	var bushes: Array[Transform3D] = []
	var steps := int(CS / VEG_STEP)
	var x0 := cc.x * CS
	var z0 := cc.y * CS
	var clear := MapClearings.near(_clearings, Rect2(x0, z0, CS, CS))
	for j in steps:
		for i in steps:
			var gi := cc.x * steps + i
			var gj := cc.y * steps + j
			var lx := (i + 0.15 + _rand01(gi, gj, 60) * 0.7) * VEG_STEP
			var lz := (j + 0.15 + _rand01(gi, gj, 61) * 0.7) * VEG_STEP
			var wx := x0 + lx
			var wz := z0 + lz
			var h := _ground(wx, wz)
			if h < WATER_LEVEL + 1.2:
				continue
			if _sample(_edge_dist, wx, wz) < 4.0:
				continue
			if MapClearings.blocked(clear, wx, wz):
				continue
			var slope := absf(_ground(wx + 2.0, wz) - _ground(wx - 2.0, wz)) / 4.0 \
				+ absf(_ground(wx, wz + 2.0) - _ground(wx, wz - 2.0)) / 4.0
			var fw := _sample(_forest, wx, wz)
			var rw := _sample(_rocks, wx, wz)
			var tree_density := 0.02 + 0.55 * fw
			var rock_density := 0.005 + 0.09 * rw
			var bush_density := 0.04 + 0.08 * fw
			var r := _rand01(gi, gj, 50)
			var rot := _rand01(gi, gj, 52) * TAU
			var scale := 0.75 + _rand01(gi, gj, 53) * 0.6
			var basis := Basis(Vector3.UP, rot).scaled(Vector3.ONE * scale)
			var pos := Vector3(lx, h - 0.2, lz)
			if r < tree_density and slope < 0.7:
				if _rand01(gi, gj, 51) < _sample(_conifer, wx, wz):
					conifer.append(Transform3D(basis, pos))
				else:
					leafy.append(Transform3D(basis, pos))
			elif r < tree_density + rock_density:
				var rs := 0.6 + _rand01(gi, gj, 54) * 1.6
				var rb := Basis(Vector3(_rand01(gi, gj, 55), 1.0, _rand01(gi, gj, 56)).normalized(), rot)
				rocks.append(Transform3D(rb.scaled(Vector3(rs, rs * 0.7, rs)), pos))
			elif r < tree_density + rock_density + bush_density and slope < 0.8:
				bushes.append(Transform3D(basis, pos + Vector3(0, 0.1, 0)))
	return {"conifer": conifer, "leafy": leafy, "rocks": rocks, "bushes": bushes}


func _add_layer(parent: Node, cc: Vector2i, layer_name: String, mesh: Mesh, xforms: Array, range_end: float,
		shadows: bool, radius: float, height: float, min_scale: float,
		preset: VegetationLayer.TreePreset = VegetationLayer.TreePreset.NONE) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(cc) + layer_name.hash()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		var v := rng.randf_range(0.8, 1.15)
		mm.set_instance_color(i, Color(v * rng.randf_range(0.92, 1.08), v, v * rng.randf_range(0.85, 1.0)))
	var layer := VegetationLayer.new()
	layer.name = layer_name
	layer.multimesh = mm
	layer.visibility_range_end = range_end
	layer.visibility_range_end_margin = 20.0
	layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	layer.collider_radius = radius
	layer.collider_height = height
	layer.collider_min_scale = min_scale
	layer.tree_preset = preset
	parent.add_child(layer)


func _set_owner(node: Node, owner_node: Node) -> void:
	for c in node.get_children():
		c.owner = owner_node
		if c.scene_file_path.is_empty():
			_set_owner(c, owner_node)


# --- Сцена мира -----------------------------------------------------------------

func _bake_world(coords: Array[Vector2i]) -> void:
	var root := WorldMap.new()
	root.name = "World"
	for cc in coords:
		var ps: PackedScene = ResourceLoader.load(WorldDefs.chunk_scene_path(cc), "", ResourceLoader.CACHE_MODE_REPLACE)
		var inst := ps.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		inst.position = Vector3(cc.x * CS, 0.0, cc.y * CS)
		root.add_child(inst)

	var rect := WorldDefs.rect_of_chunks(coords)
	root.add_child(WorldTerrain.create())
	root.add_child(WorldTerrain.make_water(rect))

	var start := Marker3D.new()
	start.name = "PlayerStart"
	start.transform = _start
	root.add_child(start)
	root.add_child(ChunkStreamer.make_bounds(rect))

	_set_owner(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, WORLD_SCENE)
	assert(err == OK)
	# Индекс мира (что грузит игра) считается в глобальных координатах,
	# поэтому сцену ненадолго ставим в дерево.
	(root.get_node("Terrain3D") as Terrain3D).clipmap_target = root # камеры здесь нет
	get_root().add_child(root)
	WorldIndex.save_from(root, _places, _spots)
	root.free()
