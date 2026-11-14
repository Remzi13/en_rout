extends SceneTree
## Запекает мир 5×5 чанков из генератора в редактируемые сцены:
##   game/world/assets/        — материалы и меши (общие для всех чанков);
##   game/world/chunks/        — chunk_X_Z.tscn + меш и форма рельефа (*.res);
##   game/world/world.tscn     — все чанки, точка старта, стены по краю.
## Запуск (ПЕРЕЗАПИСЫВАЕТ чанки, ручные правки пропадут):
##   godot --headless --path . --import
##   godot --path . -s res://tools/bake_world.gd [-- --seed=42]
## Без --headless: в headless-режиме MultiMesh не отдаёт данные и
## растительность сохранится пустой.

const WorldGen := preload("res://tools/world_gen.gd")
const MaterialBuilder := preload("res://tools/material_builder.gd")
const ASSETS := "res://game/world/assets/"
const CHUNKS := "res://game/world/chunks/"
const WORLD_SCENE := "res://game/world/world.tscn"
const CONTROL_EVERY := 5 ## каждая 5-я точка оси (~20 м) — точка кривой
const ROAD_MARGIN_M := 160.0 ## дороги не ближе к краю мира (там горы)

var _assets: Dictionary = {}


func _initialize() -> void:
	var seed_value := 42
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed_value = int(a.trim_prefix("--seed="))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ASSETS))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CHUNKS))
	_bake_assets()

	var gen := WorldGen.new(seed_value)
	gen.bounds = WorldDefs.world_rect()
	gen.allowed_edges = _pick_edges(gen)
	print("дорог в мире: %d" % gen.allowed_edges.size())

	var pieces := _split_roads(gen) ## Vector2i -> Array[{points, type, uv}]
	for cz in WorldDefs.CHUNKS_Z:
		for cx in WorldDefs.CHUNKS_X:
			var cc := WorldDefs.CHUNK_MIN + Vector2i(cx, cz)
			_bake_chunk(gen, cc, pieces.get(cc, []))
			print("чанк %s готов" % cc)
	_bake_world(gen)
	print("мир сохранён: %s" % WORLD_SCENE)
	quit(0)


# --- Ресурсы ------------------------------------------------------------------

