extends SceneTree
## Прогалины при запекании (tools/map_clearings.gd): на синтетических данных
## растительность не попадает в пятно объекта Props (габариты модели с
## поворотом и масштабом + отступ) и в круг точки Spots, clear_radius
## переопределяет отступ, clear_radius = 0 отключает вырубку.

const H := preload("res://tests/headless/helper.gd")
const MapProps := preload("res://tools/map_props.gd")
const MapClearings := preload("res://tools/map_clearings.gd")
const VAN := "res://game/cars/models/car_van.glb"


func _initialize() -> void:
	_run()


func _run() -> void:
	var src: Array = JSON.parse_string("""[
		{"name": "Дом", "model": "%s", "pos": [100.0, 5.0, 50.0], "yaw": 0.5236, "scale": [2.0, 1.0, 1.5]},
		{"name": "Широкий", "model": "%s", "pos": [300.0, 0.0, 50.0], "clear_radius": 6},
		{"name": "Без вырубки", "model": "%s", "pos": [500.0, 0.0, 50.0], "clear_radius": 0},
		{"name": "Плохой", "model": "%s", "pos": [700.0, 0.0, 50.0], "clear_radius": "много"}
	]""" % [VAN, VAN, VAN, VAN])
	var props := MapProps.parse(src)
	H.check("clear_radius читается: нет/плохой — −1, иначе число",
		props.size() == 4 and props[0]["clear_radius"] == -1.0 and props[1]["clear_radius"] == 6.0
		and props[2]["clear_radius"] == 0.0 and props[3]["clear_radius"] == -1.0)
	var spots: Array[Dictionary] = [{"id": "shop", "title": "Лавка", "position": Vector3(100, 3, 200), "radius": 8.0}]
	var list := MapClearings.from_props(props)
	list.append_array(MapClearings.from_spots(spots))
	H.check("clear_radius = 0: объект без прогалины", list.size() == 4, "прогалин %d из 5" % list.size())
	H.check("clear_radius = 0: в центре объекта можно сажать", not MapClearings.blocked(list, 500.0, 50.0))

	# Пятно дома: габариты с масштабом в осях дома (поворот 30°) + отступ 3 м.
	var house: Dictionary = props[0]
	var box := MapProps.footprint(house)
	var xf: Transform3D = house["transform"]
	var m := MapClearings.PROP_MARGIN_M
	var inside_ok := true
	var outside_ok := true
	var n_in := 0
	var n_out := 0
	for i in range(-40, 41):
		for j in range(-40, 41):
			var w := xf.origin + Vector3(i * 0.5, 0.0, j * 0.5)
			var l := xf.affine_inverse() * w # в осях дома, без масштаба
			var dx := maxf(absf(l.x - box.get_center().x) - box.size.x * 0.5, 0.0)
			var dz := maxf(absf(l.z - box.get_center().z) - box.size.z * 0.5, 0.0)
			var d := Vector2(dx, dz).length()
			var b := MapClearings.blocked(list, w.x, w.z)
			if d < m - 0.05:
				n_in += 1
				inside_ok = inside_ok and b
			elif d > m + 0.05:
				n_out += 1
				outside_ok = outside_ok and not b
	H.check("пятно объекта: габариты с поворотом и масштабом + %.0f м вырублены" % m, inside_ok and n_in > 100, "точек %d" % n_in)
	H.check("за пятном объекта растительность не трогается", outside_ok and n_out > 100, "точек %d" % n_out)
	var sx := box.size.x * 0.5
	var c := xf * box.get_center()
	var side := xf.basis.x # от центра вдоль ширины дома
	H.check("масштаб учтён: край по ширине дальше, чем у модели без масштаба",
		MapClearings.blocked(list, c.x + side.x * (sx + m - 0.2), c.z + side.z * (sx + m - 0.2))
		and not MapClearings.blocked(list, c.x + side.x * (sx + m + 0.2), c.z + side.z * (sx + m + 0.2)))

	# clear_radius = 6 переопределяет отступ.
	var wide: Dictionary = props[1]
	var wb := MapProps.footprint(wide)
	var wc: Vector3 = (wide["transform"] as Transform3D) * wb.get_center()
	var edge := wb.size.x * 0.5
	H.check("clear_radius = 6: отступ 6 м вместо %.0f" % m,
		MapClearings.blocked(list, wc.x + edge + 5.8, wc.z) and not MapClearings.blocked(list, wc.x + edge + 6.2, wc.z))

	# Точка доставки: круг её радиуса.
	H.check("точка доставки: круг радиуса точки вырублен",
		MapClearings.blocked(list, 100.0 + 7.9, 200.0) and MapClearings.blocked(list, 100.0, 200.0 - 7.9)
		and not MapClearings.blocked(list, 100.0 + 8.1, 200.0) and not MapClearings.blocked(list, 105.8, 205.8))

	# near: чанк получает только свои прогалины.
	var mine := MapClearings.near(list, Rect2(0, 0, 256, 256))
	H.check("near: чанку — только задевающие его прогалины", mine.size() == 2, "%d" % mine.size())

	# Расстановка как у запекания (шаг 7 м со сдвигом): в пятна ничего не попадает.
	var hit := 0
	var placed := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for j in 36:
		for i in 36:
			var x := (i + rng.randf_range(0.15, 0.85)) * 7.0
			var z := (j + rng.randf_range(0.15, 0.85)) * 7.0
			if MapClearings.blocked(mine, x, z):
				continue
			placed += 1
			var l := xf.affine_inverse() * Vector3(x, 0.0, z)
			var in_box := absf(l.x - box.get_center().x) <= box.size.x * 0.5 and absf(l.z - box.get_center().z) <= box.size.z * 0.5
			if in_box or Vector2(x, z).distance_to(Vector2(100, 200)) < 8.0:
				hit += 1
	H.check("расстановка: ни одного дерева в пятне объекта и точки", hit == 0 and placed > 1200,
		"поставлено %d, в пятнах %d" % [placed, hit])
	H.finish(self)
