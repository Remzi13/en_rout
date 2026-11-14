class_name ChaseDirector
extends Node3D
## Случайные погони во время свободной езды. Через случайный интервал
## уличные гонщики (2–4) появляются позади игрока вне поля зрения и
## открывают охоту. Исход — по ChaseRules, очки — по ChaseScore.
## После результата преследователи уезжают и исчезают, езда продолжается.

signal state_changed(state: State)
signal chase_finished(outcome: int, score: int, place: int)
signal near_miss_scored

enum State { FREE, WARNING, ACTIVE, RESULT }

const RACER_STATS := preload("res://game/cars/stats/racer.tres")
const RACER_COLORS := [
	Color(0.1, 0.9, 0.4), Color(0.95, 0.1, 0.6), Color(0.2, 0.6, 1.0),
	Color(1.0, 0.85, 0.1), Color(0.65, 0.2, 1.0), Color(1.0, 0.3, 0.1),
]

@export var config: ChaseConfig = preload("res://game/chase/chase_config.tres")

var world: OpenWorld
var state: State = State.FREE
var pursuers: Array[ArcadeCar] = []
var rules: ChaseRules
var score: ChaseScore
var last_outcome: int = ChaseRules.Outcome.NONE
var last_score: int = 0
var last_place: int = 0
var event_size: int = 0
var timer: float = 0.0 ## до следующей погони / до конца фазы
var rng := RandomNumberGenerator.new()

var _leaving: Array[ArcadeCar] = []
var _music: AudioStreamPlayer


func setup(w: OpenWorld, seed_value: int) -> void:
	world = w
	rng.seed = seed_value
	rules = ChaseRules.new(config)
	score = ChaseScore.new(config)
	timer = rng.randf_range(config.min_interval_s, config.max_interval_s)
	_music = AudioStreamPlayer.new()
	_music.bus = &"Music"
	_music.stream = Synth.chase_music()
	_music.volume_db = -8.0
	add_child(_music)
	w.traffic.near_miss.connect(_on_near_miss)


func time_to_next() -> float:
	return timer if state == State.FREE else 0.0


## Немедленно начать погоню (клавиша «Вызвать погоню» или тесты).
func trigger_now() -> void:
	if state == State.FREE:
		timer = 0.0


func min_pursuer_distance() -> float:
	var best := INF
	for p in pursuers:
		if is_instance_valid(p):
			best = minf(best, p.global_position.distance_to(world.player.global_position))
	return best


func _physics_process(delta: float) -> void:
	if world == null or world.player == null:
		return
	_update_leaving()
	match state:
		State.FREE:
			timer -= delta
			if timer <= 0.0:
				_begin_warning()
		State.WARNING:
			timer -= delta
			if timer <= 0.0:
				_start_chase()
		State.ACTIVE:
			_tick_chase(delta)
		State.RESULT:
			timer -= delta
			if timer <= 0.0:
				_set_state(State.FREE)
				timer = rng.randf_range(config.min_interval_s, config.max_interval_s)


func _begin_warning() -> void:
	event_size = rng.randi_range(config.min_pursuers, config.max_pursuers)
	var skill := rng.randf_range(config.min_skill, config.max_skill)
	var behind := world.player.global_basis.z
	var spawned := 0
	for i in event_size:
		var spot := world.find_road_spawn(world.player.global_position, config.spawn_min_m, config.spawn_max_m,
			rng, true, behind)
		if spot.is_empty():
			spot = world.find_ground_spawn(world.player.global_position, config.spawn_min_m, config.spawn_max_m,
				rng, behind)
		if spot.is_empty():
			continue
		_spawn_pursuer(spot, skill, i)
		spawned += 1
	if spawned == 0:
		timer = 5.0 # не нашли места — попробуем чуть позже
		return
	event_size = spawned
	rules.reset()
	score = ChaseScore.new(config)
	timer = config.warning_s
	Synth.play(self, Synth.alert(), -4.0)
	_set_state(State.WARNING)


func _spawn_pursuer(spot: Dictionary, skill: float, index: int) -> void:
	var car := ArcadeCar.new()
	car.stats = RACER_STATS
	car.style = CarModel.Style.RACER
	car.body_color = RACER_COLORS[rng.randi() % RACER_COLORS.size()]
	car.name = "Racer%d" % index
	var drv := RacerDriver.new()
	drv.setup(world.player, skill * rng.randf_range(0.97, 1.03), rng.randi())
	car.driver = drv
	car.respawn_requested.connect(_on_pursuer_respawn)
	add_child(car)
	var pos: Vector3 = spot["pos"] + Vector3.UP * 1.0
	var to_player := world.player.global_position - pos
	to_player.y = 0.0
	var spread := Vector3(rng.randf_range(-4.0, 4.0), 0.0, rng.randf_range(-4.0, 4.0))
	car.place(Transform3D(Basis.looking_at(to_player.normalized(), Vector3.UP), pos + spread), 20.0)
	pursuers.append(car)


