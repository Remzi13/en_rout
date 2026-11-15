extends SceneTree
# Классы игры грузятся в рантайме: в режиме -s автозагрузка GameState
# не видна при компиляции этого скрипта.
var OpenWorldScript: GDScript
var TrafficDriverScript: GDScript
var ChaseDirectorScript: GDScript
## Интеграция открытого мира: подгрузка чанков вокруг игрока, старт на
## дороге, езда по дорогам через чанки без провалов, трафик, запуск погони,
## захват и побег, телепорт в незагруженный чанк.

const H := preload("res://tests/headless/helper.gd")
const CR := preload("res://game/chase/chase_rules.gd")

var world


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	OpenWorldScript = load("res://game/world/open_world.gd")
	TrafficDriverScript = load("res://game/cars/drivers/traffic_driver.gd")
	ChaseDirectorScript = load("res://game/chase/chase_director.gd")
	var gs: Node = root.get_node("GameState")
	gs.save_path = "user://test_save_world.json"
	world = OpenWorldScript.create(42)
	world.journal_path = "user://test_journal_world.json"
	var t_load := Time.get_ticks_msec()
	root.add_child(world)
	# Ждём по реальному времени: чанки читаются с диска, а кадры в headless
	# с --fixed-fps идут без пауз, и счёт кадров ничего не говорит о загрузке.
	while world.loading and Time.get_ticks_msec() - t_load < 30000:
		await physics_frame
	H.info("стартовая загрузка: %d мс" % (Time.get_ticks_msec() - t_load))
	var p = world.player
	if not H.check("игрок создан (мир загрузился за 30 с)", p != null):
		H.finish(self)
		return
	var total: int = world.map.index.chunk_coords.size()
	var initial: int = world.map.chunks().size()
	H.check("до старта грузятся только чанки у старта", initial > 0 and initial < total, "%d из %d" % [initial, total])
	H.check("чанк под игроком загружен", world.map.contains(p.global_position))
	await _frames(5)
	H.check("дорожная сеть собрана", world.roads.edges.size() > 10, "%d участков" % world.roads.edges.size())

	await _frames(120)
	H.check("машина стоит на поверхности", p.grounded_wheels >= 3, "колёс на земле: %d" % p.grounded_wheels)
	H.check("старт на дороге", p.on_road)

	# Едем «автопилотом» трафика по дорогам 50 с.
	var auto = TrafficDriverScript.new()
	var near = world.roads.nearest_road(p.global_position)
	auto.setup(world.roads, near["edge"], true, near["s"], 1)
	auto.cruise_kmh = 110.0
	p.driver = auto
	var min_clear := INF
	var max_traffic := 0
	var path_m := 0.0
	var prev_pos = p.global_position
	var visited := {}
	var t0 := Time.get_ticks_msec()
	for i in 3000:
		await physics_frame
		auto.cruise_kmh = 110.0 if auto.edge.is_highway() else 70.0
		path_m += p.global_position.distance_to(prev_pos)
		prev_pos = p.global_position
		visited[WorldDefs.chunk_of(p.global_position)] = true
		if i % 30 == 0:
			var g = world.ground_height(p.global_position, -999.0)
			min_clear = minf(min_clear, p.global_position.y - g)
			max_traffic = maxi(max_traffic, world.traffic.cars.size())
	var real_s := (Time.get_ticks_msec() - t0) / 1000.0
	H.info("проехано %.0f м за 50 с игры (%.1f с реального времени), чанков пройдено %d" % [path_m, real_s, visited.size()])
	H.check("машина проехала по дорогам", path_m > 800.0, "%.0f м" % path_m)
	H.check("машина переезжает из чанка в чанк", visited.size() >= 2, "%d" % visited.size())
	H.check("машина не провалилась сквозь мир", min_clear > -1.0, "мин. просвет %.2f м" % min_clear)
	H.check("появился трафик", max_traffic > 0, "%d" % max_traffic)
	H.check("остальные чанки догрузились в фоне", world.map.is_settled(), "загружено %d" % world.map.chunks().size())

	# Выгрузка: с малым радиусом дальние чанки уходят из дерева.
	var radius_before: float = world.map.load_radius_m
	world.map.load_radius_m = 200.0
	await _frames(5)
	var far_left := 0
	for c in world.map.chunks():
		if ChunkStreamer.distance_to_chunk(p.global_position, c.coord) > 200.0 + world.map.unload_margin_m:
			far_left += 1
	H.check("дальние чанки выгружаются", far_left == 0 and world.map.chunks().size() < total,
		"загружено %d, лишних %d" % [world.map.chunks().size(), far_left])
	world.map.load_radius_m = radius_before

	# Погоня: игрок стоит — его должны зажать.
	p.driver = null
	world.chase.trigger_now()
	await _frames(10)
	H.check("погоня: предупреждение", world.chase.state == ChaseDirectorScript.State.WARNING, str(world.chase.state))
	var n = world.chase.pursuers.size()
	H.check("2–4 преследователя", n >= 2 and n <= 4, "%d" % n)
	await _frames(200)
	H.check("погоня активна", world.chase.state == ChaseDirectorScript.State.ACTIVE)
	var caught_t := 0
	while world.chase.state == ChaseDirectorScript.State.ACTIVE and caught_t < 60 * 60:
		await physics_frame
		caught_t += 1
	H.check("стоящего игрока зажали", world.chase.last_outcome == CR.Outcome.CAUGHT,
		"исход %d за %.1f с, мин. дистанция %.0f" % [world.chase.last_outcome, caught_t / 60.0, world.chase.min_pursuer_distance()])
	H.info("время до захвата: %.1f с" % (caught_t / 60.0))

	# Ждём конец результата, вторая погоня — телепорт далеко = побег.
	while world.chase.state != ChaseDirectorScript.State.FREE:
		await physics_frame
	world.chase.trigger_now()
	await _frames(200)
	H.check("вторая погоня активна", world.chase.state == ChaseDirectorScript.State.ACTIVE)
	# Самая дальняя от игрока точка дорог.
	var fp: Vector3 = p.global_position
	for e in world.roads.edges:
		for q: Vector3 in e.points:
			if q.distance_to(p.global_position) > fp.distance_to(p.global_position):
				fp = q
	world.map.load_radius_m = 200.0 # чтобы точка телепорта точно была не загружена
	await _frames(5)
	var was_loaded: bool = world.map.contains(fp)
	p.place(Transform3D(Basis(), fp + Vector3.UP * 1.5))
	await physics_frame
	H.check("телепорт в незагруженный чанк: чанк грузится сразу", not was_loaded and world.map.contains(fp),
		"был загружен: %s" % was_loaded)
	var esc_t := 0
	while world.chase.state == ChaseDirectorScript.State.ACTIVE and esc_t < 30 * 60:
		await physics_frame
		esc_t += 1
	H.check("побег при отрыве > 300 м", world.chase.last_outcome == CR.Outcome.ESCAPED,
		"исход %d за %.1f с" % [world.chase.last_outcome, esc_t / 60.0])
	H.check("рекорд записан", gs.records.size() >= 2)

	H.check("после телепорта машина на земле", p.grounded_wheels >= 3, "колёс на земле: %d" % p.grounded_wheels)
	world.map.load_radius_m = radius_before

	# Респаун на дорогу.
	p.place(Transform3D(Basis(), p.global_position + Vector3(30, 5, 30)))
	await _frames(30)
	world.respawn_player()
	await _frames(60)
	H.check("респаун ставит на дорогу", p.on_road and p.grounded_wheels >= 3)

	H.check("журнал считает путь машины", world.journal.distance_m > 10.0, "%.0f м" % world.journal.distance_m)
	world.queue_free()
	await _frames(5)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_save_world.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_journal_world.json"))
	H.finish(self)
