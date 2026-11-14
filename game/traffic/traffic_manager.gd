class_name TrafficManager
extends Node3D
## Гражданский трафик: держит до max_cars машин на дорогах вокруг игрока.
## Появляются вне поля зрения на загруженных чанках, исчезают далеко
## позади или если застряли. Сообщает об опасных пролётах игрока мимо них.

signal near_miss(car: ArcadeCar)

const STATS := preload("res://game/cars/stats/traffic.tres")
const COLORS := [
	Color(0.85, 0.85, 0.86), Color(0.12, 0.12, 0.14), Color(0.55, 0.08, 0.08),
	Color(0.15, 0.25, 0.5), Color(0.45, 0.47, 0.5), Color(0.8, 0.7, 0.45), Color(0.2, 0.35, 0.25),
]

@export_range(0, 30) var max_cars: int = 12
@export_range(50.0, 400.0) var spawn_min_m: float = 140.0
@export_range(100.0, 600.0) var spawn_max_m: float = 380.0
@export_range(200.0, 900.0) var despawn_m: float = 480.0
@export var near_miss_distance_m: float = 3.6
@export var near_miss_min_kmh: float = 60.0

var world: OpenWorld
var cars: Array[ArcadeCar] = []
var rng := RandomNumberGenerator.new()
var _spawn_timer: float = 0.0
var _counter: int = 0


func setup(w: OpenWorld, seed_value: int) -> void:
	world = w
	rng.seed = seed_value


func _physics_process(delta: float) -> void:
	if world == null or world.player == null:
		return
	var player := world.player
	var ppos := player.global_position
	for car: ArcadeCar in cars.duplicate():
		var d := car.global_position.distance_to(ppos)
		var drv := car.driver as TrafficDriver
		var stuck := drv != null and drv.stuck_time > 8.0 and d > 60.0
		if d > despawn_m or stuck or car.global_position.y < WorldGen.WATER_LEVEL - 20.0 \
				or not world.chunks.is_loaded_at(car.global_position):
			_remove(car)
			continue
		_check_near_miss(car, player, d)

	_spawn_timer -= delta
	if _spawn_timer <= 0.0 and cars.size() < max_cars:
		_spawn_timer = 0.4
		_try_spawn()


func _check_near_miss(car: ArcadeCar, player: ArcadeCar, d: float) -> void:
	var cool: float = car.get_meta("nm_cool", 0.0)
	if cool > 0.0:
		car.set_meta("nm_cool", cool - get_physics_process_delta_time())
		return
	if player.get_colliding_bodies().has(car):
		car.set_meta("nm_cool", 3.0) # столкновение — не «пролёт»
		return
	if d < near_miss_distance_m + player.stats.body_size.x and player.get_speed_kmh() > near_miss_min_kmh:
		var rel := (player.linear_velocity - car.linear_velocity).length() * 3.6
		if rel > 40.0:
			car.set_meta("nm_cool", 3.0)
			near_miss.emit(car)


func _try_spawn() -> void:
	var cam := world.camera
	var spot := world.find_road_spawn(world.player.global_position, spawn_min_m, spawn_max_m, rng, true)
	if spot.is_empty():
		return
	var pos: Vector3 = spot["pos"]
	# Не появляться на глазах у игрока.
	if cam != null:
		var to := pos - cam.global_position
		if to.length() < 260.0 and (-cam.global_basis.z).dot(to.normalized()) > 0.3:
			return
	for other in cars:
		if other.global_position.distance_to(pos) < 25.0:
			return
	var car := ArcadeCar.new()
	car.stats = STATS
	car.style = CarModel.Style.VAN if rng.randf() < 0.2 else CarModel.Style.SEDAN
	if car.style == CarModel.Style.VAN:
		var van_stats := STATS.duplicate() as CarStats
		van_stats.body_size = Vector3(2.0, 2.0, 4.8)
		van_stats.mass_kg = 1900.0
		van_stats.max_speed_kmh = 105.0
		car.stats = van_stats
	car.body_color = COLORS[rng.randi() % COLORS.size()]
	car.name = "Traffic%d" % _counter
	_counter += 1
	var drv := TrafficDriver.new()
	drv.setup(world.gen, spot["edge"], spot["forward"], spot["s"], rng.randi())
	car.driver = drv
	car.auto_respawn = false
	add_child(car)
	var lane := drv.lane_point(0.0)
	lane.y = world.ground_height(lane, pos.y) + 1.0
	var fwd := drv.heading()
	car.place(Transform3D(Basis.looking_at(fwd, Vector3.UP), lane), drv.cruise_kmh / 3.6 * 0.8)
	cars.append(car)


func _remove(car: ArcadeCar) -> void:
	cars.erase(car)
	car.queue_free()


func clear() -> void:
	for car in cars:
		car.queue_free()
	cars.clear()