func _start_chase() -> void:
	_music.play()
	_set_state(State.ACTIVE)


func _tick_chase(delta: float) -> void:
	var p := world.player
	# Гонщики за пределами загруженного мира потерялись.
	for car: ArcadeCar in pursuers.duplicate():
		if not is_instance_valid(car) or not world.chunks.is_loaded_at(car.global_position):
			_drop_pursuer(car)
	score.tick(delta, p.get_speed_kmh(), p.drifting)
	var outcome := rules.update(delta, min_pursuer_distance(), p.get_speed_kmh())
	if outcome != ChaseRules.Outcome.NONE:
		_finish(outcome)


func _finish(outcome: int) -> void:
	last_outcome = outcome
	last_score = score.final_total(outcome, event_size)
	last_place = GameState.add_record({
		"score": last_score,
		"duration": snappedf(score.duration_s, 0.1),
		"result": "escaped" if outcome == ChaseRules.Outcome.ESCAPED else "caught",
		"pursuers": event_size,
		"near_misses": score.near_misses,
		"top_speed": int(score.top_speed_kmh),
		"seed": GameState.world_seed,
		"date": Time.get_datetime_string_from_system(false, true),
	})
	_music.stop()
	Synth.play(self, Synth.success() if outcome == ChaseRules.Outcome.ESCAPED else Synth.fail(), -2.0)
	# Преследователи уезжают: отключаем погоню и уводим их прочь.
	for car in pursuers:
		if is_instance_valid(car):
			car.driver = _LeaveDriver.new(world.player)
			_leaving.append(car)
	pursuers.clear()
	timer = config.result_s
	_set_state(State.RESULT)
	chase_finished.emit(outcome, last_score, last_place)


func _update_leaving() -> void:
	for car: ArcadeCar in _leaving.duplicate():
		if not is_instance_valid(car):
			_leaving.erase(car)
			continue
		var d := car.global_position.distance_to(world.player.global_position)
		var seen := world.camera != null and world.camera.is_position_in_frustum(car.global_position)
		if d > 250.0 or (d > 80.0 and not seen) or not world.chunks.is_loaded_at(car.global_position):
			_leaving.erase(car)
			car.queue_free()


func _on_pursuer_respawn(car: ArcadeCar) -> void:
	# Отставший гонщик, вылетевший с трассы, выбывает — иначе от погони не уйти.
	if car.global_position.distance_to(world.player.global_position) > config.escape_distance_m:
		_drop_pursuer(car)
		return
	# Перевернулся/утонул рядом — переставить позади игрока вне поля зрения.
	var behind := world.player.global_basis.z
	var spot := world.find_road_spawn(world.player.global_position, 90.0, 180.0, rng, true, behind)
	if spot.is_empty():
		spot = world.find_ground_spawn(world.player.global_position, 90.0, 180.0, rng, behind)
	if spot.is_empty():
		return
	var pos: Vector3 = spot["pos"] + Vector3.UP
	var to := world.player.global_position - pos
	to.y = 0.0
	car.place(Transform3D(Basis.looking_at(to.normalized(), Vector3.UP), pos), 15.0)


func _drop_pursuer(car: ArcadeCar) -> void:
	pursuers.erase(car)
	if is_instance_valid(car):
		car.queue_free()


func _on_near_miss(_car: ArcadeCar) -> void:
	if state == State.ACTIVE:
		score.add_near_miss()
		near_miss_scored.emit()
		Synth.play(self, Synth.whoosh(), -6.0)


func _set_state(s: State) -> void:
	state = s
	state_changed.emit(s)


func clear() -> void:
	for car in pursuers + _leaving:
		if is_instance_valid(car):
			car.queue_free()
	pursuers.clear()
	_leaving.clear()


## После погони: гонщик разворачивается и уезжает от игрока.
class _LeaveDriver extends RefCounted:
	var from: ArcadeCar

	func _init(player: ArcadeCar) -> void:
		from = player

	func update_input(car: ArcadeCar, c: ArcadeCar.CarControls, _delta: float) -> void:
		car.speed_scale = 0.8
		if not is_instance_valid(from):
			return
		var away := car.global_position - from.global_position
		away.y = 0.0
		c.steer = SteerUtil.steer_to(car, car.global_position + away.normalized() * 30.0)
		c.throttle = 0.8
