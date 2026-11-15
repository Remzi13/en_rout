extends SceneTree
## Главное меню и сохранение журнала через настоящий game/main.tscn:
## без сохранения нет «Продолжить»; после сессии файл есть и «Продолжить»
## видна; «Новая игра» → «Отмена» ничего не стирает; «Стереть и начать»
## стирает журнал, и новая сессия начинает статистику с нуля (уходящий мир
## не дописывает старые км). Пауза не прибавляет км и время; «Рекорды»
## в паузе открывают таблицу, «Назад» возвращает в паузу.
##
## main.gd пишет в настоящий user://journal.json, поэтому тест сохраняет его
## содержимое до начала и возвращает в конце; рекорды GameState уводятся
## в user://test_save_menu.json. С окном и аргументом --shots=папка снимает
## кадры меню.

const H := preload("res://tests/headless/helper.gd")
const JPATH := "user://journal.json"
const GS_TEST_PATH := "user://test_save_menu.json"

var main: Node
var _shots := ""
var _backup: Variant = null # исходное содержимое journal.json или null


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _wait_ms(ms: int) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < ms:
		await process_frame


func _buttons() -> Array[Button]:
	var out: Array[Button] = []
	for n in main.find_children("*", "Button", true, false):
		var b := n as Button
		if b.is_visible_in_tree() and not b.is_queued_for_deletion():
			out.append(b)
	return out


func _button(text: String) -> Button:
	for b in _buttons():
		if b.text == text:
			return b
	return null


func _texts() -> String:
	var t: PackedStringArray = []
	for b in _buttons():
		t.append(b.text)
	return ", ".join(t)


func _shot(name: String) -> void:
	if _shots == "":
		return
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(_shots.path_join(name + ".png"))


func _read_journal() -> Dictionary:
	if not FileAccess.file_exists(JPATH):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(JPATH)) != OK or not json.data is Dictionary:
		return {}
	return json.data


func _km(d: Dictionary) -> float:
	return float(d.get("stats", {}).get("distance_m", -1.0))


## Запуск сессии кнопкой меню и ожидание загрузки мира.
func _press_and_wait_world(text: String) -> bool:
	var b := _button(text)
	if b == null:
		return false
	b.pressed.emit()
	var t := Time.get_ticks_msec()
	while (main.world == null or main.world.loading) and Time.get_ticks_msec() - t < 30000:
		await process_frame
	return main.world != null and not main.world.loading


## Машина игрока едет автопилотом трафика ms миллисекунд.
func _drive(ms: int) -> void:
	var w = main.world
	var auto = (load("res://game/cars/drivers/traffic_driver.gd") as GDScript).new()
	var near = w.roads.nearest_road(w.player.global_position)
	auto.setup(w.roads, near["edge"], true, near["s"], 1)
	auto.cruise_kmh = 110.0
	w.player.driver = auto
	await _frames(int(ms / 1000.0 * 60.0))


## Пауза → «В главное меню» через кнопки.
func _to_menu() -> void:
	main._pause()
	await process_frame
	_button("В главное меню").pressed.emit()
	await _frames(5)


