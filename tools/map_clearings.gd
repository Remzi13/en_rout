extends RefCounted
## Прогалины: где запекание (tools/bake_world.gd) не ставит деревья, кусты и
## камни. Лес рисуется в маске forest свободно, а место под постройки и точки
## доставок вырубается здесь — маску в map.blend править не нужно.
## Соглашение — docs/map-pipeline.md, тест — test_map_clearings.
##
## Прогалина — прямоугольник в плоскости XZ (центр, ось ax, полуразмеры half)
## плюс отступ pad вокруг него (углы скруглены):
##   - объект Props: габариты модели с поворотом и масштабом + clear_radius
##     пустышки (по умолчанию PROP_MARGIN_M; 0 — не вырубать);
##   - точка Spots: круг радиуса точки (half = 0, pad = radius).
## Места (Places) прогалин не делают.

const MapProps := preload("res://tools/map_props.gd")
const PROP_MARGIN_M := 3.0 ## отступ вокруг габаритов объекта, если нет clear_radius


## Прогалины объектов из MapProps.parse.
static func from_props(props: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for prop: Dictionary in props:
		var pad: float = prop.get("clear_radius", -1.0)
		if pad < 0.0:
			pad = PROP_MARGIN_M
		if pad <= 0.0:
			continue
		var box := MapProps.footprint(prop)
		var xf: Transform3D = prop["transform"]
		var c := xf * box.get_center()
		var ax := Vector2(xf.basis.x.x, xf.basis.x.z).normalized()
		out.append(_make(Vector2(c.x, c.z), ax, Vector2(box.size.x, box.size.z) * 0.5, pad))
	return out


## Прогалины точек доставок из MapPlaces.parse: круг радиуса точки.
static func from_spots(spots: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s: Dictionary in spots:
		var p: Vector3 = s["position"]
		out.append(_make(Vector2(p.x, p.z), Vector2.RIGHT, Vector2.ZERO, float(s["radius"])))
	return out


## Прогалины, задевающие прямоугольник rect (плоскость XZ) — чтобы чанк
## проверял только свои.
static func near(list: Array[Dictionary], rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c: Dictionary in list:
		if rect.grow(c["reach"]).has_point(c["center"]):
			out.append(c)
	return out


## Точка (x, z) внутри какой-нибудь прогалины.
static func blocked(list: Array[Dictionary], x: float, z: float) -> bool:
	for c: Dictionary in list:
		var d := Vector2(x, z) - (c["center"] as Vector2)
		var ax: Vector2 = c["ax"]
		var half: Vector2 = c["half"]
		var q := Vector2(absf(d.dot(ax)) - half.x, absf(d.dot(ax.orthogonal())) - half.y)
		if Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() < c["pad"]:
			return true
	return false


static func _make(center: Vector2, ax: Vector2, half: Vector2, pad: float) -> Dictionary:
	return {"center": center, "ax": ax, "half": half, "pad": pad, "reach": half.length() + pad}
