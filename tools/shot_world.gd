extends SceneTree
## Снимок игрового мира (OpenWorld с подгрузкой чанков) в нужной точке — для
## проверки карты глазами (нужен экран, не --headless):
##   godot --path . -s res://tools/shot_world.gd -- --shot=файл.png [--at=x,z,угол°] [--drive] [--time=с]
## --at — машина ставится в точку (x, z) мира, угол — поворот от «вперёд» (-Z)
## против часовой; без --at — старт карты. --drive — газ зажат. Снимок
## через --time секунд (по умолчанию 4) после загрузки, затем выход.

# OpenWorld грузится в рантайме: в режиме -s автозагрузка GameState не видна
# при компиляции этого скрипта (как в tests/headless/test_open_world.gd).
const JOURNAL := "user://shot_journal.json" ## временный журнал, удаляется после снимка
var _world
var _shot := ""
var _wait_s := 4.0


func _initialize() -> void:
	_run()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var at := PackedFloat64Array()
	var drive := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot = a.trim_prefix("--shot=")
		elif a.begins_with("--at="):
			at = a.trim_prefix("--at=").split_floats(",")
		elif a.begins_with("--time="):
			_wait_s = float(a.trim_prefix("--time="))
		elif a == "--drive":
			drive = true
	if _shot == "":
		push_error("Нужен --shot=файл.png")
		quit(1)
		return
	_world = (load("res://game/world/open_world.gd") as GDScript).create(1)
	_world.journal_path = JOURNAL # не трогать сохранение игрока
	root.add_child(_world)
	if _world.loading:
		await _world.ready_to_play
	_world.traffic.process_mode = Node.PROCESS_MODE_DISABLED
	_world.day_night.hour = 10.0
	if at.size() >= 3:
		var p := Vector3(at[0], 0.0, at[1])
		_world.map.load_now(p)
		await physics_frame
		p.y = float(_world.ground_height(p, 0.0)) + 1.2
		var fwd := Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(at[2]))
		_world.player.place(Transform3D(Basis.looking_at(fwd, Vector3.UP), p))
		_world.camera.snap()
	if drive:
		Input.action_press("accelerate")
	await create_timer(_wait_s).timeout
	await process_frame
	var car: RigidBody3D = _world.player
	var p := car.global_position
	print("Кадр: позиция машины (%.1f, %.1f, %.1f), %.0f км/ч" % [p.x, p.y, p.z,
		car.linear_velocity.length() * 3.6])
	root.get_texture().get_image().save_png(_shot)
	# Журнал пишется при уходе мира из дерева — удаляем файл после этого.
	_world.queue_free()
	await process_frame
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JOURNAL))
	quit(0)
