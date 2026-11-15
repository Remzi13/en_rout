extends SceneTree
## Открытие мест без сцены (PlaceTracker на подставных местах): место
## открывается при въезде в радиус (запись KIND_PLACE с id, временем суток и
## погодой, сигнал place_discovered), повторно не открывается (и после
## перечитывания журнала), сводка мира без поля places и негодные данные не
## роняют игру. Пишет только в user://test_places.json.

const H := preload("res://tests/headless/helper.gd")
const PATH := "user://test_places.json"


class FakeSink:
	var journal: Journal
	func add_event(kind: String, text: String, id: String = "") -> Dictionary:
		return journal.add_entry(kind, text, 7.0, Journal.WEATHER_FOG, id)


## Сводка мира со старым набором полей (без places).
class OldIndex:
	extends Resource
	var road_types := PackedInt32Array()


class NewIndex:
	extends Resource
	var places: Array[Dictionary] = []
	var spots: Variant = null


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	# Сводка мира: поле есть, нет его или null.
	H.check("from_index: null-сводка — пусто", PlaceTracker.from_index(null, "places").is_empty())
	H.check("from_index: нет поля — пусто", PlaceTracker.from_index(OldIndex.new(), "places").is_empty())
	var ni := NewIndex.new()
	ni.places.append({"id": "hill", "title": "Холм", "position": Vector3.ZERO, "radius": 25.0})
	H.check("from_index: поле есть", PlaceTracker.from_index(ni, "places").size() == 1)
	H.check("from_index: поле null — пусто", PlaceTracker.from_index(ni, "spots").is_empty())
	H.check("from_index: настоящая сводка не падает", PlaceTracker.from_index(WorldIndex.load_baked(), "places") is Array)

	Journal.reset(PATH)
	var j := Journal.load_or_new(PATH)
	var sink := FakeSink.new()
	sink.journal = j
	var pt := PlaceTracker.new()
	var data := [
		{"id": "hill", "title": "Холм над озером", "position": Vector3(100, 20, 0), "radius": 25.0},
		{"id": "bridge", "title": "Старый мост", "position": Vector3(-300, 2, 40)}, # радиус по умолчанию 25
		{"id": "shore", "position": Vector3(0, 0, 500), "radius": -1}, # без названия, негодный радиус
		{"title": "без id", "position": Vector3.ZERO}, "мусор", null, {"id": "nopos"},
	]
	pt.setup(j, null, data, sink)
	H.check("негодные места отброшены", pt.places.size() == 3, "%d" % pt.places.size())
	H.check("без названия — id, радиус по умолчанию", pt.places[2]["title"] == "shore"
		and is_equal_approx(float(pt.places[2]["radius"]), PlaceTracker.DEFAULT_RADIUS_M))
	var got: Array = []
	pt.place_discovered.connect(func(id: String, title: String) -> void: got.append([id, title]))

	H.check("вне радиуса не открывается", pt.check(Vector3(126, 20, 0)).is_empty() and got.is_empty()
		and not j.is_place_open("hill"))
	H.check("в радиусе открывается (высота не важна)", pt.check(Vector3(120, 0, 10)) == ["hill"]
		and got == [["hill", "Холм над озером"]] and j.is_place_open("hill"))
	var e: Dictionary = j.entries.back() if not j.entries.is_empty() else {}
	H.check("запись в журнале: место, id, время и погода", j.entries.size() == 1 and e.get("kind") == Journal.KIND_PLACE
		and e.get("text") == "Холм над озером" and e.get("id") == "hill" and e.get("weather") == Journal.WEATHER_FOG
		and absf(float(e.get("hour", 0.0)) - 7.0) < 0.01)
	H.check("повторно не открывается", pt.check(Vector3(100, 20, 0)).is_empty() and got.size() == 1 and j.entries.size() == 1)
	H.check("all_places — с отметкой open", pt.all_places().map(func(p: Dictionary) -> bool: return p["open"]) == [true, false, false])
	pt.free()

	# После перечитывания журнала («Продолжить»).
	var j2 := Journal.load_or_new(PATH)
	var pt2 := PlaceTracker.new()
	pt2.setup(j2, null, data, null)
	H.check("после «Продолжить» открытое не открывается", pt2.check(Vector3(100, 20, 0)).is_empty() and j2.entries.size() == 1)
	H.check("без sink пишет прямо в журнал", pt2.check(Vector3(-280, 0, 40)) == ["bridge"]
		and j2.entries.back()["id"] == "bridge" and j2.places_count() == 2)
	H.check("места сохранены на диск", Journal.load_or_new(PATH).places_count() == 2)

	# Узел с таймером: проверка раз в CHECK_S, до готовности мира — нет.
	var car := Node3D.new()
	root.add_child(car)
	car.global_position = Vector3(0, 0, 500)
	pt2.target = car
	pt2._physics_process(1.0)
	H.check("до готовности мира не проверяет", not j2.is_place_open("shore"))
	pt2.active = true
	pt2._physics_process(0.1)
	H.check("раньше CHECK_S не проверяет", not j2.is_place_open("shore"))
	pt2._physics_process(0.2)
	H.check("через CHECK_S открывает", j2.is_place_open("shore"))
	pt2.free()
	car.queue_free()

	# Нет данных и журнала — не падает.
	var pe := PlaceTracker.new()
	pe.setup(j2, null, [], null)
	H.check("нет мест — ничего не открывается", pe.check(Vector3.ZERO).is_empty())
	var pn := PlaceTracker.new()
	H.check("без журнала — не падает", pn.check(Vector3.ZERO).is_empty() and pn.all_places().is_empty())
	pn._physics_process(1.0)
	pe.free()
	pn.free()

	Journal.reset(PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH + ".tmp"))
	H.finish(self)
