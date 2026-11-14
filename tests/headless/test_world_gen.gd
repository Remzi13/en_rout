extends SceneTree
## Процедурный мир: детерминизм по сиду, непрерывность дорог через узлы,
## стыковка рельефа на границе чанков, время генерации чанка.

const H := preload("res://tests/headless/helper.gd")


func _initialize() -> void:
	var a := WorldGen.new(12345)
	var b := WorldGen.new(12345)
	var c := WorldGen.new(777)

	H.check("высота одинакова при одном сиде", is_equal_approx(a.base_height(1234.5, -987.0), b.base_height(1234.5, -987.0)))
	H.check("разные сиды — разный мир", not is_equal_approx(a.base_height(1234.5, -987.0), c.base_height(1234.5, -987.0)))

	var t0 := Time.get_ticks_msec()
	var d1 := a.build_chunk_data(Vector2i(0, 0))
	var gen_ms := Time.get_ticks_msec() - t0
	var d2 := b.build_chunk_data(Vector2i(0, 0))
	var v1: PackedVector3Array = d1["terrain"]["vertices"]
	var v2: PackedVector3Array = d2["terrain"]["vertices"]
	H.check("чанк детерминирован по сиду", v1 == v2)
	H.info("генерация чанка: %d мс" % gen_ms)
	H.check("генерация чанка < 1500 мс", gen_ms < 1500, "%d мс" % gen_ms)

	# Стык рельефа: правый край чанка (0,0) = левый край чанка (1,0).
	var d3 := a.build_chunk_data(Vector2i(1, 0))
	var v3: PackedVector3Array = d3["terrain"]["vertices"]
	var n := WorldGen.GRID_N + 1
	var max_gap := 0.0
	for gz in n:
		max_gap = maxf(max_gap, absf(v1[gz * n + (n - 1)].y - v3[gz * n].y))
	H.check("рельеф стыкуется на границе чанков", max_gap < 0.001, "разрыв %.4f м" % max_gap)

	# Дороги: у стартового узла есть рёбра, концы рёбер совпадают с узлами.
	var links := a.node_links(Vector2i.ZERO)
	H.check("у стартового узла есть дороги", links.size() >= 2, "%d" % links.size())
	var worst := 0.0
	for i in range(-2, 3):
		for j in range(-2, 3):
			for dir in 2:
				var cell := Vector2i(i, j)
				if not a.has_edge(cell, dir):
					continue
				var e := a.make_edge(cell, dir)
				worst = maxf(worst, e.points[0].distance_to(a.node_pos3(cell)))
				worst = maxf(worst, e.points[e.points.size() - 1].distance_to(a.node_pos3(e.b_cell)))
	H.check("концы дорог совпадают с узлами", worst < 0.01, "%.4f м" % worst)

	var e0 := a.make_edge(Vector2i.ZERO, 0)
	var max_step := 0.0
	var max_grade := 0.0
	for k in e0.points.size() - 1:
		var p := e0.points[k]
		var q := e0.points[k + 1]
		max_step = maxf(max_step, p.distance_to(q))
		max_grade = maxf(max_grade, absf(q.y - p.y) / maxf(Vector2(q.x - p.x, q.z - p.z).length(), 0.01))
	H.check("шаг точек дороги ~4 м", max_step < 6.0, "%.2f" % max_step)
	H.info("макс. уклон дороги: %.1f%%" % (max_grade * 100.0))
	H.check("дорога проходима (уклон < 35%)", max_grade < 0.35, "%.1f%%" % (max_grade * 100.0))
	H.check("дорога выше воды", e0.points[e0.points.size() / 2].y >= WorldGen.ROAD_MIN_Y - 0.01)

	var near := a.nearest_road(Vector3(e0.points[10].x + 3.0, 0.0, e0.points[10].z))
	H.check("nearest_road находит дорогу", not near.is_empty() and float(near["dist"]) < 5.0)

	var roads: Dictionary = d1["roads"]
	var tri := (roads[WorldGen.RoadType.HIGHWAY]["indices"] as PackedInt32Array).size() + (roads[WorldGen.RoadType.DIRT]["indices"] as PackedInt32Array).size()
	H.info("индексов дорог в чанке (0,0): %d, деревьев: %d" % [tri, (d1["vegetation"]["conifer"] as Array).size() + (d1["vegetation"]["leafy"] as Array).size()])
	H.finish(self)