func _save(res: Resource, file: String) -> Resource:
	var path := ASSETS + file
	var err := ResourceSaver.save(res, path, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
	assert(err == OK, "не удалось сохранить %s" % path)
	res.take_over_path(path)
	return res


func _bake_assets() -> void:
	var mb := MaterialBuilder.new()
	_assets["terrain"] = _save(mb.terrain, "terrain.res")
	_assets["highway"] = _save(mb.highway, "highway.res")
	_assets["asphalt_plain"] = _save(mb.asphalt_plain, "asphalt_plain.res")
	_assets["dirt_road"] = _save(mb.dirt_road, "dirt_road.res")
	_assets["water"] = _save(mb.water, "water.tres")
	_assets["water_plane"] = _save(mb.water_mesh, "water_plane.tres")
	_assets["rock"] = _save(mb.rock_mesh, "rock.tres")
	_assets["bush"] = _save(mb.bush_mesh, "bush.tres")


# --- Дорожная сеть -------------------------------------------------------------

## Рёбра генератора внутри мира, только связная часть со стартовым узлом.
func _pick_edges(gen: WorldGen) -> Dictionary:
	var inner := WorldDefs.world_rect().grow(-ROAD_MARGIN_M)
	var cand := {}
	var i0 := floori(inner.position.x / WorldGen.CELL_SIZE) - 1
	var i1 := ceili(inner.end.x / WorldGen.CELL_SIZE) + 1
	var j0 := floori(inner.position.y / WorldGen.CELL_SIZE) - 1
	var j1 := ceili(inner.end.y / WorldGen.CELL_SIZE) + 1
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			for dir in 2:
				var c := Vector2i(i, j)
				if not gen.has_edge(c, dir):
					continue
				var e := gen.make_edge(c, dir)
				var box := e.bbox
				if inner.encloses(box):
					cand[Vector3i(i, j, dir)] = true
	# Связная компонента, содержащая узел (0,0).
	var keep := {}
	var seen := {Vector2i.ZERO: true}
	var queue: Array[Vector2i] = [Vector2i.ZERO]
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_back()
		for key: Vector3i in cand:
			var a := Vector2i(key.x, key.y)
			var b := a + (Vector2i(1, 0) if key.z == 0 else Vector2i(0, 1))
			if a != cell and b != cell:
				continue
			keep[key] = true
			var other := b if a == cell else a
			if not seen.has(other):
				seen[other] = true
				queue.append(other)
	return keep


## Режет каждую дорогу по границам чанков. Результат: чанк -> куски
## {points (глобальные), tangents, type, uv}.
func _split_roads(gen: WorldGen) -> Dictionary:
	var out := {}
	for key: Vector3i in gen.allowed_edges:
		var e := gen.make_edge(Vector2i(key.x, key.y), key.z)
		var pts := _insert_border_points(e.points)
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
				out[ck].append({
					"points": pts.slice(start, k + 1),
					"tangents": tangents.slice(start, k + 1),
					"type": e.type,
					"uv": dists[start],
				})
				start = k
	return out


## Вставляет точки пересечения с границами чанков (x или z кратны CHUNK_SIZE).
func _insert_border_points(src: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array([src[0]])
	var cs := WorldDefs.CHUNK_SIZE
	for k in range(1, src.size()):
		var a := src[k - 1]
		var b := src[k]
		var ts: Array[float] = []
		for axis in [0, 2]:
			var va: float = a[axis]
			var vb: float = b[axis]
			var lo := minf(va, vb)
			var hi := maxf(va, vb)
			var line := ceilf(lo / cs) * cs
			while line < hi:
				if line > lo:
					ts.append((line - va) / (vb - va))
				line += cs
		ts.sort()
		for t in ts:
			if t > 0.02 and t < 0.98:
				out.append(a.lerp(b, t))
		out.append(b)
	return out


func _make_curve(pts: PackedVector3Array, tangents: PackedVector3Array, origin: Vector3) -> Curve3D:
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


# --- Чанк ----------------------------------------------------------------------

func _bake_chunk(gen: WorldGen, cc: Vector2i, pieces: Array) -> void:
	var data := gen.build_chunk_data(cc)
	var origin: Vector3 = data["origin"]
	var base := "chunk_%d_%d" % [cc.x, cc.y]

	var root := WorldChunk.new()
	root.name = "Chunk_%d_%d" % [cc.x, cc.y]
	root.coord = cc

	# Рельеф: меш и форма — отдельными файлами рядом со сценой.
	var t: Dictionary = data["terrain"]
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = t["vertices"]
	a[Mesh.ARRAY_NORMAL] = t["normals"]
	a[Mesh.ARRAY_COLOR] = t["colors"]
	a[Mesh.ARRAY_INDEX] = t["indices"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	mesh.surface_set_material(0, _assets["terrain"])
	ResourceSaver.save(mesh, CHUNKS + base + "_terrain.res", ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
	mesh.take_over_path(CHUNKS + base + "_terrain.res")
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(t["faces"])
	shape.backface_collision = true
	ResourceSaver.save(shape, CHUNKS + base + "_terrain_shape.res", ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
	shape.take_over_path(CHUNKS + base + "_terrain_shape.res")

	var terrain := MeshInstance3D.new()
	terrain.name = "Terrain"
	terrain.mesh = mesh
	root.add_child(terrain)
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = WorldDefs.LAYER_WORLD
	body.collision_mask = 0
	body.set_meta("surface", WorldDefs.Surface.GRASS)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)

	if data["water"]:
		var water := MeshInstance3D.new()
		water.name = "Water"
		water.mesh = _assets["water_plane"]
		water.position.y = WorldDefs.WATER_LEVEL
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(water)

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
		rp.curve = _make_curve(piece["points"], piece["tangents"], origin)
		roads.add_child(rp)

	var junctions := Node3D.new()
	junctions.name = "Junctions"
	root.add_child(junctions)
	n = 0
	for pad in data["pads"]:
		var j := RoadJunction.new()
		j.name = "Junction%d" % n
		n += 1
		j.highway = pad["highway"]
		j.position = pad["pos"]
		junctions.add_child(j)

	var veg_root := Node3D.new()
	veg_root.name = "Vegetation"
	root.add_child(veg_root)
	var veg: Dictionary = data["vegetation"]
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

	_set_owner(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, WorldDefs.chunk_scene_path(cc))
	assert(err == OK)
	root.free()


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

func _bake_world(gen: WorldGen) -> void:
	var root := WorldMap.new()
	root.name = "World"
	for cz in WorldDefs.CHUNKS_Z:
		for cx in WorldDefs.CHUNKS_X:
			var cc := WorldDefs.CHUNK_MIN + Vector2i(cx, cz)
			var ps: PackedScene = ResourceLoader.load(WorldDefs.chunk_scene_path(cc), "", ResourceLoader.CACHE_MODE_REPLACE)
			var inst := ps.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
			inst.position = Vector3(cc.x * WorldDefs.CHUNK_SIZE, 0.0, cc.y * WorldDefs.CHUNK_SIZE)
			root.add_child(inst)

	# Старт: правая полоса первой дороги стартового узла, ~60 м от узла.
	var start_key := Vector3i(0, 0, 0)
	if not gen.allowed_edges.has(start_key):
		start_key = gen.allowed_edges.keys()[0]
	var e := gen.make_edge(Vector2i(start_key.x, start_key.y), start_key.z)
	var k := mini(15, e.points.size() - 2)
	var p := e.points[k]
	var fwd := e.points[k + 1] - p
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var start := Marker3D.new()
	start.name = "PlayerStart"
	start.transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), p + right * 2.6 + Vector3.UP * 1.2)
	root.add_child(start)

	# Невидимые стены по краю мира.
	var bounds := StaticBody3D.new()
	bounds.name = "Bounds"
	bounds.collision_layer = WorldDefs.LAYER_WORLD
	bounds.collision_mask = 0
	root.add_child(bounds)
	var r := WorldDefs.world_rect()
	var c := r.get_center()
	const T := 20.0
	const H := 400.0
	var walls := [
		[Vector3(r.position.x - T * 0.5, 0, c.y), Vector3(T, H, r.size.y + T * 2.0)],
		[Vector3(r.end.x + T * 0.5, 0, c.y), Vector3(T, H, r.size.y + T * 2.0)],
		[Vector3(c.x, 0, r.position.y - T * 0.5), Vector3(r.size.x + T * 2.0, H, T)],
		[Vector3(c.x, 0, r.end.y + T * 0.5), Vector3(r.size.x + T * 2.0, H, T)],
	]
	for i in walls.size():
		var box := BoxShape3D.new()
		box.size = walls[i][1]
		var wcs := CollisionShape3D.new()
		wcs.name = "Wall%d" % i
		wcs.shape = box
		wcs.position = walls[i][0]
		bounds.add_child(wcs)

	_set_owner(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, WORLD_SCENE)
	assert(err == OK)
	root.free()