func _run() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.trim_prefix("--shots=")
	root.size = Vector2i(1280, 720)
	var gs: Node = root.get_node("GameState")
	gs.save_path = GS_TEST_PATH
	if FileAccess.file_exists(JPATH):
		_backup = FileAccess.get_file_as_string(JPATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JPATH))

	main = (load("res://game/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await _frames(3)
	H.check("без сохранения нет «Продолжить»", _button("Продолжить") == null, _texts())
	H.check("есть «Новая игра»", _button("Новая игра") != null)
	H.check("нет поля сида", main.find_children("*", "LineEdit", true, false).is_empty())
	await _shot("menu_no_save")

	# Первая сессия: без сохранения «Новая игра» стартует сразу.
	H.check("«Новая игра» без сохранения сразу грузит мир", await _press_and_wait_world("Новая игра"))
	await _drive(20000)
	var w = main.world
	var km1: float = w.journal.distance_m
	H.check("журнал считает путь", km1 > 100.0, "%.0f м" % km1)
	# Пауза: км и время не растут.
	main._pause()
	var d0: float = w.journal.distance_m
	var t0: float = w.journal.drive_time_s
	await _frames(120)
	H.check("на паузе км не растут", is_equal_approx(w.journal.distance_m, d0), "%.2f → %.2f" % [d0, w.journal.distance_m])
	H.check("на паузе время за рулём не растёт", is_equal_approx(w.journal.drive_time_s, t0), "%.2f → %.2f" % [t0, w.journal.drive_time_s])
	await _shot("pause")
	# «Рекорды» в паузе (до экрана журнала, задача 5): открывают таблицу, «Назад» — в паузу.
	H.check("в паузе есть «Рекорды»", _button("Рекорды") != null, _texts())
	if _button("Рекорды") != null:
		_button("Рекорды").pressed.emit()
		await _frames(2)
		H.check("«Рекорды» из паузы открывают таблицу", _button("Назад") != null and _button("Продолжить") == null, _texts())
		H.check("с рекордами игра на паузе", paused)
		await _shot("pause_records")
		if _button("Назад") != null:
			_button("Назад").pressed.emit()
		await _frames(2)
		H.check("«Назад» из рекордов возвращает в паузу", _button("Продолжить") != null and _button("Рекорды") != null and main.world != null, _texts())
		H.check("фокус на «Рекорды» после возврата", _button("Рекорды") != null and _button("Рекорды").has_focus())
	main._resume()
	await _frames(10)
	km1 = w.journal.distance_m
	await _to_menu()
	var saved := _read_journal()
	H.check("после сессии есть journal.json", not saved.is_empty())
	H.check("в файле км сессии", absf(_km(saved) - km1) < 30.0, "файл %.0f м, сессия %.0f м" % [_km(saved), km1])
	H.check("после сессии видна «Продолжить»", _button("Продолжить") != null, _texts())
	H.check("фокус на «Продолжить»", _button("Продолжить") != null and _button("Продолжить").has_focus())
	await _shot("menu_with_save")

	# «Новая игра» → подтверждение → «Отмена».
	var before := FileAccess.get_file_as_string(JPATH)
	_button("Новая игра").pressed.emit()
	await _frames(2)
	H.check("при сохранении «Новая игра» спрашивает", _button("Стереть и начать") != null and _button("Отмена") != null, _texts())
	H.check("мир не грузится до ответа", main.world == null)
	await _shot("menu_confirm")
	_button("Отмена").pressed.emit()
	await _frames(3)
	H.check("«Отмена» не стирает журнал", FileAccess.get_file_as_string(JPATH) == before)
	H.check("после «Отмены» снова меню с «Продолжить»", _button("Продолжить") != null and _button("Стереть и начать") == null, _texts())

	# «Продолжить» подхватывает старые км.
	H.check("«Продолжить» грузит мир", await _press_and_wait_world("Продолжить"))
	H.check("«Продолжить» загружает журнал", main.world.journal.distance_m >= km1 - 1.0,
		"%.0f м, было %.0f м" % [main.world.journal.distance_m, km1])
	await _drive(3000)
	await _to_menu()
	var km_cont := _km(_read_journal())
	H.check("после «Продолжить» км накапливаются", km_cont > km1, "%.0f → %.0f м" % [km1, km_cont])

	# «Стереть и начать».
	_button("Новая игра").pressed.emit()
	await _frames(2)
	var yes := _button("Стереть и начать")
	yes.pressed.emit()
	H.check("«Стереть и начать» стирает файл", not FileAccess.file_exists(JPATH))
	var t := Time.get_ticks_msec()
	while (main.world == null or main.world.loading) and Time.get_ticks_msec() - t < 30000:
		await process_frame
	H.check("после стирания мир загрузился", main.world != null and not main.world.loading)
	H.check("новый журнал пустой", main.world.journal.distance_m < 1.0 and main.world.journal.entries.is_empty(),
		"%.1f м" % main.world.journal.distance_m)
	await _drive(5000)
	var km_new: float = main.world.journal.distance_m
	await _to_menu()
	var km_file := _km(_read_journal())
	H.check("после новой сессии в файле только новые км", km_file >= 0.0 and km_file < km_cont and absf(km_file - km_new) < 30.0,
		"файл %.0f м, новая сессия %.0f м, старый журнал %.0f м" % [km_file, km_new, km_cont])

	# Возврат файлов как было.
	main.queue_free()
	await _frames(3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JPATH))
	if _backup != null:
		var f := FileAccess.open(JPATH, FileAccess.WRITE)
		f.store_string(_backup)
		f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GS_TEST_PATH))
	H.finish(self)
