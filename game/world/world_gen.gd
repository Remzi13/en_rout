class_name WorldGen
extends RefCounted
## Детерминированный генератор мира по сиду: рельеф, биомы, дорожная сеть,
## растительность. Не трогает сцену — только считает данные, поэтому
## build_chunk_data() можно вызывать из рабочего потока (на каждый поток —
## свой экземпляр WorldGen).
##
## Дороги: мир разбит на клетки CELL_SIZE, в каждой клетке — узел со
## случайным смещением. Узлы соединены рёбрами на восток и на север
## (часть рёбер выпадает). Ребро — кривая Безье, высота вдоль неё сглажена
## и прибита к высоте узлов, поэтому участки стыкуются через границы чанков.

const CHUNK_SIZE := 256.0
const GRID_STEP := 4.0
const GRID_N := 64 ## клеток рельефа на сторону чанка
const CELL_SIZE := 480.0
const CELL_JITTER := 120.0
const WATER_LEVEL := -4.0
const ROAD_MIN_Y := WATER_LEVEL + 1.6
const ROAD_SAMPLE_M := 4.0
const ROAD_SHOULDER_M := 1.5
const ROAD_BLEND_M := 18.0
const ROAD_SINK_M := 0.3 ## рельеф под дорогой ниже полотна
const ROAD_LIFT_M := 0.06 ## полотно над осевой высотой
const PAD_LIFT_M := 0.03
const PAD_RADIUS_M := 10.0
const EDGE_CHANCE := 0.72
const HIGHWAY_CHANCE := 0.55
const CURVE_AMOUNT := 0.45
const SMOOTH_RADIUS := 10
const SMOOTH_PASSES := 3
const VEG_STEP := 7.0
const ROAD_WIDTHS := [12.0, 7.0]

enum RoadType { HIGHWAY, DIRT }
enum Surface { ASPHALT, DIRT, GRASS }

var world_seed: int = 0

var _continental: FastNoiseLite
var _hills: FastNoiseLite
var _detail: FastNoiseLite
var _biome: FastNoiseLite
var _edge_cache: Dictionary = {} ## Vector3i -> RoadEdge (только для основного потока)


func _init(seed_value: int = 0) -> void:
	world_seed = seed_value
	_continental = _make_noise(seed_value, 1.0 / 2200.0, 3)
	_hills = _make_noise(seed_value + 101, 1.0 / 420.0, 4)
	_detail = _make_noise(seed_value + 202, 1.0 / 45.0, 2)
	_biome = _make_noise(seed_value + 303, 1.0 / 1600.0, 2)


static func _make_noise(s: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = s
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM if octaves > 1 else FastNoiseLite.FRACTAL_NONE
	n.fractal_octaves = octaves
	return n


# --- Хэш и случайные числа -------------------------------------------------

static func hash4(a: int, b: int, c: int, d: int) -> int:
	var h: int = a * 374761393 + b * 668265263 + c * 1442695041 + d * 1274126177
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return h


func rand01(i: int, j: int, salt: int) -> float:
	return float(hash4(world_seed, i, j, salt) & 0xFFFFFF) / 16777216.0


# --- Рельеф и биомы ----------------------------------------------------------

## Доля «холмистого» биома 0..1.
func hills_weight(x: float, z: float) -> float:
	return smoothstep(0.08, 0.35, _biome.get_noise_2d(x, z))


## Доля леса 0..1 (между полями и холмами).
func forest_weight(x: float, z: float) -> float:
	var b := _biome.get_noise_2d(x, z)
	return smoothstep(-0.3, -0.08, b) * (1.0 - smoothstep(0.12, 0.35, b))


## Высота рельефа без учёта дорог.
func base_height(x: float, z: float) -> float:
	var c := _continental.get_noise_2d(x, z)
	var hw := hills_weight(x, z)
	var h := _hills.get_noise_2d(x, z)
	return 4.0 + c * 30.0 + h * (8.0 + 42.0 * hw) + _detail.get_noise_2d(x, z) * 1.2


# --- Дорожная сеть -----------------------------------------------------------

static func chunk_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / CHUNK_SIZE), floori(pos.z / CHUNK_SIZE))


