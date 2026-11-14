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
	root.add_child(w)
	print("создание мира: %d мс" % ((Time.get_ticks_usec() - t) / 1000))
	for phase in ["idle", "drive"]:
		if phase == "drive":
			var auto = TrafficDriverScript.new()
			var near = w.gen.nearest_road(w.player.global_position)
			auto.setup(w.gen, near["edge"], true, near["s"], 1)
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
		print("%s: среднее %.1f мс/кадр, худший %.1f мс, чанков %d, в очереди %d, трафик %d" % [phase,
			(Time.get_ticks_usec() - t) / 240000.0, worst / 1000.0, w.chunks.loaded_count(), w.chunks.pending_count(), w.traffic.cars.size()])
	quit()
