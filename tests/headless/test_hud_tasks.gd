extends SceneTree
## Интерфейс мест и доставок без мира: TaskHud и Radar на подставных
## PlaceTracker / Deliveries. Подсказка появляется с клавишей interact и
## плавно, пустая — скрывается; надписи «Открыто» и «Доставлено» идут по
## очереди и гаснут через ANNOUNCE_S; строка цели «Везу: … → …»; метки
## радара: цель за краем прижата к ободу, неоткрытое место — «?»; без
## данных ничего не падает; interact есть в переназначении.
## Пишет user://test_hud_tasks*.json / .cfg и удаляет за собой.

const H := preload("res://tests/headless/helper.gd")
const JPATH := "user://test_hud_tasks.json"
const SPATH := "user://test_hud_tasks_settings.cfg"
# Классы с обращением к автозагрузке GameState грузятся во время работы:
# при компиляции -s скрипта автозагрузок ещё нет.
const GOAL := "goal"
const PICKUP := "pickup"
const PLACE := "place"
const UNKNOWN := "unknown"


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _def(id: String, cargo: String, from: String, to: String, order: int) -> DeliveryDef:
	var d := DeliveryDef.new()
	d.id = id
	d.cargo = cargo
	d.from_spot = from
	d.to_spot = to
	d.journal_text = "Отвёз: " + cargo
	d.order = order
	return d


func _kinds(marks: Array[Dictionary]) -> Array:
	return marks.map(func(m: Dictionary) -> String: return m["kind"])