static func cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(roundi(pos.x / CELL_SIZE), roundi(pos.z / CELL_SIZE))


func node_pos(cell: Vector2i) -> Vector2:
	return Vector2(
		cell.x * CELL_SIZE + (rand01(cell.x, cell.y, 1) * 2.0 - 1.0) * CELL_JITTER,
		cell.y * CELL_SIZE + (rand01(cell.x, cell.y, 2) * 2.0 - 1.0) * CELL_JITTER
	)


func node_height(cell: Vector2i) -> float:
	var p := node_pos(cell)
	return maxf(base_height(p.x, p.y), ROAD_MIN_Y)


func node_pos3(cell: Vector2i) -> Vector3:
	var p := node_pos(cell)
	return Vector3(p.x, node_height(cell), p.y)


func has_edge(cell: Vector2i, dir: int) -> bool:
	if cell == Vector2i.ZERO:
		return true # у стартового узла всегда есть дороги
	return rand01(cell.x, cell.y, 10 + dir) < EDGE_CHANCE


func edge_type(cell: Vector2i, dir: int) -> int:
	return RoadType.HIGHWAY if rand01(cell.x, cell.y, 20 + dir) < HIGHWAY_CHANCE else RoadType.DIRT


## Рёбра, выходящие из узла: массив [ключ ребра Vector3i, идём_от_начала bool].
func node_links(cell: Vector2i) -> Array:
	var out := []
	if has_edge(cell, 0):
		out.append([Vector3i(cell.x, cell.y, 0), true])
	if has_edge(cell, 1):
		out.append([Vector3i(cell.x, cell.y, 1), true])
	var w := cell - Vector2i(1, 0)
	if has_edge(w, 0):
		out.append([Vector3i(w.x, w.y, 0), false])
	var s := cell - Vector2i(0, 1)
	if has_edge(s, 1):
		out.append([Vector3i(s.x, s.y, 1), false])
	return out


func node_has_roads(cell: Vector2i) -> bool:
	return not node_links(cell).is_empty()


## Ребро по ключу с кэшем (кэш — только для основного потока).
func get_edge(key: Vector3i) -> RoadEdge:
	var e: RoadEdge = _edge_cache.get(key)
	if e == null:
		e = make_edge(Vector2i(key.x, key.y), key.z)
		_edge_cache[key] = e
		if _edge_cache.size() > 400:
			_edge_cache.erase(_edge_cache.keys()[0])
	return e


