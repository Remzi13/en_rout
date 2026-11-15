extends SceneTree
# Классы игры грузятся в рантайме: в режиме -s автозагрузка GameState
# не видна при компиляции этого скрипта.
var OpenWorldScript: GDScript
var TrafficDriverScript: GDScript
var ChaseDirectorScript: GDScript
## Замер времени кадра открытого мира (не тест, запускать вручную).

func _initialize() -> void:
	_run()

func _run() -> void:
	OpenWorldScript = load("res://game/world/open_world.gd")
	TrafficDriverScript = load("res://game/cars/drivers/traffic_driver.gd")
	ChaseDirectorScript = load("res://game/chase/chase_director.gd")
	var t := Time.get_ticks_usec()
	var w = OpenWorldScript.create(42)
	w.journal_path = "user://test_journal_perf.json"
	root.add_child(w)
	while w.loading:
		await process_frame
	print("создание мира: %d мс, чанков %d, добавление чанка до %.0f мс" % [(Time.get_ticks_usec() - t) / 1000,
		w.map.chunks().size(), w.map.max_add_ms])
	w.map.chunk_loaded.connect(func(c: Vector2i) -> void: print("  чанк %s: %.0f мс" % [c, w.map.last_add_ms]))
	for phase in ["idle", "drive"]:
		if phase == "drive":
			var auto = TrafficDriverScript.new()
			var near = w.roads.nearest_road(w.player.global_position)
			auto.setup(w.roads, near["edge"], true, near["s"], 1)
			auto.cruise_kmh = 110.0
			w.player.driver = auto
		var worst := 0
		t = Time.get_ticks_usec()
		var last := t
		for i in 240:
			await physics_frame
			var now := Time.get_ticks_usec()
			worst = maxi(worst, now - last)
			last = now
		print("%s: среднее %.1f мс/кадр, худший %.1f мс, трафик %d" % [phase,
			(Time.get_ticks_usec() - t) / 240000.0, worst / 1000.0, w.traffic.cars.size()])
	w.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_journal_perf.json"))
	quit()
