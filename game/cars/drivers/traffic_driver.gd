class_name TrafficDriver
extends RefCounted
## Гражданский водитель: едет по своей полосе вдоль рёбер дорожной сети,
## на узлах выбирает случайное продолжение, держит дистанцию и тормозит
## перед препятствием.

var world: RoadNetwork
var edge: RoadEdge
var forward: bool = true ## едем от начала ребра к концу
var s: float = 0.0 ## позиция вдоль ребра от его начала
var cruise_kmh: float = 80.0
var rng := RandomNumberGenerator.new()
var stuck_time: float = 0.0


func setup(w: RoadNetwork, e: RoadEdge, fwd: bool, start_s: float, seed_value: int) -> void:
	world = w
	edge = e
	forward = fwd
	s = start_s
	rng.seed = seed_value
	cruise_kmh = (rng.randf_range(70.0, 95.0) if e.is_highway() else rng.randf_range(40.0, 60.0))


func lane_offset() -> float:
	return 2.6 if edge.is_highway() else 1.6


## Точка на своей полосе на расстоянии ahead по ходу движения.
func lane_point(ahead: float) -> Vector3:
	var ss := s + ahead if forward else s - ahead
	var over := 0.0
	if ss > edge.length:
		over = ss - edge.length
	elif ss < 0.0:
		over = -ss
	var p := edge.sample(ss)
	var t := edge.tangent_at_distance(ss) * (1.0 if forward else -1.0)
	var right := Vector3(-t.z, 0.0, t.x)
	return p + right * lane_offset() + t * over


func heading() -> Vector3:
	return edge.tangent_at_distance(s) * (1.0 if forward else -1.0)


func update_input(car: ArcadeCar, c: ArcadeCar.CarControls, delta: float) -> void:
	var pr := edge.project(car.global_position, s, 30.0)
	s = pr.x
	var remaining := edge.length - s if forward else s
	if remaining < 6.0:
		_next_edge()
		pr = edge.project(car.global_position)
		s = pr.x

	var v := car.get_forward_speed()
	var look := 8.0 + absf(v) * 0.6
	var target := lane_point(look)
	c.steer = SteerUtil.steer_to(car, target, 1.4)

	# Скорость: медленнее в крутых поворотах и перед препятствием.
	var t_now := heading()
	var t_far := (lane_point(look + 25.0) - lane_point(look)).normalized()
	var bend := clampf(1.0 - t_now.dot(t_far), 0.0, 1.0)
	var target_mps := cruise_kmh / 3.6 * clampf(1.0 - bend * 3.0, 0.35, 1.0)
	var probe := SteerUtil.probe(car, 0.0, 12.0 + absf(v) * 1.2, ArcadeCar.LAYER_CARS | ArcadeCar.LAYER_WORLD)
	var dist: float = probe["dist"]
	if dist < INF:
		target_mps = minf(target_mps, maxf((dist - 6.0) * 0.6, 0.0))
	SteerUtil.hold_speed(car, c, target_mps)

	if target_mps > 3.0 and absf(v) < 1.0:
		stuck_time += delta
	else:
		stuck_time = maxf(stuck_time - delta, 0.0)


func _next_edge() -> void:
	var node := edge.b_node if forward else edge.a_node
	var options := []
	for link in world.links(node):
		if link[0] != edge.index:
			options.append(link)
	if options.is_empty():
		forward = not forward # тупик — разворот
		return
	var pick: Array = options[rng.randi() % options.size()]
	edge = world.get_edge(pick[0])
	forward = pick[1]
	s = 0.0 if forward else edge.length
	cruise_kmh = (rng.randf_range(70.0, 95.0) if edge.is_highway() else rng.randf_range(40.0, 60.0))
