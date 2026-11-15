extends SceneTree
## Карта-схема без мира: MapScreen на подставных WorldIndex, PlaceTracker,
## Deliveries и машине. Пересчёт «мир → экран» (углы мира, север сверху,
## пропорции, поля), курс игрока; открытие и закрытие действием map и Esc,
## пауза на время карты, не открывается поверх паузы; плавное появление;
## без подложки и без данных не падает; значки и строка «Везу: …» — из
## подставных данных; map есть в переназначении.
## Пишет только user://test_map_screen*.json / .cfg и удаляет за собой.

const H := preload("res://tests/headless/helper.gd")
const JPATH := "user://test_map_screen.json"
const SPATH := "user://test_map_screen_settings.cfg"


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	root.push_input(ev)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	root.push_input(up)


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


func _of(marks: Array[Dictionary], kind: String) -> Array[Dictionary]:
	return marks.filter(func(m: Dictionary) -> bool: return m["kind"] == kind)


func _near(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.01


func _run() -> void:
	var gs: Node = root.get_node("GameState")
	gs.settings_path = SPATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JPATH))
	var journal_mtime := FileAccess.get_modified_time("user://journal.json")
	# Классы с обращением к GameState грузим во время работы.
	var cls: GDScript = load("res://game/ui/map_screen.gd")

	# --- Пересчёт «мир → экран» ---
	var wr := WorldDefs.rect_of_chunks([Vector2i(-4, -4), Vector2i(3, 3)] as Array[Vector2i])
	H.check("мир 8×8 чанков: −1024..1024", wr == Rect2(-1024, -1024, 2048, 2048), str(wr))
	var area: Rect2 = cls.map_area(Vector2(1920, 1080))
	var mr: Rect2 = cls.fit_rect(wr, area)
	H.check("карта вписана целиком в поле", area.encloses(mr), "%s в %s" % [mr, area])
	H.check("карта квадратная, как мир", is_equal_approx(mr.size.x, mr.size.y), str(mr.size))
	H.check("карта по высоте во всё поле", is_equal_approx(mr.size.y, area.size.y), str(mr))
	H.check("карта по центру", _near(mr.get_center(), area.get_center()), str(mr.get_center()))
	H.check("поля вокруг карты", mr.position.y >= cls.MARGIN_TOP_PX and mr.end.y <= 1080.0 - cls.MARGIN_BOTTOM_PX, str(mr))
	H.check("северо-запад (−X, −Z) — левый верхний угол",
		_near(cls.world_to_screen(Vector3(-1024, 50, -1024), wr, mr), mr.position))
	H.check("юго-восток (+X, +Z) — правый нижний угол",
		_near(cls.world_to_screen(Vector3(1024, 0, 1024), wr, mr), mr.end))
	H.check("северо-восток — правый верхний угол",
		_near(cls.world_to_screen(Vector3(1024, 0, -1024), wr, mr), Vector2(mr.end.x, mr.position.y)))
	H.check("центр мира — центр карты", _near(cls.world_to_screen(Vector3.ZERO, wr, mr), mr.get_center()))
	var north: Vector2 = cls.world_to_screen(Vector3(0, 0, -500), wr, mr)
	var east: Vector2 = cls.world_to_screen(Vector3(500, 0, 0), wr, mr)
	H.check("север выше центра, восток правее", north.y < mr.get_center().y and east.x > mr.get_center().x
		and is_equal_approx(north.x, mr.get_center().x), "%s %s" % [north, east])
	var wide: Rect2 = cls.fit_rect(Rect2(0, 0, 2000, 1000), Rect2(0, 0, 1000, 1000))
	H.check("вытянутый мир: по ширине, по центру по высоте", wide == Rect2(0, 250, 1000, 500), str(wide))
	H.check("пустой мир не делит на ноль", cls.fit_rect(Rect2(), area).size == Vector2.ZERO
		and cls.world_to_screen(Vector3(5, 0, 5), Rect2(), Rect2(10, 10, 0, 0)) == Vector2(10, 10))
	H.check("курс по базису совпадает с курсом по углу", _near(cls.heading_of(Basis(Vector3.UP, 0.7)), cls.heading_dir(0.7)))
	H.check("курс по базису с креном не прыгает", _near(cls.heading_of(Basis(Vector3.UP, 0.7) * Basis(Vector3.FORWARD, 2.5)), cls.heading_dir(0.7)))
	H.check("курс: yaw 0 — вверх (на север)", _near(cls.heading_dir(0.0), Vector2(0, -1)), str(cls.heading_dir(0.0)))
	# Поворот на +90° вокруг Y: −Z локально смотрит в −X мира — влево.
	H.check("курс: yaw +90° — влево (на запад)", _near(cls.heading_dir(PI * 0.5), Vector2(-1, 0)), str(cls.heading_dir(PI * 0.5)))

	# --- Без данных и без подложки ---
	H.check("подложки по договору в этой ветке может не быть: загрузка не падает",
		cls.load_base("res://game/world/__нет_такой__.png") == null)
	var empty = cls.new()
	root.add_child(empty)
	empty.setup(null, null, null, null)
	H.check("без сводки мира карта не открывается", not empty.open() and not paused)
	H.check("без данных значков нет", empty.marks().is_empty())
	empty.visible = true
	await _frames(2) # _draw без данных
	empty.queue_free()

	# --- Подставные данные ---
	var idx := WorldIndex.new()
	idx.chunk_coords = [Vector2i(-4, -4), Vector2i(3, 3)] as Array[Vector2i]
	idx.road_points = [PackedVector3Array([Vector3(-500, 0, 0), Vector3(0, 0, 0), Vector3(500, 0, 0)]),
		PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0, -300)])] as Array[PackedVector3Array]
	idx.road_types = PackedInt32Array([WorldDefs.RoadType.HIGHWAY, WorldDefs.RoadType.DIRT])
	idx.spots = [
		{"id": "a", "title": "Коптильня", "position": Vector3(0, 0, 0)},
		{"id": "b", "title": "Хутор на холмах", "position": Vector3(0, 0, -800)},
		{"id": "c", "title": "Лавка", "position": Vector3(200, 0, 0)},
	] as Array[Dictionary]
	var j := Journal.new()
	j.path = JPATH
	var places := PlaceTracker.new()
	places.setup(j, null, [
		{"id": "hill", "title": "Холм над озером", "position": Vector3(-300, 0, 400)},
		{"id": "cape", "title": "Мыс", "position": Vector3(600, 0, 600)},
	])
	root.add_child(places)
	var del := Deliveries.new()
	del.setup(j, null, idx.spots, [_def("fish", "ящик копчёной рыбы", "a", "b", 1), _def("motor", "лодочный мотор", "c", "a", 2)])
	root.add_child(del)
	del.start()
	j.open_place("hill", false)
	var car := Node3D.new()
	root.add_child(car)
	car.global_position = Vector3(512, 3, -512)
	car.rotation.y = PI * 0.5

	var map = cls.new()
	root.add_child(map)
	map.setup(idx, car, places, del)
	await _frames(1)
	var r: Rect2 = map.map_rect()
	H.check("прямоугольник карты по размеру экрана", r == cls.fit_rect(wr, cls.map_area(map.size)), str(r))
	H.check("без подложки — нет текстуры, карта не падает", cls.load_base("res://нет/такой/подложки.png") == null)
	H.check("дороги из сводки: обе", map._roads.size() == 2 and map._roads[0]["type"] == WorldDefs.RoadType.HIGHWAY
		and map._roads[1]["type"] == WorldDefs.RoadType.DIRT, str(map._roads.size()))
	H.check("асфальт шире грунтовки", map._road_width(WorldDefs.RoadType.HIGHWAY) > map._road_width(WorldDefs.RoadType.DIRT))
	var road0: PackedVector2Array = map._roads[0]["points"]
	H.check("дорога: последняя точка не потеряна", _near(road0[road0.size() - 1], cls.world_to_screen(Vector3(500, 0, 0), wr, r)), str(road0))

	var marks: Array[Dictionary] = map.marks()
	H.check("подписи всех точек Spots", _of(marks, map.MARK_SPOT).map(func(m: Dictionary) -> String: return m["title"])
		== ["Коптильня", "Хутор на холмах", "Лавка"], str(_kinds(marks)))
	var opened_pl := _of(marks, map.MARK_PLACE)
	var unknown := _of(marks, map.MARK_UNKNOWN)
	H.check("открытое место — флажок с названием", opened_pl.size() == 1 and opened_pl[0]["title"] == "Холм над озером"
		and _near(opened_pl[0]["pos"], cls.world_to_screen(Vector3(-300, 0, 400), wr, r)))
	H.check("неоткрытое место — «?» без названия", unknown.size() == 1 and unknown[0]["title"] == "")
	var goal := _of(marks, map.MARK_GOAL)
	H.check("цель активной доставки — точка сдачи", goal.size() == 1
		and _near(goal[0]["pos"], cls.world_to_screen(Vector3(0, 0, -800), wr, r)), str(goal))
	H.check("пока везём, точек взятия нет", _of(marks, map.MARK_PICKUP).is_empty())
	var pl := _of(marks, map.MARK_PLAYER)
	H.check("игрок на своём месте", pl.size() == 1 and _near(pl[0]["pos"], cls.world_to_screen(car.global_position, wr, r)), str(pl))
	if pl.size() == 1:
		H.check("стрелка игрока по курсу", _near(pl[0]["dir"], Vector2(-1, 0)), str(pl[0]["dir"]))
	H.check("игрок рисуется последним (поверх)", _kinds(marks).back() == map.MARK_PLAYER)

	# --- Открытие и закрытие ---
	H.check("до открытия скрыта, игра идёт", not map.visible and not paused)
	_press("map")
	await _frames(1)
	H.check("map открывает карту", map.is_open and map.visible)
	H.check("пока карта открыта — пауза", paused)
	H.check("появляется плавно", map.modulate.a < 0.5, "a=%.2f" % map.modulate.a)
	map.tick(1.0)
	H.check("проявилась", is_equal_approx(map.modulate.a, 1.0))
	H.check("строка цели сверху", map.goal_label.text == "Везу: ящик копчёной рыбы → Хутор на холмах", map.goal_label.text)
	var key: String = UiTheme.key_name(gs.key_for("map"))
	H.check("клавиша карты по умолчанию — M", gs.key_for("map") == KEY_M, key)
	H.check("подсказка закрытия с клавишей", map.hint_label.text == "%s / Esc — закрыть" % key, map.hint_label.text)
	await _frames(2) # _draw с данными
	_press("map")
	await _frames(1)
	H.check("map закрывает карту", not map.is_open and not map.visible and not paused)
	_press("map")
	await _frames(1)
	_press("ui_cancel")
	await _frames(1)
	H.check("Esc закрывает карту", not map.is_open and not paused)

	paused = true
	_press("map")
	await _frames(1)
	H.check("поверх паузы не открывается", not map.is_open and paused)
	paused = false

	# Переназначение: строка подсказки следует новой клавише.
	gs.rebind("map", KEY_K)
	H.check("после переназначения открывает новая клавиша", gs.key_for("map") == KEY_K)
	map.open()
	H.check("подсказка с новой клавишей", map.hint_label.text.begins_with("K /"), map.hint_label.text)
	map.close()
	gs.reset_bindings()

	# Доставку сдали: цели нет, есть точка взятия, строки «Везу» нет.
	del.interact_at(Vector3(0, 0, -800), 0.0)
	map.open()
	var after: Array[Dictionary] = map.marks()
	H.check("без доставки: точка взятия, без цели", _of(after, map.MARK_PICKUP).size() == 1 and _of(after, map.MARK_GOAL).is_empty(), str(_kinds(after)))
	H.check("без доставки строки «Везу» нет", map.goal_label.text == "", map.goal_label.text)
	# Ночь: рисуется так же, без ошибок.
	gs.is_night = true
	await _frames(2)
	gs.is_night = false
	map.close()

	# Переназначение в меню настроек.
	var menu_cls: GDScript = load("res://game/ui/settings_menu.gd")
	var menu = menu_cls.new()
	root.add_child(menu)
	await _frames(1)
	H.check("«Карта» в переназначении", menu._key_buttons.has("map"))
	menu.queue_free()

	H.check("user://journal.json не тронут", FileAccess.get_modified_time("user://journal.json") == journal_mtime)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JPATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SPATH))
	H.finish(self)
