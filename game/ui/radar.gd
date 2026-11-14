class_name Radar
extends Control
## Мини-карта: дороги вокруг игрока (север карты — по курсу машины),
## красные маркеры преследователей (за краем — прижаты к ободу),
## серые точки трафика.

@export var range_m: float = 350.0

var world: OpenWorld
var _edges: Array[RoadEdge] = []
var _refresh: float = 0.0
var _last_cell := Vector2i(999999, 999999)


func _process(delta: float) -> void:
	_refresh -= delta
	if world != null and world.player != null:
		var cell := WorldGen.cell_of(world.player.global_position)
		if cell != _last_cell or _refresh <= 0.0:
			_last_cell = cell
			_refresh = 2.0
			_edges.clear()
			var p := world.player.global_position
			var rect := Rect2(p.x - range_m, p.z - range_m, range_m * 2.0, range_m * 2.0)
			for key in world.gen.edge_keys_near(rect, 100.0):
				_edges.append(world.gen.get_edge(key))
	queue_redraw()


func _draw() -> void:
	var r := size.x * 0.5
	var c := size * 0.5
	draw_circle(c, r, Color(0.05, 0.07, 0.09, 0.72))
	if world == null or world.player == null:
		return
	var p := world.player.global_position
	var yaw := world.player.global_rotation.y
	var k := r / range_m
	for e in _edges:
		var col := Color(0.85, 0.85, 0.8, 0.85) if e.is_highway() else Color(0.7, 0.58, 0.4, 0.75)
		var width := 3.0 if e.is_highway() else 2.0
		var prev := Vector2.ZERO
		var prev_in := false
		for i in range(0, e.points.size(), 3):
			var q := _to_map(e.points[i], p, yaw, k) + c
			var inside := q.distance_to(c) < r - 2.0
			if i > 0 and inside and prev_in:
				draw_line(prev, q, col, width, true)
			prev = q
			prev_in = inside
	for car in world.traffic.cars:
		var q := _to_map(car.global_position, p, yaw, k) + c
		if q.distance_to(c) < r - 3.0:
			draw_circle(q, 2.5, Color(0.75, 0.75, 0.78))
	for car in world.chase.pursuers:
		if not is_instance_valid(car):
			continue
		var q := _to_map(car.global_position, p, yaw, k)
		var on_edge := q.length() > r - 7.0
		if on_edge:
			q = q.normalized() * (r - 7.0)
		draw_circle(q + c, 5.5 if on_edge else 4.5, Color(1.0, 0.15, 0.15))
	# Игрок — стрелка в центре.
	var tri := PackedVector2Array([c + Vector2(0, -9), c + Vector2(6, 7), c + Vector2(-6, 7)])
	draw_colored_polygon(tri, Color(1.0, 0.6, 0.1))
	draw_arc(c, r, 0.0, TAU, 64, Color(1, 1, 1, 0.35), 2.0, true)


static func _to_map(world_pos: Vector3, center: Vector3, yaw: float, k: float) -> Vector2:
	var d := world_pos - center
	# Поворачиваем так, чтобы курс машины (-Z локально) смотрел вверх.
	var rotated := Vector3(d.x, 0, d.z).rotated(Vector3.UP, -yaw)
	return Vector2(rotated.x, rotated.z) * k
