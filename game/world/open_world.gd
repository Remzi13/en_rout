class_name OpenWorld
extends Node3D
## Игровая сессия в открытом мире: окружение и свет, мир из сцен-чанков
## (подгружаются вокруг игрока, см. ChunkStreamer), машина игрока, камера,
## трафик, погони, сутки и погода, HUD, бортовой журнал (journal) и счётчик
## поездки (trip_stats). Создаётся из main.gd через
## OpenWorld.create(seed); готовность — сигнал ready_to_play (стартовые чанки
## грузятся несколько кадров). Сид влияет на трафик, погони и погоду, сам
## мир — фиксированный.

signal ready_to_play
signal pause_requested

const PLAYER_STATS := preload("res://game/cars/stats/player.tres")
## Чанки ближе этого к старту грузятся до начала игры, остальные — потом в фоне.
const INITIAL_LOAD_RADIUS_M := 320.0

var world_seed: int = 0
var materials: WorldMaterials
var map: ChunkStreamer
var roads: RoadNetwork
var player: ArcadeCar
var camera: FollowCamera
var traffic: TrafficManager
var chase: ChaseDirector
var day_night: DayNight
var weather: Weather
var hud: GameHud
## Бортовой журнал игрока; грузится из journal_path при входе в мир.
var journal: Journal
var trip_stats: TripStats
## Путь сохранения журнала (тесты подставляют свой до add_child).
var journal_path: String = Journal.PATH
var env: Environment
var sun: DirectionalLight3D
var sky_mat: ProceduralSkyMaterial
var player_driver := HumanDriver.new()
var loading: bool = true

var _last_pos := Vector3.ZERO
var _respawn_cooldown: float = 0.0


static func create(seed_value: int) -> OpenWorld:
	var w := OpenWorld.new()
	w.world_seed = seed_value
	w.name = "OpenWorld"
	return w


func _ready() -> void:
	GameState.world_seed = world_seed
	GameState.weather_grip = 1.0
	journal = Journal.load_or_new(journal_path)
	materials = WorldMaterials.shared()
	_build_environment()

	# Без видеокарты главный расход — треугольники деревьев: рисуем их ближе.
	VegetationLayer.distance_scale = 0.5 if is_software_renderer() else 1.0
	var index := WorldIndex.load_baked()
	map = ChunkStreamer.create(index)
	add_child(map)
	roads = RoadNetwork.from_index(index)
	var spawn := map.start_transform()
	await map.load_initial(spawn.origin, INITIAL_LOAD_RADIUS_M)

	player = ArcadeCar.new()
	player.name = "Player"
	player.stats = PLAYER_STATS
	player.style = CarModel.Style.SPORT
	player.body_color = Color(0.95, 0.42, 0.06)
	player.driver = player_driver
	player.respawn_requested.connect(func(_c: ArcadeCar) -> void: respawn_player())
	add_child(player)
	player.place(spawn)
	map.target = player
	_last_pos = player.global_position

	camera = FollowCamera.new()
	camera.name = "Camera"
	camera.target = player
	add_child(camera)
	camera.current = true
	player.impacted.connect(_on_player_impact)

	day_night = DayNight.new()
	day_night.name = "DayNight"
	add_child(day_night)
	day_night.setup(sun, env, sky_mat)

	weather = Weather.new()
	weather.name = "Weather"
	add_child(weather)
	weather.setup(day_night, materials, camera, world_seed + 5)

	trip_stats = TripStats.new()
	trip_stats.name = "TripStats"
	trip_stats.setup(journal, player, weather, day_night)
	add_child(trip_stats)

	traffic = TrafficManager.new()
	traffic.name = "Traffic"
	traffic.setup(self, world_seed + 7)
	add_child(traffic)

	chase = ChaseDirector.new()
	chase.name = "Chase"
	add_child(chase)
	chase.setup(self, world_seed + 9)

	hud = GameHud.new()
	hud.name = "GameHud"
	add_child(hud)
	hud.setup(self)

	GameState.settings_changed.connect(apply_quality)
	apply_quality()
	loading = false
	ready_to_play.emit()


func _build_environment() -> void:
	var lighting := build_lighting(self)
	env = lighting["env"]
	sun = lighting["sun"]
	sky_mat = lighting["sky"]


## Небо, окружение и солнце мира; добавляет их в parent. Цвета и положение
## солнца потом ведёт DayNight. Возвращает {env, sun, sky}.
static func build_lighting(parent: Node) -> Dictionary:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sun_curve = 0.1
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_density = 0.0012
	env.fog_sky_affect = 0.6
	env.fog_aerial_perspective = 0.4
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.2
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.05
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 160.0
	sun.shadow_bias = 0.05
	sun.shadow_blur = 1.5
	parent.add_child(sun)
	return {"env": env, "sun": sun, "sky": sky_mat}


## Настройки качества и дальности (применяются и из меню паузы).
func apply_quality() -> void:
	var q := GameState.quality
	# Без видеокарты (виртуальная машина) каждый пиксель считает процессор:
	# тени, MSAA и полное разрешение дают меньше кадра в секунду.
	var software := is_software_renderer()
	if software:
		q = 0
	get_viewport().scaling_3d_scale = 0.5 if software else 1.0
	sun.shadow_enabled = q >= 1
	sun.directional_shadow_max_distance = [80.0, 160.0, 260.0][q]
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if q < 2 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	env.glow_enabled = q >= 1
	var forward_plus := RenderingServer.get_current_rendering_method() == "forward_plus"
	env.ssao_enabled = forward_plus and q >= 1
	env.ssil_enabled = forward_plus and q >= 2
	env.sdfgi_enabled = false
	get_viewport().msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][q]
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED if q >= 1 or software else Viewport.SCREEN_SPACE_AA_FXAA
	camera.far = 300.0 + GameState.draw_distance * 300.0
	# Всё, что видит камера, должно быть загружено.
	map.load_radius_m = camera.far
	traffic.max_cars = [6, 12, 16][q]