func make_edge(cell: Vector2i, dir: int) -> RoadEdge:
	var e := RoadEdge.new()
	e.cell = cell
	e.dir = dir
	e.b_cell = cell + (Vector2i(1, 0) if dir == 0 else Vector2i(0, 1))
	e.type = edge_type(cell, dir)
	e.width = ROAD_WIDTHS[e.type]

	var a := node_pos(cell)
	var b := node_pos(e.b_cell)
	var d := b - a
	var total_len := d.length()
	var perp := Vector2(-d.y, d.x) / total_len
	var c1 := a + d / 3.0 + perp * (rand01(cell.x, cell.y, 30 + dir) - 0.5) * CURVE_AMOUNT * total_len
	var c2 := a + d * (2.0 / 3.0) + perp * (rand01(cell.x, cell.y, 40 + dir) - 0.5) * CURVE_AMOUNT * total_len

	# Плотная выборка кривой, затем равномерная по длине.
	const DENSE := 200
	var dense := PackedVector2Array()
	var cum := PackedFloat32Array()
	var acc := 0.0
	for k in DENSE + 1:
		var p := _bezier(a, c1, c2, b, float(k) / DENSE)
		if k > 0:
			acc += p.distance_to(dense[k - 1])
		dense.append(p)
		cum.append(acc)
	var n := maxi(2, ceili(acc / ROAD_SAMPLE_M))
	var step := acc / n
	var flat := PackedVector2Array()
	var j := 0
	for k in n + 1:
		var s := minf(k * step, acc)
		while j < DENSE - 1 and cum[j + 1] < s:
			j += 1
		var seg := cum[j + 1] - cum[j]
		var t := (s - cum[j]) / seg if seg > 0.0001 else 0.0
		flat.append(dense[j].lerp(dense[j + 1], t))

	# Профиль высоты: рельеф → сглаживание → прибить концы к узлам.
	var h := PackedFloat32Array()
	h.resize(flat.size())
	for k in flat.size():
		h[k] = base_height(flat[k].x, flat[k].y)
	for _pass in SMOOTH_PASSES:
		h = _smooth(h, SMOOTH_RADIUS)
	var ha := node_height(cell)
	var hb := node_height(e.b_cell)
	var e0 := ha - h[0]
	var e1 := hb - h[h.size() - 1]
	var last := float(h.size() - 1)
	for k in h.size():
		h[k] = maxf(h[k] + lerpf(e0, e1, k / last), ROAD_MIN_Y)
	h[0] = ha
	h[h.size() - 1] = hb

	var minx := INF
	var minz := INF
	var maxx := -INF
	var maxz := -INF
	for k in flat.size():
		var p3 := Vector3(flat[k].x, h[k], flat[k].y)
		e.points.append(p3)
		e.dists.append(k * step)
		minx = minf(minx, p3.x)
		minz = minf(minz, p3.z)
		maxx = maxf(maxx, p3.x)
		maxz = maxf(maxz, p3.z)
	e.length = acc
	var pad := e.width * 0.5
	e.bbox = Rect2(minx - pad, minz - pad, maxx - minx + pad * 2.0, maxz - minz + pad * 2.0)
	return e


static func _bezier(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t)


