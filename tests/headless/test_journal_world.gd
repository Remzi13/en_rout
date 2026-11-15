extends SceneTree
## Статистика журнала в настоящем мире (OpenWorld): ночью под дождём (как
## --hour=23 --weather=1) км идут и в «ночью», и в «под дождём»; днём в ясную
## погоду — нет; респаун и телепорт не дают скачка км; время за рулём идёт.
## Пишет в user://test_journal_world2.json и удаляет за собой.

const H := preload("res://tests/headless/helper.gd")
const JPATH := "user://test_journal_world2.json"
const GS_TEST_PATH := "user://test_save_world2.json"

var world


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


## Как разбор --hour= / --weather= в game/main.gd.
func _set_moment(hour: float, kind: int) -> void:
	world.day_night.hour = hour
	world.weather.set_kind(kind)
	world.weather.rain_k = 1.0 if kind == 1 else 0.0
	world.weather.fog_k = 1.0 if kind == 2 else 0.0


func _run() -> void:
	var gs: Node = root.get_node("GameState")
	gs.save_path = GS_TEST_PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JPATH))
	world = (load("res://game/world/open_world.gd") as GDScript).create(1)
	world.journal_path = JPATH
	root.add_child(world)
	var t := Time.get_ticks_msec()
	while world.loading and Time.get_ticks_msec() - t < 30000:
		await physics_frame
	if not H.check("мир загрузился", not world.loading):
		H.finish(self)
		return
	var j: Journal = world.journal
	var p = world.player
	var auto = (load("res://game/cars/drivers/traffic_driver.gd") as GDScript).new()
	var near = world.roads.nearest_road(p.global_position)
	auto.setup(world.roads, near["edge"], true, near["s"], 1)
	auto.cruise_kmh = 110.0
	p.driver = auto

	# Ночь и дождь.
	_set_moment(23.0, 1)
	await _frames(5)
	var d0 := j.distance_m
	var n0 := j.night_distance_m
	var r0 := j.rain_distance_m
	var time0 := j.drive_time_s
	await _frames(20 * 60)
	var dd := j.distance_m - d0
	H.check("ночью под дождём км идут", dd > 100.0, "%.0f м" % dd)
	H.check("км ночью = все км", absf((j.night_distance_m - n0) - dd) < 1.0, "ночью %.0f из %.0f м" % [j.night_distance_m - n0, dd])
	H.check("км под дождём = все км", absf((j.rain_distance_m - r0) - dd) < 1.0, "дождь %.0f из %.0f м" % [j.rain_distance_m - r0, dd])
	H.check("время за рулём ≈ 20 с", absf((j.drive_time_s - time0) - 20.0) < 0.5, "%.2f с" % (j.drive_time_s - time0))

	# День, ясно.
	_set_moment(12.0, 0)
	await _frames(5)
	d0 = j.distance_m
	n0 = j.night_distance_m
	r0 = j.rain_distance_m
	await _frames(10 * 60)
	H.check("днём в ясную погоду км идут", j.distance_m - d0 > 50.0, "%.0f м" % (j.distance_m - d0))
	H.check("днём км ночью не растут", is_equal_approx(j.night_distance_m, n0))
	H.check("в ясную погоду км под дождём не растут", is_equal_approx(j.rain_distance_m, r0))

	# Респаун (R) — машина ставится на ближайшую дорогу.
	d0 = j.distance_m
	world.respawn_player()
	await _frames(2)
	H.check("респаун на дороге не даёт скачка", j.distance_m - d0 < 5.0, "+%.1f м" % (j.distance_m - d0))

	# Телепорт на 600 м.
	p.driver = world.player_driver
	await _frames(60)
	d0 = j.distance_m
	var to: Vector3 = p.global_position + Vector3(600.0, 0.0, 0.0)
	world.map.load_now(to)
	to.y = world.ground_height(to, p.global_position.y) + 1.2
	p.place(Transform3D(Basis(), to))
	await _frames(3)
	H.check("телепорт на 600 м не даёт скачка", j.distance_m - d0 < 5.0, "+%.1f м" % (j.distance_m - d0))

	# Телепорт на 45 м (меньше порога TripStats.TELEPORT_M) — учитывается как путь.
	await _frames(60)
	d0 = j.distance_m
	to = p.global_position + Vector3(0.0, 0.0, 45.0)
	to.y = world.ground_height(to, p.global_position.y) + 1.2
	p.place(Transform3D(Basis(), to))
	await _frames(3)
	H.info("сдвиг на 45 м за кадр засчитан как %.1f м (порог %d м)" % [j.distance_m - d0, 50])

	world.queue_free()
	await _frames(3)
	var saved := FileAccess.file_exists(JPATH)
	H.check("при выходе из мира журнал сохранён", saved)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JPATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GS_TEST_PATH))
	H.finish(self)