## Рендер идёт на процессоре (llvmpipe и подобные), а не на видеокарте.
static func is_software_renderer() -> bool:
	var adapter := RenderingServer.get_video_adapter_name().to_lower()
	for marker in ["llvmpipe", "softpipe", "lavapipe", "swiftshader", "software"]:
		if adapter.contains(marker):
			return true
	return false


func _physics_process(delta: float) -> void:
	if player == null:
		return
	_respawn_cooldown = maxf(_respawn_cooldown - delta, 0.0)
	var moved := player.global_position.distance_to(_last_pos)
	if moved < 50.0: # телепорт не считаем
		GameState.add_distance(moved)
	_last_pos = player.global_position


func _unhandled_input(event: InputEvent) -> void:
	if loading:
		return
	if event.is_action_pressed("pause"):
		pause_requested.emit()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("respawn") and _respawn_cooldown <= 0.0:
		respawn_player()
	elif event.is_action_pressed("call_chase"):
		chase.trigger_now()


## Ставит игрока на ближайшую дорогу по направлению движения.
func respawn_player() -> void:
	_respawn_cooldown = 2.0
	var near := roads.nearest_road(player.global_position)
	if near.is_empty():
		var p := player.global_position
		map.load_now(p)
		p.y = ground_height(p, p.y) + 2.0
		player.place(Transform3D(Basis(Vector3.UP, player.global_rotation.y), p))
		return
	var t: Vector3 = near["tangent"]
	if t.dot(-player.global_basis.z) < 0.0:
		t = -t
	var right := Vector3(-t.z, 0.0, t.x)
	var e: RoadEdge = near["edge"]
	var pos: Vector3 = near["pos"] + right * (2.6 if e.is_highway() else 1.6)
	map.load_now(pos)
	pos.y = ground_height(pos, pos.y) + 1.2
	player.place(Transform3D(Basis.looking_at(t, Vector3.UP), pos))
	camera.snap()


## Высота поверхности (лучом сверху); fallback — если под точкой ничего нет.
func ground_height(pos: Vector3, fallback: float) -> float:
	var from := Vector3(pos.x, 400.0, pos.z)
	var q := PhysicsRayQueryParameters3D.create(from, Vector3(pos.x, -100.0, pos.z), ArcadeCar.LAYER_WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return fallback
	return (hit["position"] as Vector3).y


## Случайная точка на дороге на расстоянии [min_d, max_d] от center.
## prefer_dir — если задан, точка ищется в этом направлении (dot > 0.3).
## Возвращает {pos, edge, s, forward} или {}.
func find_road_spawn(center: Vector3, min_d: float, max_d: float, rng: RandomNumberGenerator,
		need_loaded: bool = true, prefer_dir: Vector3 = Vector3.ZERO) -> Dictionary:
	var rect := Rect2(center.x - max_d, center.z - max_d, max_d * 2.0, max_d * 2.0)
	var near_edges := roads.edges_near(rect)
	if near_edges.is_empty():
		return {}
	var dir := prefer_dir
	dir.y = 0.0
	if dir.length_squared() > 0.0:
		dir = dir.normalized()
	for attempt in 30:
		var e := near_edges[rng.randi() % near_edges.size()]
		if not e.bbox.grow(max_d).has_point(Vector2(center.x, center.z)):
			continue
		var s := rng.randf_range(10.0, maxf(e.length - 10.0, 10.0))
		var p := e.sample(s)
		var to := p - center
		to.y = 0.0
		var d := to.length()
		if d < min_d or d > max_d:
			continue
		if dir != Vector3.ZERO and to.normalized().dot(dir) < 0.3:
			continue
		if need_loaded and not map.contains(p):
			continue
		return {"pos": p, "edge": e, "s": s, "forward": rng.randf() < 0.5}
	return {}


## Точка на рельефе (без дороги) — запасной вариант для преследователей.
func find_ground_spawn(center: Vector3, min_d: float, max_d: float, rng: RandomNumberGenerator,
		prefer_dir: Vector3 = Vector3.ZERO) -> Dictionary:
	var base_ang := atan2(prefer_dir.x, prefer_dir.z) if prefer_dir.length_squared() > 0.0 else rng.randf() * TAU
	for attempt in 20:
		var ang := base_ang + rng.randf_range(-0.8, 0.8)
		var d := rng.randf_range(min_d, max_d)
		var p := center + Vector3(sin(ang), 0.0, cos(ang)) * d
		if not map.contains(p):
			continue
		p.y = ground_height(p, -1000.0)
		if p.y < WorldDefs.WATER_LEVEL + 0.5:
			continue
		return {"pos": p}
	return {}


func _on_player_impact(strength: float) -> void:
	camera.add_shake(clampf(strength / 15.0, 0.1, 0.8))


func _exit_tree() -> void:
	GameState.save_game()
	GameState.weather_grip = 1.0
	GameState.is_night = false
