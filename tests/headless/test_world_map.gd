extends SceneTree
## Мир из сцен-чанков (запечён из art/map/map.blend): сцены всех чанков
## индекса на месте, рельеф стыкуется на границах,
## дороги связаны в одну сеть и гладко переходят через границы чанков,
## запечённый индекс мира (world_index.tres) совпадает со сценой.

const H := preload("res://tests/headless/helper.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	var idx := WorldIndex.load_baked()
	var total := idx.chunk_coords.size()
	var ok_scenes := 0
	for cc in idx.chunk_coords:
		if ResourceLoader.exists(WorldDefs.chunk_scene_path(cc)):
			ok_scenes += 1
	H.check("сцены всех чанков индекса на месте", total > 0 and ok_scenes == total, "%d из %d" % [ok_scenes, total])
	var wr := idx.world_rect()
	H.check("мир — прямоугольник из целых чанков", is_equal_approx(wr.get_area(), total * WorldDefs.CHUNK_SIZE * WorldDefs.CHUNK_SIZE),
		"%s, чанков %d" % [wr, total])

	var map := (load("res://game/world/world.tscn") as PackedScene).instantiate() as WorldMap
	root.add_child(map)
	await physics_frame
	var chunks := map.chunks()
	H.check("world.tscn содержит все чанки", chunks.size() == total, "%d" % chunks.size())
	var coords_ok := true
	for c in chunks:
		var expected := Vector3(c.coord.x, 0, c.coord.y) * WorldDefs.CHUNK_SIZE
		coords_ok = coords_ok and c.position.is_equal_approx(expected) \
			and c.scene_file_path == WorldDefs.chunk_scene_path(c.coord)
		var roads := c.find_children("*", "RoadPath", true, false)
		for r: RoadPath in roads:
			# Сгенерированное полотно не сохраняется в сцену (нет owner).
			coords_ok = coords_ok and r.get_child_count() == 2
	H.check("чанки стоят по своим координатам, полотно строится", coords_ok)

	# Стык рельефа: правый край чанка = левый край соседа.
	var by_coord := {}
	for c in chunks:
		by_coord[c.coord] = c
	var max_gap := 0.0
	for c in chunks:
		var right: WorldChunk = by_coord.get(c.coord + Vector2i(1, 0))
		if right == null:
			continue
		var va := _terrain_vertices(c)
		var vb := _terrain_vertices(right)
		var n := int(sqrt(va.size()))
		for gz in n:
			max_gap = maxf(max_gap, absf(va[gz * n + n - 1].y - vb[gz * n].y))
	H.check("рельеф стыкуется на границах чанков", max_gap < 0.001, "разрыв %.4f м" % max_gap)

	# Сеть: все участки достижимы из узла старта.
	var net := RoadNetwork.build(map)
	H.check("дорог больше 10 участков", net.edges.size() > 10, "%d" % net.edges.size())
	var start := net.nearest_road(map.start_transform().origin)
	H.check("старт рядом с дорогой", not start.is_empty() and float(start["dist"]) < 4.0,
		"%.1f м" % (float(start["dist"]) if not start.is_empty() else -1.0))
	var seen := {}
	var queue := [(start["edge"] as RoadEdge).a_node]
	while not queue.is_empty():
		var node: int = queue.pop_back()
		if seen.has(node):
			continue
		seen[node] = true
		for link in net.links(node):
			var e := net.get_edge(link[0])
			queue.append(e.b_node if link[1] else e.a_node)
	H.check("дорожная сеть связная", seen.size() == net.node_positions.size(),
		"%d из %d узлов" % [seen.size(), net.node_positions.size()])

	# Переход через границу чанка: в узлах степени 2 направление не ломается.
	var worst := 1.0
	var border_nodes := 0
	for node in net.node_positions.size():
		var ls := net.links(node)
		var np := net.node_positions[node]
		var cs := WorldDefs.CHUNK_SIZE
		var on_border := absf(np.x - roundf(np.x / cs) * cs) < 0.01 or absf(np.z - roundf(np.z / cs) * cs) < 0.01
		if ls.size() != 2 or not on_border:
			continue
		border_nodes += 1
		var d := []
		for link in ls:
			var e := net.get_edge(link[0])
			d.append(e.tangent_at_distance(0.5) if link[1] else -e.tangent_at_distance(e.length - 0.5))
		worst = minf(worst, -(d[0] as Vector3).dot(d[1]))
	H.info("узлов на границах чанков: %d" % border_nodes)
	H.check("дорога гладко переходит через границу чанка", worst > 0.97, "мин. cos %.3f" % worst)

	var max_grade := 0.0
	for e in net.edges:
		for k in e.points.size() - 1:
			var p := e.points[k]
			var q := e.points[k + 1]
			max_grade = maxf(max_grade, absf(q.y - p.y) / maxf(Vector2(q.x - p.x, q.z - p.z).length(), 0.01))
	H.check("дороги проходимы (уклон < 35%)", max_grade < 0.35, "%.1f%%" % (max_grade * 100.0))

	# Индекс мира: игра берёт старт и дороги из него, а не из сцены.
	var fresh := WorldIndex.from_map(map)
	var same_chunks := idx.chunk_coords.size() == fresh.chunk_coords.size()
	for c in fresh.chunk_coords:
		same_chunks = same_chunks and idx.has_chunk(c)
	var same_roads := idx.road_points.size() == fresh.road_points.size()
	if same_roads:
		for i in fresh.road_points.size():
			var a: PackedVector3Array = idx.road_points[i]
			var b: PackedVector3Array = fresh.road_points[i]
			same_roads = same_roads and idx.road_types[i] == fresh.road_types[i] and a.size() == b.size()
			if same_roads:
				for k in a.size():
					same_roads = same_roads and a[k].distance_to(b[k]) < 0.01
	var same_start := idx.start_transform.is_equal_approx(fresh.start_transform)
	H.check("индекс мира совпадает со сценой", same_chunks and same_roads and same_start,
		"чанки %s, дороги %s, старт %s — пересоберите карту: tools/export_map.sh" % [same_chunks, same_roads, same_start])
	var net_idx := RoadNetwork.from_index(idx)
	H.check("сеть из индекса = сеть из сцены", net_idx.edges.size() == net.edges.size()
		and net_idx.node_positions.size() == net.node_positions.size(),
		"участков %d/%d, узлов %d/%d" % [net_idx.edges.size(), net.edges.size(), net_idx.node_positions.size(), net.node_positions.size()])

	map.queue_free()
	await physics_frame
	H.finish(self)


func _terrain_vertices(c: WorldChunk) -> PackedVector3Array:
	var mi := c.get_node("Terrain") as MeshInstance3D
	return mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
