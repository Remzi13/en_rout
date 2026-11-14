class_name RoadNetwork
extends RefCounted
## Граф дорог всего мира. В игре строится из WorldIndex (чанки при этом
## могут быть не загружены), в тестах и инструментах — из RoadPath сцены. Узел — точка, где
## сходятся концы участков (ближе WorldDefs.JOIN_DISTANCE_M). Используют
## трафик, респаун, поиск точек спавна и радар.

var edges: Array[RoadEdge] = []
var node_positions: PackedVector3Array = PackedVector3Array()
var _links: Array = [] ## узел -> Array [индекс ребра, идём_от_начала bool]


## Сеть по узлам RoadPath в сцене (сцена должна быть в дереве).
static func build(root: Node) -> RoadNetwork:
	var net := RoadNetwork.new()
	for path: RoadPath in root.find_children("*", "RoadPath", true, false):
		net._add_edge(path.sample_global_points(), path.road_type)
	return net


## Сеть по запечённому индексу мира.
static func from_index(idx: WorldIndex) -> RoadNetwork:
	var net := RoadNetwork.new()
	for i in idx.road_points.size():
		net._add_edge(idx.road_points[i], idx.road_types[i])
	return net


func _add_edge(pts: PackedVector3Array, road_type: int) -> void:
	if pts.size() < 2:
		return
	var e := RoadEdge.from_points(pts, road_type)
	e.index = edges.size()
	e.a_node = _node_at(pts[0])
	e.b_node = _node_at(pts[pts.size() - 1])
	edges.append(e)
	_links[e.a_node].append([e.index, true])
	_links[e.b_node].append([e.index, false])


func _node_at(p: Vector3) -> int:
	for i in node_positions.size():
		if node_positions[i].distance_to(p) < WorldDefs.JOIN_DISTANCE_M:
			return i
	node_positions.append(p)
	_links.append([])
	return node_positions.size() - 1


## Рёбра, выходящие из узла: массив [индекс ребра, идём_от_начала bool].
func links(node: int) -> Array:
	return _links[node]


func get_edge(index: int) -> RoadEdge:
	return edges[index]


func edges_near(rect: Rect2) -> Array[RoadEdge]:
	var out: Array[RoadEdge] = []
	for e in edges:
		if e.bbox.intersects(rect):
			out.append(e)
	return out


## Ближайшая точка дороги к pos: {edge, s, dist, pos, tangent} или пустой словарь.
func nearest_road(pos: Vector3, search_m: float = 600.0) -> Dictionary:
	var best := {}
	var best_d := INF
	for e in edges:
		if not e.bbox.grow(search_m * 0.5).has_point(Vector2(pos.x, pos.z)):
			continue
		var pr := e.project(pos)
		if pr.y < best_d:
			best_d = pr.y
			best = {"edge": e, "s": pr.x, "dist": pr.y, "pos": e.sample(pr.x), "tangent": e.tangent_at_distance(pr.x)}
	return best