func _run() -> void:
	var gs: Node = root.get_node("GameState")
	gs.settings_path = SPATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JPATH))

	# Без данных: ни подсказки, ни цели, ничего не падает.
	var task_hud_cls: GDScript = load("res://game/ui/task_hud.gd")
	var radar_cls: GDScript = load("res://game/ui/radar.gd")
	var menu_cls: GDScript = load("res://game/ui/settings_menu.gd")
	var empty_hud = task_hud_cls.new()
	root.add_child(empty_hud)
	empty_hud.setup(null, null)
	var empty_radar = radar_cls.new()
	empty_radar.size = Vector2(240, 240)
	root.add_child(empty_radar)
	await _frames(3)
	H.check("без данных: подсказка и цель пусты", not empty_hud.prompt_panel.visible and empty_hud.goal_label.text == "")
	H.check("без данных: меток на радаре нет", empty_radar.task_marks(Vector3.ZERO, 0.0, 120.0).is_empty())
	empty_radar.places = PlaceTracker.new()
	empty_radar.deliveries = Deliveries.new()
	H.check("пустые трекеры: меток нет", empty_radar.task_marks(Vector3.ZERO, 0.0, 120.0).is_empty())
	empty_radar.places.free()
	empty_radar.deliveries.free()
	empty_radar.places = null
	empty_radar.deliveries = null

	# Подставные данные.
	var j := Journal.new()
	j.path = JPATH
	var spots := [
		{"id": "a", "title": "Коптильня", "position": Vector3(0, 0, 0)},
		{"id": "b", "title": "Хутор на холмах", "position": Vector3(0, 0, -2000)},
		{"id": "c", "title": "Лавка", "position": Vector3(100, 0, 0)},
	]
	var places_list := [
		{"id": "hill", "title": "Холм над озером", "position": Vector3(0, 0, 60)},
		{"id": "cape", "title": "Мыс", "position": Vector3(-80, 0, 0)},
	]
	var places := PlaceTracker.new()
	places.setup(j, null, places_list)
	root.add_child(places)
	var del := Deliveries.new()
	del.setup(j, null, spots, [_def("fish", "копчёная рыба", "a", "b", 1), _def("motor", "лодочный мотор", "c", "a", 2)])
	root.add_child(del)

	var hud = task_hud_cls.new()
	root.add_child(hud)
	hud.setup(places, del)
	var radar = radar_cls.new()
	radar.size = Vector2(240, 240)
	radar.places = places
	radar.deliveries = del
	root.add_child(radar)
	del.start()
	await _frames(2)
	H.check("цель после выдачи первой доставки", hud.goal_label.text == "Везу: копчёная рыба → Хутор на холмах", hud.goal_label.text)

	# Подсказка.
	del.update_at(Vector3(0, 0, -2000), 0.0)
	var key: String = UiTheme.key_name(gs.key_for("interact"))
	H.check("клавиша interact есть", gs.key_for("interact") != 0, key)
	H.check("подсказка видна с клавишей", hud.prompt_panel.visible and hud.prompt_label.text == "[%s]  Сдать: копчёная рыба" % key, hud.prompt_label.text)
	H.check("подсказка появляется плавно", hud.prompt_panel.modulate.a < 0.5, "a=%.2f" % hud.prompt_panel.modulate.a)
	hud.tick(1.0)
	H.check("подсказка проявилась", is_equal_approx(hud.prompt_panel.modulate.a, 1.0))
	gs.rebind("interact", KEY_F)
	hud.tick(0.0)
	H.check("подсказка следует переназначению", hud.prompt_label.text.begins_with("[F]"), hud.prompt_label.text)
	gs.reset_bindings()
	hud.tick(0.0)
	H.check("после сброса снова клавиша по умолчанию", hud.prompt_label.text.begins_with("[%s]" % key), hud.prompt_label.text)
	del.update_at(Vector3(0, 0, -1000), 0.0)
	H.check("пустая подсказка скрыта", not hud.prompt_panel.visible)

	# Радар: цель за краем, места.
	var r := 120.0
	var marks: Array[Dictionary] = radar.task_marks(Vector3.ZERO, 0.0, r)
	var goal: Array = marks.filter(func(m: Dictionary) -> bool: return m["kind"] == GOAL)
	H.check("на радаре одна цель", goal.size() == 1, str(_kinds(marks)))
	if goal.size() == 1:
		var q: Vector2 = goal[0]["pos"]
		H.check("цель за краем прижата к ободу", goal[0]["edge"] and is_equal_approx(q.length(), r - radar.EDGE_INSET_PX), str(q))
		H.check("цель впереди — стрелка вверху", q.y < 0.0 and absf(q.x) < 0.5, str(q))
	H.check("пока есть доставка, точек взятия нет", not _kinds(marks).has(PICKUP), str(_kinds(marks)))
	H.check("неоткрытые места — «?»", _kinds(marks).count(UNKNOWN) == 2, str(_kinds(marks)))
	var far: Array[Dictionary] = radar.task_marks(Vector3(0, 0, 3000), 0.0, r)
	H.check("места вне радиуса не рисуются", not _kinds(far).has(UNKNOWN) and not _kinds(far).has(PLACE), str(_kinds(far)))

	# Взятие доставки показало «Везём»: проверяем и ждём, пока надпись уйдёт.
	H.check("при взятии — «Везём»", hud.announce_caption.text == "Везём", "%s / %s" % [hud.announce_caption.text, hud.announce_title.text])
	hud.tick(3.1)
	H.check("«Везём» ушла", not hud.announce_box.visible and hud.queue.is_empty())

	# Надписи: место, затем сдача — по очереди.
	places.check(Vector3(0, 0, 60))
	H.check("надпись «Открыто» видна", hud.announce_box.visible and hud.announce_caption.text == "Открыто" and hud.announce_title.text == "Холм над озером",
		"%s / %s" % [hud.announce_caption.text, hud.announce_title.text])
	H.check("надпись появляется плавно", hud.announce_box.modulate.a < 0.5)
	hud.tick(0.5)
	H.check("надпись проявилась", hud.announce_box.modulate.a > 0.99)
	H.check("открытое место на радаре — флажок", _kinds(radar.task_marks(Vector3.ZERO, 0.0, r)).count(PLACE) == 1)
	H.check("сдача доставки", del.interact_at(Vector3(0, 0, -2000), 0.0))
	H.check("«Доставлено» ждёт в очереди, не накладывается", hud.queue.size() == 1 and hud.announce_title.text == "Холм над озером", "очередь %d" % hud.queue.size())
	H.check("после сдачи цели нет", hud.goal_label.text == "", hud.goal_label.text)
	hud.tick(2.4)
	H.check("перед концом надпись гаснет", hud.announce_box.modulate.a < 1.0 and hud.announce_box.visible, "a=%.2f" % hud.announce_box.modulate.a)
	hud.tick(0.2)
	H.check("через 3 с — «Доставлено»", hud.announce_caption.text == "Доставлено" and hud.announce_title.text == "копчёная рыба",
		"%s / %s" % [hud.announce_caption.text, hud.announce_title.text])
	var seen: Array[String] = []
	for i in 80: # 8 с мелкими шагами
		hud.tick(0.1)
		if hud.announce_box.visible and not seen.has(hud.announce_caption.text):
			seen.append(hud.announce_caption.text)
	var all_done: bool = not del.has_target() and del.available_spots().is_empty()
	H.check("«Все грузы доставлены» — только когда сдавать больше нечего", seen.has("Все грузы доставлены") == all_done,
		"все сделаны=%s, надписи=%s" % [all_done, seen])
	H.check("очередь пуста — надпись скрыта", not hud.announce_box.visible and hud.queue.is_empty())
	var after: Array[Dictionary] = radar.task_marks(Vector3.ZERO, 0.0, r)
	H.check("без доставки на радаре точка взятия, без цели", _kinds(after).has(PICKUP) and not _kinds(after).has(GOAL), str(_kinds(after)))

	# Радар рисуется с данными (_draw без мира выходит рано; метки — в task_marks).
	await _frames(3)

	# Переназначение.
	var menu = menu_cls.new()
	root.add_child(menu)
	await _frames(1)
	H.check("interact в переназначении", menu._key_buttons.has("interact"))
	var acts: Array = menu_cls._actions().map(func(p: Array) -> String: return p[0])
	H.check("interact перед паузой", acts.find("interact") == acts.find("pause") - 1, str(acts))
	menu.queue_free()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(JPATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SPATH))
	H.finish(self)
