class_name Radar
extends Control
## Мини-карта: дороги вокруг игрока (север карты — по курсу машины),
## красные маркеры преследователей (за краем — прижаты к ободу),
## серые точки трафика. Доставки и места (task_marks): цель активной
## доставки — жёлтый ромб, за краем — стрелка на ободе; точки взятия —
## песочные квадраты (за краем — прижаты к ободу); места в радиусе —
## голубой флажок (открытое) или «?» (неоткрытое).

const MARK_GOAL := "goal"
const MARK_PICKUP := "pickup"
const MARK_PLACE := "place"
const MARK_UNKNOWN := "unknown"
## Отступ меток за краем от обода, px.
const EDGE_INSET_PX := 12.0

@export var range_m: float = 350.0

var world: OpenWorld
## Источники меток; GameHud ставит из world, тест — свои. null — меток нет.
var places: PlaceTracker
var deliveries: Deliveries
var _edges: Array[RoadEdge] = []
var _refresh: float = 0.0
var _last_pos := Vector3(INF, 0.0, INF)


func _process(delta: float) -> void:
	_refresh -= delta
	if world != null and world.player != null:
		var p := world.player.global_position
		if p.distance_to(_last_pos) > 100.0 or _refresh <= 0.0:
			_last_pos = p
			_refresh = 2.0
			var rect := Rect2(p.x - range_m, p.z - range_m, range_m * 2.0, range_m * 2.0)
			_edges = world.roads.edges_near(rect.grow(100.0))
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
	_draw_tasks(c, task_marks(p, yaw, r))
	# Игрок — стрелка в центре.
	var tri := PackedVector2Array([c + Vector2(0, -9), c + Vector2(6, 7), c + Vector2(-6, 7)])
	draw_colored_polygon(tri, Color(1.0, 0.6, 0.1))
	draw_arc(c, r, 0.0, TAU, 64, Color(1, 1, 1, 0.35), 2.0, true)


## Метки мест и доставок: {kind, pos (px от центра радара), edge (прижата
## к ободу)}. Места — только в радиусе, цель и точки взятия — всегда.
## Порядок — порядок рисования: места, точки взятия, цель сверху.
func task_marks(center: Vector3, yaw: float, radius_px: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var k := radius_px / range_m
	var lim := radius_px - EDGE_INSET_PX
	if places != null:
		for pl in places.all_places():
			var q := _to_map(pl["position"], center, yaw, k)
			if q.length() <= lim:
				out.append({"kind": MARK_PLACE if pl["open"] else MARK_UNKNOWN, "pos": q, "edge": false})
	if deliveries != null:
		for s in deliveries.available_spots():
			out.append(_clamped(MARK_PICKUP, _to_map(s["position"], center, yaw, k), lim))
		if deliveries.has_target():
			out.append(_clamped(MARK_GOAL, _to_map(deliveries.target_position(), center, yaw, k), lim))
	return out


static func _clamped(kind: String, q: Vector2, lim: float) -> Dictionary:
	var edge := q.length() > lim
	return {"kind": kind, "pos": q.normalized() * lim if edge else q, "edge": edge}


func _draw_tasks(c: Vector2, marks: Array[Dictionary]) -> void:
	var font := ThemeDB.fallback_font
	var outline := Color(0.02, 0.03, 0.05, 0.9)
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 260.0)
	for m in marks:
		var q: Vector2 = m["pos"] + c
		var edge: bool = m["edge"]
		match m["kind"]:
			MARK_PLACE:
				# Флажок: древко и треугольник.
				var pole := PackedVector2Array([q + Vector2(-4, 8), q + Vector2(-4, -10)])
				var flag := PackedVector2Array([q + Vector2(-4, -10), q + Vector2(8, -5.5), q + Vector2(-4, -1)])
				draw_line(pole[0], pole[1], outline, 5.0)
				draw_colored_polygon(PackedVector2Array([flag[0] + Vector2(-1.5, -2), flag[1] + Vector2(3, 0), flag[2] + Vector2(-1.5, 2)]), outline)
				draw_line(pole[0], pole[1], UiTheme.PLACE, 2.5)
				draw_colored_polygon(flag, UiTheme.PLACE)
			MARK_UNKNOWN:
				draw_circle(q, 10.0, outline)
				draw_arc(q, 10.0, 0.0, TAU, 24, Color(UiTheme.PLACE, 0.85), 2.0, true)
				draw_string(font, q + Vector2(-10, 6.5), "?", HORIZONTAL_ALIGNMENT_CENTER, 20, 18, UiTheme.PLACE)
			MARK_PICKUP:
				var h := 5.0 if edge else 6.5
				var col := Color(UiTheme.PICKUP, 0.75) if edge else UiTheme.PICKUP
				draw_rect(Rect2(q - Vector2(h + 2.0, h + 2.0), Vector2(h + 2.0, h + 2.0) * 2.0), outline)
				draw_rect(Rect2(q - Vector2(h, h), Vector2(h, h) * 2.0), col)
			MARK_GOAL:
				if edge:
					# Стрелка на ободе остриём наружу — туда ехать.
					var dir := (m["pos"] as Vector2).normalized()
					var side := Vector2(-dir.y, dir.x)
					var tri := PackedVector2Array([q + dir * 8.0, q - dir * 9.0 + side * 10.0, q - dir * 9.0 - side * 10.0])
					var big := PackedVector2Array([q + dir * 11.0, q - dir * 11.5 + side * 13.0, q - dir * 11.5 - side * 13.0])
					draw_colored_polygon(big, outline)
					draw_colored_polygon(tri, UiTheme.GOAL)
				else:
					draw_arc(q, 13.0 + 6.0 * pulse, 0.0, TAU, 28, Color(UiTheme.GOAL, 0.8 * (1.0 - pulse)), 2.5, true)
					var d := 10.0
					draw_colored_polygon(PackedVector2Array([q + Vector2(0, -d - 3), q + Vector2(d + 3, 0), q + Vector2(0, d + 3), q + Vector2(-d - 3, 0)]), outline)
					draw_colored_polygon(PackedVector2Array([q + Vector2(0, -d), q + Vector2(d, 0), q + Vector2(0, d), q + Vector2(-d, 0)]), UiTheme.GOAL)


static func _to_map(world_pos: Vector3, center: Vector3, yaw: float, k: float) -> Vector2:
	var d := world_pos - center
	# Поворачиваем так, чтобы курс машины (-Z локально) смотрел вверх.
	var rotated := Vector3(d.x, 0, d.z).rotated(Vector3.UP, -yaw)
	return Vector2(rotated.x, rotated.z) * k