static func _smooth(src: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(src.size())
	var n := src.size()
	for i in n:
		var sum := 0.0
		var cnt := 0
		for k in range(i - radius, i + radius + 1):
			sum += src[clampi(k, 0, n - 1)]
			cnt += 1
		out[i] = sum / cnt
	return out


## Ключи рёбер, чьи габариты (с запасом margin) пересекают прямоугольник.
func edge_keys_near(rect: Rect2, margin: float) -> Array[Vector3i]:
	var r := rect.grow(margin + CELL_JITTER + CELL_SIZE * CURVE_AMOUNT)
	var i0 := floori(r.position.x / CELL_SIZE) - 1
	var i1 := ceili(r.end.x / CELL_SIZE)
	var j0 := floori(r.position.y / CELL_SIZE) - 1
	var j1 := ceili(r.end.y / CELL_SIZE)
	var out: Array[Vector3i] = []
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			for dir in 2:
				var c := Vector2i(i, j)
				if has_edge(c, dir):
					var a := node_pos(c)
					var b := node_pos(c + (Vector2i(1, 0) if dir == 0 else Vector2i(0, 1)))
					var box := Rect2(a, Vector2.ZERO).expand(b).grow(CELL_SIZE * CURVE_AMOUNT * 0.5 + 20.0)
					if box.intersects(rect.grow(margin)):
						out.append(Vector3i(i, j, dir))
	return out


## Ближайшая точка дороги к pos: {edge, s, dist, pos, tangent} или пустой словарь.
func nearest_road(pos: Vector3, search_m: float = 600.0) -> Dictionary:
	var rect := Rect2(pos.x - search_m * 0.5, pos.z - search_m * 0.5, search_m, search_m)
	var best := {}
	var best_d := INF
	for key in edge_keys_near(rect, 0.0):
		var e := get_edge(key)
		if not e.bbox.grow(search_m * 0.5).has_point(Vector2(pos.x, pos.z)):
			continue
		var pr := e.project(pos)
		if pr.y < best_d:
			best_d = pr.y
			best = {"edge": e, "s": pr.x, "dist": pr.y, "pos": e.sample(pr.x), "tangent": e.tangent_at_distance(pr.x)}
	return best


# --- Данные чанка --------------------------------------------------------

## Считает всё для чанка: сетку рельефа, полотна дорог, площадки
## перекрёстков, растительность. Возвращает словарь только с данными.
func build_chunk_data(cc: Vector2i) -> Dictionary:
	var x0 := cc.x * CHUNK_SIZE
	var z0 := cc.y * CHUNK_SIZE
	var w := GRID_N + 3 # сетка с рамкой в 1 вершину для нормалей
	var count := w * w
	var hgt := PackedFloat32Array()
	hgt.resize(count)
	var infl := PackedFloat32Array()
	infl.resize(count)
	var road_y := PackedFloat32Array()
	road_y.resize(count)
	var edge_dist := PackedFloat32Array()
	edge_dist.resize(count)
	edge_dist.fill(1e6)

	for gz in w:
		for gx in w:
			var idx := gz * w + gx
			hgt[idx] = base_height(x0 + (gx - 1) * GRID_STEP, z0 + (gz - 1) * GRID_STEP)

	var chunk_rect := Rect2(x0, z0, CHUNK_SIZE, CHUNK_SIZE)
	var margin := ROAD_BLEND_M + 12.0
	var edges: Array[RoadEdge] = []
	for key in edge_keys_near(chunk_rect, margin):
		var e := make_edge(Vector2i(key.x, key.y), key.z)
		if e.bbox.grow(margin).intersects(chunk_rect):
			edges.append(e)

	# Влияние дорог на рельеф: штампуем отрезки по сетке.
	var gmin_x := x0 - GRID_STEP
	var gmin_z := z0 - GRID_STEP
	for e in edges:
		var hw := e.width * 0.5
		var core := hw + ROAD_SHOULDER_M
		var reach := core + ROAD_BLEND_M
		for k in e.points.size() - 1:
			var p0 := e.points[k]
			var p1 := e.points[k + 1]
			var ix0 := maxi(floori((minf(p0.x, p1.x) - reach - gmin_x) / GRID_STEP), 0)
			var ix1 := mini(ceili((maxf(p0.x, p1.x) + reach - gmin_x) / GRID_STEP), w - 1)
			var iz0 := maxi(floori((minf(p0.z, p1.z) - reach - gmin_z) / GRID_STEP), 0)
			var iz1 := mini(ceili((maxf(p0.z, p1.z) + reach - gmin_z) / GRID_STEP), w - 1)
			if ix0 > ix1 or iz0 > iz1:
				continue
			var sx := p1.x - p0.x
			var sz := p1.z - p0.z
			var l2 := maxf(sx * sx + sz * sz, 0.0001)
			for gz in range(iz0, iz1 + 1):
				var pz := gmin_z + gz * GRID_STEP
				for gx in range(ix0, ix1 + 1):
					var px := gmin_x + gx * GRID_STEP
					var t := clampf(((px - p0.x) * sx + (pz - p0.z) * sz) / l2, 0.0, 1.0)
					var dx := px - (p0.x + sx * t)
					var dz := pz - (p0.z + sz * t)
					var d := sqrt(dx * dx + dz * dz)
					if d >= reach:
						continue
					var idx := gz * w + gx
					edge_dist[idx] = minf(edge_dist[idx], d - hw)
					var wgt := 1.0 - smoothstep(core, reach, d)
					if wgt > infl[idx]:
						infl[idx] = wgt
						road_y[idx] = lerpf(p0.y, p1.y, t) - ROAD_SINK_M

	# Площадки перекрёстков.
	var pads := []
	var nodes := {}
	for e in edges:
		nodes[e.cell] = true
		nodes[e.b_cell] = true
	for cell: Vector2i in nodes:
		var np := node_pos(cell)
		var nh := node_height(cell)
		var types := {}
		for link in node_links(cell):
			types[edge_type(Vector2i(link[0].x, link[0].y), link[0].z)] = true
		var reach := PAD_RADIUS_M + ROAD_SHOULDER_M + ROAD_BLEND_M
		var ix0 := maxi(floori((np.x - reach - gmin_x) / GRID_STEP), 0)
		var ix1 := mini(ceili((np.x + reach - gmin_x) / GRID_STEP), w - 1)
		var iz0 := maxi(floori((np.y - reach - gmin_z) / GRID_STEP), 0)
		var iz1 := mini(ceili((np.y + reach - gmin_z) / GRID_STEP), w - 1)
		for gz in range(iz0, iz1 + 1):
			for gx in range(ix0, ix1 + 1):
				var d := Vector2(gmin_x + gx * GRID_STEP, gmin_z + gz * GRID_STEP).distance_to(np) - PAD_RADIUS_M
				if d >= ROAD_SHOULDER_M + ROAD_BLEND_M:
					continue
				var idx := gz * w + gx
				edge_dist[idx] = minf(edge_dist[idx], d)
				var wgt := 1.0 - smoothstep(ROAD_SHOULDER_M, ROAD_SHOULDER_M + ROAD_BLEND_M, d)
				if wgt > infl[idx]:
					infl[idx] = wgt
					road_y[idx] = nh - ROAD_SINK_M
		if chunk_rect.has_point(np):
			pads.append({
				"pos": Vector3(np.x - x0, nh + PAD_LIFT_M, np.y - z0),
				"highway": types.has(RoadType.HIGHWAY),
			})

	for i in count:
		if infl[i] > 0.0:
			hgt[i] = lerpf(hgt[i], road_y[i], infl[i])

	var data := {"coord": cc, "origin": Vector3(x0, 0.0, z0), "pads": pads}
	_build_terrain_arrays(data, hgt, edge_dist, w, x0, z0)
	data["roads"] = _build_road_arrays(edges, chunk_rect, x0, z0)
	data["vegetation"] = _build_vegetation(cc, hgt, edge_dist, w, x0, z0)
	return data


func _build_terrain_arrays(data: Dictionary, hgt: PackedFloat32Array, edge_dist: PackedFloat32Array,
		w: int, x0: float, z0: float) -> void:
	var n := GRID_N + 1
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(n * n)
	normals.resize(n * n)
	colors.resize(n * n)
	var min_h := INF
	var c_field := Color(0.45, 0.56, 0.24)
	var c_forest := Color(0.24, 0.37, 0.15)
	var c_hills := Color(0.40, 0.44, 0.27)
	var c_rock := Color(0.45, 0.43, 0.40)
	var c_sand := Color(0.70, 0.64, 0.48)
	var c_dirt := Color(0.40, 0.33, 0.24)
	var c_mud := Color(0.28, 0.25, 0.20)
	for gz in n:
		for gx in n:
			var idx := (gz + 1) * w + (gx + 1)
			var h := hgt[idx]
			min_h = minf(min_h, h)
			var wx := x0 + gx * GRID_STEP
			var wz := z0 + gz * GRID_STEP
			var nrm := Vector3(hgt[idx - 1] - hgt[idx + 1], 2.0 * GRID_STEP, hgt[idx - w] - hgt[idx + w]).normalized()
			var vi := gz * n + gx
			verts[vi] = Vector3(gx * GRID_STEP, h, gz * GRID_STEP)
			normals[vi] = nrm
			var fw := forest_weight(wx, wz)
			var hw := hills_weight(wx, wz)
			var col := c_field.lerp(c_forest, fw).lerp(c_hills, hw)
			col = col.lerp(c_rock, smoothstep(0.18, 0.4, 1.0 - nrm.y))
			col = col.lerp(c_dirt, 1.0 - smoothstep(0.5, 3.5, edge_dist[idx]))
			col = col.lerp(c_sand, 1.0 - smoothstep(WATER_LEVEL + 0.6, WATER_LEVEL + 1.8, h))
			col = col.lerp(c_mud, 1.0 - smoothstep(WATER_LEVEL - 3.0, WATER_LEVEL - 0.5, h))
			var jitter := (rand01(roundi(wx), roundi(wz), 7) - 0.5) * 0.06
			colors[vi] = Color(col.r + jitter, col.g + jitter, col.b + jitter * 0.5)
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	indices.resize(GRID_N * GRID_N * 6)
	faces.resize(GRID_N * GRID_N * 6)
	var k := 0
	for gz in GRID_N:
		for gx in GRID_N:
			var i00 := gz * n + gx
			var i10 := i00 + 1
			var i01 := i00 + n
			var i11 := i01 + 1
			var tri := [i00, i10, i01, i10, i11, i01]
			for t in 6:
				indices[k] = tri[t]
				faces[k] = verts[tri[t]]
				k += 1
	data["terrain"] = {"vertices": verts, "normals": normals, "colors": colors, "indices": indices, "faces": faces}
	data["water"] = min_h < WATER_LEVEL + 0.5


func _build_road_arrays(edges: Array[RoadEdge], rect: Rect2, x0: float, z0: float) -> Dictionary:
	var out := {}
	for road_type in [RoadType.HIGHWAY, RoadType.DIRT]:
		out[road_type] = {
			"vertices": PackedVector3Array(), "normals": PackedVector3Array(),
			"uvs": PackedVector2Array(), "indices": PackedInt32Array(), "faces": PackedVector3Array(),
		}
	var origin := Vector3(x0, 0.0, z0)
	var lift := Vector3(0.0, ROAD_LIFT_M, 0.0)
	var skirt := Vector3(0.0, -0.8, 0.0)
	for e in edges:
		var arr: Dictionary = out[e.type]
		var verts: PackedVector3Array = arr["vertices"]
		var normals: PackedVector3Array = arr["normals"]
		var uvs: PackedVector2Array = arr["uvs"]
		var indices: PackedInt32Array = arr["indices"]
		var faces: PackedVector3Array = arr["faces"]
		var hw := e.width * 0.5
		for k in e.points.size() - 1:
			var p0 := e.points[k]
			var p1 := e.points[k + 1]
			var mid := (p0 + p1) * 0.5
			if not rect.has_point(Vector2(mid.x, mid.z)):
				continue
			var t0 := e.tangent_at(k)
			var t1 := e.tangent_at(k + 1)
			var r0 := Vector3(-t0.z, 0.0, t0.x) * hw
			var r1 := Vector3(-t1.z, 0.0, t1.x) * hw
			var l0 := p0 - r0 - origin + lift
			var rr0 := p0 + r0 - origin + lift
			var l1 := p1 - r1 - origin + lift
			var rr1 := p1 + r1 - origin + lift
			var nrm := (l1 - l0).cross(rr0 - l0).normalized()
			if nrm.y < 0.0:
				nrm = -nrm
			var v0 := e.dists[k] / 10.0
			var v1 := e.dists[k + 1] / 10.0
			var base := verts.size()
			verts.append_array([l0, rr0, l1, rr1])
			normals.append_array([nrm, nrm, nrm, nrm])
			uvs.append_array([Vector2(0, v0), Vector2(1, v0), Vector2(0, v1), Vector2(1, v1)])
			indices.append_array([base, base + 2, base + 1, base + 1, base + 2, base + 3])
			faces.append_array([l0, l1, rr0, rr0, l1, rr1])
			# Боковые «юбки» закрывают щель между полотном и рельефом.
			var sb := verts.size()
			var ln := -r0.normalized()
			verts.append_array([l0, l1, l0 + skirt, l1 + skirt])
			normals.append_array([ln, ln, ln, ln])
			uvs.append_array([Vector2(0, v0), Vector2(0, v1), Vector2(0, v0), Vector2(0, v1)])
			indices.append_array([sb, sb + 2, sb + 1, sb + 1, sb + 2, sb + 3])
			var rb := verts.size()
			var rn := r0.normalized()
			verts.append_array([rr0, rr1, rr0 + skirt, rr1 + skirt])
			normals.append_array([rn, rn, rn, rn])
			uvs.append_array([Vector2(1, v0), Vector2(1, v1), Vector2(1, v0), Vector2(1, v1)])
			indices.append_array([rb, rb + 1, rb + 2, rb + 1, rb + 3, rb + 2])
	return out


## Высота рельефа в локальной точке чанка (билинейно по сетке).
static func _grid_sample(arr: PackedFloat32Array, w: int, lx: float, lz: float) -> float:
	var fx := lx / GRID_STEP + 1.0
	var fz := lz / GRID_STEP + 1.0
	var ix := clampi(floori(fx), 0, w - 2)
	var iz := clampi(floori(fz), 0, w - 2)
	var tx := fx - ix
	var tz := fz - iz
	var a := lerpf(arr[iz * w + ix], arr[iz * w + ix + 1], tx)
	var b := lerpf(arr[(iz + 1) * w + ix], arr[(iz + 1) * w + ix + 1], tx)
	return lerpf(a, b, tz)


func _build_vegetation(cc: Vector2i, hgt: PackedFloat32Array, edge_dist: PackedFloat32Array,
		w: int, x0: float, z0: float) -> Dictionary:
	var conifer: Array[Transform3D] = []
	var leafy: Array[Transform3D] = []
	var rocks: Array[Transform3D] = []
	var bushes: Array[Transform3D] = []
	var colliders := [] ## [локальная позиция Vector3, радиус float, высота float]
	var steps := int(CHUNK_SIZE / VEG_STEP)
	var base_i := cc.x * steps
	var base_j := cc.y * steps
	for j in steps:
		for i in steps:
			var gi := base_i + i
			var gj := base_j + j
			var lx := (i + 0.15 + rand01(gi, gj, 60) * 0.7) * VEG_STEP
			var lz := (j + 0.15 + rand01(gi, gj, 61) * 0.7) * VEG_STEP
			var wx := x0 + lx
			var wz := z0 + lz
			var h := _grid_sample(hgt, w, lx, lz)
			if h < WATER_LEVEL + 1.2:
				continue
			var ed := _grid_sample(edge_dist, w, lx, lz)
			if ed < 4.0:
				continue
			var slope := absf(_grid_sample(hgt, w, lx + 2.0, lz) - _grid_sample(hgt, w, lx - 2.0, lz)) / 4.0 \
				+ absf(_grid_sample(hgt, w, lx, lz + 2.0) - _grid_sample(hgt, w, lx, lz - 2.0)) / 4.0
			var fw := forest_weight(wx, wz)
			var hw := hills_weight(wx, wz)
			var tree_density := 0.025 + 0.5 * fw + 0.07 * hw
			var rock_density := 0.01 + 0.08 * hw
			var bush_density := 0.05 + 0.08 * fw
			var r := rand01(gi, gj, 50)
			var rot := rand01(gi, gj, 52) * TAU
			var scale := 0.75 + rand01(gi, gj, 53) * 0.6
			var basis := Basis(Vector3.UP, rot).scaled(Vector3.ONE * scale)
			var pos := Vector3(lx, h - 0.2, lz)
			if r < tree_density and slope < 0.7:
				if rand01(gi, gj, 51) < 0.25 + 0.6 * hw + 0.2 * fw:
					conifer.append(Transform3D(basis, pos))
				else:
					leafy.append(Transform3D(basis, pos))
				colliders.append([pos, 0.35 * scale, 6.0 * scale])
			elif r < tree_density + rock_density:
				var rs := 0.6 + rand01(gi, gj, 54) * 1.6
				var rb := Basis(Vector3(rand01(gi, gj, 55), 1.0, rand01(gi, gj, 56)).normalized(), rot)
				rocks.append(Transform3D(rb.scaled(Vector3(rs, rs * 0.7, rs)), pos))
				if rs > 1.0:
					colliders.append([pos, rs * 0.8, rs * 0.9])
			elif r < tree_density + rock_density + bush_density and slope < 0.8:
				bushes.append(Transform3D(basis, pos + Vector3(0, 0.1, 0)))
	return {"conifer": conifer, "leafy": leafy, "rocks": rocks, "bushes": bushes, "colliders": colliders}
