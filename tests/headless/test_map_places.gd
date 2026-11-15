extends SceneTree
## Места и точки доставок (коллекции Places и Spots из Blender -> поля
## places и spots сводки мира, tools/map_places.gd): разбор записей map.json
## на синтетических данных (умолчания, пропуск битых и повторов, высота по
## рельефу), сохранение и загрузка WorldIndex с этими полями, поля в
## запечённом world_index.tres.

const H := preload("res://tests/headless/helper.gd")
const MapPlaces := preload("res://tools/map_places.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	var slope := func(x: float, z: float) -> float: return 5.0 + x * 0.1 - z * 0.05
	var rect := Rect2(-512, -512, 1024, 1024)
	var src: Variant = JSON.parse_string("""[
		{"id": "lake_hill", "title": "Холм над озером", "radius": 40, "pos": [100.0, 99.0, -20.0]},
		{"id": "mill", "pos": [-30.0, 0.0, 10.0]},
		{"id": "lake_hill", "title": "Повтор", "pos": [0, 0, 0]},
		{"id": "", "title": "Пустой", "pos": [0, 0, 0]},
		{"title": "Без id", "pos": [0, 0, 0]},
		{"id": "nopos"},
		{"id": "far", "pos": [9000, 0, 0]},
		{"id": "bad_r", "radius": -3, "pos": [0, 0, 0]},
		"мусор"
	]""")
	var places := MapPlaces.parse(src, "Places", MapPlaces.PLACE_RADIUS_M, slope, rect)
	var ids := places.map(func(p: Dictionary) -> String: return p["id"])
	H.check("разбор: повтор, пустой id, без позиции, вне мира и мусор пропущены",
		ids == ["lake_hill", "mill", "bad_r"], "%s" % [ids])
	if places.size() != 3:
		H.finish(self)
		return
	var hill: Dictionary = places[0]
	H.check("поля записи: id, title, position, radius",
		hill.keys().size() == 4 and hill["title"] == "Холм над озером" and is_equal_approx(hill["radius"], 40.0)
		and hill["position"] is Vector3)
	var want := 5.0 + 100.0 * 0.1 + 20.0 * 0.05
	H.check("позиция из записи, высота по рельефу (не пустышки)",
		(hill["position"] as Vector3).is_equal_approx(Vector3(100.0, want, -20.0)), "%s" % hill["position"])
	H.check("без title — название равно id, радиус по умолчанию 25",
		places[1]["title"] == "mill" and is_equal_approx(places[1]["radius"], 25.0))
	H.check("плохой радиус — по умолчанию", is_equal_approx(places[2]["radius"], 25.0))

	var spots := MapPlaces.parse(JSON.parse_string("""[{"id": "smokehouse", "title": "Коптильня", "pos": [1, 2, 3]}]"""),
		"Spots", MapPlaces.SPOT_RADIUS_M, slope, rect)
	H.check("точка доставки: радиус по умолчанию 8",
		spots.size() == 1 and is_equal_approx(spots[0]["radius"], 8.0) and spots[0]["title"] == "Коптильня")
	H.check("нет коллекции (null) — пустой список",
		MapPlaces.parse(null, "Spots", MapPlaces.SPOT_RADIUS_M, slope, rect).is_empty()
		and MapPlaces.parse([], "Places", MapPlaces.PLACE_RADIUS_M, slope, rect).is_empty())

	# --- WorldIndex: поля переживают сохранение в .tres.
	var idx := WorldIndex.new()
	idx.places = places
	idx.spots = spots
	var path := "user://test_world_index_places.tres"
	var err := ResourceSaver.save(idx, path)
	var back := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as WorldIndex
	H.check("WorldIndex: места и точки сохраняются и читаются",
		err == OK and back != null and back.places.size() == 3 and back.spots.size() == 1
		and (back.places[0]["position"] as Vector3).is_equal_approx(hill["position"])
		and back.spots[0]["id"] == "smokehouse")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# --- Запечённая сводка: поля есть, записи в нужном формате, точки в мире.
	var base := WorldIndex.load_baked()
	var ok := true
	var wr := base.world_rect()
	for list: Array[Dictionary] in [base.places, base.spots]:
		for p: Dictionary in list:
			ok = ok and str(p.get("id", "")) != "" and p.get("position") is Vector3 and float(p.get("radius", 0)) > 0.0
			if ok:
				var pos: Vector3 = p["position"]
				ok = wr.has_point(Vector2(pos.x, pos.z))
	H.info("в запечённой сводке мест %d, точек %d" % [base.places.size(), base.spots.size()])
	H.check("запечённая сводка: places и spots в формате договора", ok)
	H.finish(self)
