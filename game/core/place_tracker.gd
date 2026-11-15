class_name PlaceTracker
extends Node
## Открытие мест: раз в CHECK_S сверяет позицию игрока (XZ) с местами из
## WorldIndex.places ({id, title, position, radius}). Первое попадание в
## радиус — journal.open_place(id, false), запись KIND_PLACE в журнал (через
## event_sink.add_event, обычно TripStats: время суток и погода; она же
## сохраняет журнал, одна запись на диск) и сигнал place_discovered.
## Открытые места берутся из журнала и повторно не открываются. Нет данных — ничего не делает.
## Правила в check(pos): тесты зовут его напрямую, без сцены.

signal place_discovered(id: String, title: String)

const CHECK_S := 0.25
const DEFAULT_RADIUS_M := 25.0

var journal: Journal
var target: Node3D
## Места мира: {id, title, position, radius}.
var places: Array[Dictionary] = []
## Куда писать запись: объект с add_event(kind, text, id) (TripStats).
## null — пишем прямо в журнал с полднем и ясной погодой.
var event_sink: Object
## Мир готов к игре (OpenWorld ставит после загрузки).
var active: bool = false

var _since_check_s: float = 0.0


func setup(j: Journal, car: Node3D, place_list: Array, sink: Object = null) -> void:
	journal = j
	target = car
	event_sink = sink
	places = normalize(place_list, DEFAULT_RADIUS_M)


## Места из сводки мира; нет поля places (старая сводка) или null — пусто.
static func from_index(idx: Object, field: String) -> Array:
	if idx == null:
		return []
	var v: Variant = idx.get(field)
	return v if v is Array else []


## Годные записи {id, title, position, radius}; негодные отбрасываются.
static func normalize(list: Array, default_radius: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Variant in list:
		if not p is Dictionary:
			continue
		var d := p as Dictionary
		var id: Variant = d.get("id")
		var pos: Variant = d.get("position")
		if typeof(id) != TYPE_STRING or id == "" or not pos is Vector3:
			continue
		var title: Variant = d.get("title", "")
		var r: Variant = d.get("radius", default_radius)
		var radius := float(r) if (typeof(r) == TYPE_FLOAT or typeof(r) == TYPE_INT) and float(r) > 0.0 else default_radius
		out.append({"id": id, "title": title if typeof(title) == TYPE_STRING and title != "" else id,
			"position": pos, "radius": radius})
	return out


func _physics_process(delta: float) -> void:
	if not active or target == null:
		return
	_since_check_s += delta
	if _since_check_s < CHECK_S:
		return
	_since_check_s = 0.0
	check(target.global_position)


## Открывает места, в радиус которых попала pos. Возвращает id открытых.
func check(pos: Vector3) -> Array[String]:
	var opened: Array[String] = []
	if journal == null:
		return opened
	for p in places:
		var id: String = p["id"]
		if journal.is_place_open(id):
			continue
		var c: Vector3 = p["position"]
		if Vector2(pos.x - c.x, pos.z - c.z).length() > float(p["radius"]):
			continue
		# Без сохранения: add_event/add_entry ниже сохранит место и запись разом.
		journal.open_place(id, false)
		var title: String = p["title"]
		if event_sink != null:
			event_sink.add_event(Journal.KIND_PLACE, title, id)
		else:
			journal.add_entry(Journal.KIND_PLACE, title, 12.0, Journal.WEATHER_CLEAR, id)
		opened.append(id)
		place_discovered.emit(id, title)
	return opened


## Места для карты и радара: {id, title, position, radius, open}.
func all_places() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in places:
		var d := p.duplicate()
		d["open"] = journal != null and journal.is_place_open(p["id"])
		out.append(d)
	return out
