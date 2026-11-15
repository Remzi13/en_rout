extends RefCounted
## Места и точки доставок: пустышки коллекций Places и Spots из
## art/map/map.blend -> поля places и spots сводки мира (WorldIndex).
## В чанки не попадают. Соглашение о свойствах — docs/map-pipeline.md.
## Используется запеканием (tools/bake_world.gd) и тестом test_map_places.
##
## Запись в map.json (её пишет tools/blender/export_map.py, оси уже Godot):
##   {id, title, radius: м, pos: [x, y, z]}
## Результат: {id: String, title: String, position: Vector3, radius: float},
## высота position — по рельефу (ground), а не у пустышки.

const PLACE_RADIUS_M := 25.0
const SPOT_RADIUS_M := 8.0


## Проверяет записи коллекции label ("Places" или "Spots"). Битые, с пустым
## или повторным id и вне rect (плоскость XZ) — предупреждение и пропуск.
## ground(x, z) -> высота рельефа.
static func parse(list: Variant, label: String, default_radius: float, ground: Callable,
		rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not list is Array:
		return out
	var seen := {}
	for item: Variant in list:
		if not item is Dictionary:
			push_warning("%s: запись не словарь — пропускаю" % label)
			continue
		var d: Dictionary = item
		var id := str(d.get("id", "")).strip_edges()
		if id == "":
			push_warning("%s: запись без id — пропускаю" % label)
			continue
		if seen.has(id):
			push_warning("%s/%s: повтор id — пропускаю" % [label, id])
			continue
		var p: Variant = d.get("pos")
		if not p is Array or (p as Array).size() != 3:
			push_warning("%s/%s: нет позиции — пропускаю" % [label, id])
			continue
		var x := float(p[0])
		var z := float(p[2])
		if not rect.has_point(Vector2(x, z)):
			push_warning("%s/%s: вне мира (%.0f, %.0f) — пропускаю" % [label, id, x, z])
			continue
		seen[id] = true
		var radius := float(d.get("radius", default_radius))
		if radius <= 0.0:
			radius = default_radius
		var title := str(d.get("title", "")).strip_edges()
		out.append({
			"id": id,
			"title": title if title != "" else id,
			"position": Vector3(x, float(ground.call(x, z)), z),
			"radius": radius,
		})
	return out
