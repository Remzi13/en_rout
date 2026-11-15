class_name Deliveries
extends Node
## Доставки: одна активная. Взять — стоять в радиусе точки from_spot
## (медленнее STOP_SPEED_MPS) и нажать interact; сдать — то же у to_spot.
## Точки — WorldIndex.spots ({id, title, position, radius}), доставки —
## DeliveryDef из game/missions/. Доставки, у которых нет точки на карте,
## не выдаются.
## Состояние живёт в журнале: сделанные — записи KIND_DELIVERY с id,
## активная — journal.active_delivery («Продолжить» её возвращает). При новой
## игре (журнал пустой) доставка с order = 1 выдаётся сразу активной.
## Если активную из журнала нельзя восстановить (её нет среди годных: файл
## убран или точки нет на карте), поле в журнале не стирается — в этой сессии
## активной просто нет, другие доставки можно брать, а поле перезапишется,
## только когда игрок возьмёт другую. Вернётся точка — «Продолжить» снова
## подхватит доставку.
## Сдача — запись с journal_text через event_sink.add_event (TripStats: время
## суток и погода) и сигнал delivery_completed.
## Правила — в start(), update_at(pos, speed), interact_at(pos, speed): тесты
## зовут их напрямую, без сцены; узел только подаёт позицию, скорость и
## нажатие interact.

signal prompt_changed(text: String)
signal delivery_taken(def: DeliveryDef)
signal delivery_completed(def: DeliveryDef)
signal target_changed(has_target: bool, position: Vector3)

const STOP_SPEED_MPS := 2.0
const DEFAULT_RADIUS_M := 8.0

var journal: Journal
var target: Node3D
## Годные доставки (обе точки есть на карте), по order.
var defs: Array[DeliveryDef] = []
## Точки: id -> {id, title, position, radius}.
var spots: Dictionary = {}
## Объект с add_event(kind, text, id) (TripStats); null — прямо в журнал.
var event_sink: Object
## Активная доставка или null.
var active: DeliveryDef
## Текущая подсказка («Взять: сети»); пусто — нет.
var prompt: String = ""
## Мир готов к игре (OpenWorld ставит после загрузки).
var enabled: bool = false

## Что можно сделать в текущей точке (для interact).
var _here_take: DeliveryDef
var _here_deliver: bool = false
## Кеш journal.delivered_ids(), обновляется по journal.entry_added.
var _done: Dictionary = {}


func setup(j: Journal, car: Node3D, spot_list: Array, def_list: Array, sink: Object = null) -> void:
	if journal != null and journal.entry_added.is_connected(_on_entry_added):
		journal.entry_added.disconnect(_on_entry_added)
	journal = j
	_done = j.delivered_ids() if j != null else {}
	if j != null:
		j.entry_added.connect(_on_entry_added)
	target = car
	event_sink = sink
	spots.clear()
	for s in PlaceTracker.normalize(spot_list, DEFAULT_RADIUS_M):
		spots[s["id"]] = s
	defs.clear()
	for d: Variant in def_list:
		var def := d as DeliveryDef
		if def == null:
			continue
		if not spots.has(def.from_spot) or not spots.has(def.to_spot):
			push_warning("Доставка %s: нет точки %s или %s на карте — не выдаётся" % [def.id, def.from_spot, def.to_spot])
			continue
		defs.append(def)


## Восстанавливает активную из журнала или выдаёт первую при новой игре.
## Зовётся после setup, когда интерфейс уже подписан на сигналы.
func start() -> void:
	active = null
	if journal == null:
		return
	_done = journal.delivered_ids()
	var stuck := false
	if journal.active_delivery != "":
		var def := find(journal.active_delivery)
		if _done.has(journal.active_delivery):
			# Уже сдана — поле устарело, его можно стереть.
			journal.active_delivery = ""
			journal.save()
		elif def != null:
			active = def
		else:
			# Нет среди годных (убрана или нет точки на карте): поле не трогаем,
			# в этой сессии активной нет. Первую поверх неё не выдаём.
			push_warning("Активная доставка %s не найдена или без точки на карте — в этой сессии не активна" % journal.active_delivery)
			stuck = true
	if active == null and not stuck and journal.entries.is_empty():
		for def in defs:
			if def.order == 1 and not _done.has(def.id):
				_take(def)
				break
	_emit_target()


func find(id: String) -> DeliveryDef:
	for def in defs:
		if def.id == id:
			return def
	return null


func is_done(def: DeliveryDef) -> bool:
	return journal != null and _done.has(def.id)


## Точки, где сейчас можно что-то взять: {id, title, position, radius,
## delivery_id, cargo}. Пока есть активная доставка — пусто.
func available_spots() -> Array:
	var out: Array = []
	if active != null or journal == null:
		return out
	for def in defs:
		if _done.has(def.id):
			continue
		var s: Dictionary = spots[def.from_spot].duplicate()
		s["delivery_id"] = def.id
		s["cargo"] = def.cargo
		out.append(s)
	return out


func has_target() -> bool:
	return active != null


## Точка сдачи активной доставки (Vector3.ZERO, если её нет).
func target_position() -> Vector3:
	return spots[active.to_spot]["position"] if active != null else Vector3.ZERO


## Пересчитывает подсказку по позиции и скорости машины.
func update_at(pos: Vector3, speed_mps: float) -> void:
	_here_take = null
	_here_deliver = false
	var text := ""
	if journal != null and speed_mps < STOP_SPEED_MPS:
		if active != null:
			if _inside(active.to_spot, pos):
				_here_deliver = true
				text = "Сдать: " + active.cargo
		else:
			for def in defs:
				if not _done.has(def.id) and _inside(def.from_spot, pos):
					_here_take = def
					text = "Взять: " + def.cargo
					break
	if text != prompt:
		prompt = text
		prompt_changed.emit(prompt)


## Нажатие interact: берёт или сдаёт доставку, если стоим в точке.
## true — что-то произошло.
func interact_at(pos: Vector3, speed_mps: float) -> bool:
	update_at(pos, speed_mps)
	var acted := false
	if _here_deliver:
		_complete()
		acted = true
	elif _here_take != null:
		_take(_here_take)
		_emit_target()
		acted = true
	if acted:
		update_at(pos, speed_mps)
	return acted


func _take(def: DeliveryDef) -> void:
	active = def
	journal.active_delivery = def.id
	journal.save()
	delivery_taken.emit(def)


func _complete() -> void:
	var def := active
	active = null
	journal.active_delivery = ""
	if event_sink != null:
		event_sink.add_event(Journal.KIND_DELIVERY, def.journal_text, def.id)
	else:
		journal.add_entry(Journal.KIND_DELIVERY, def.journal_text, 12.0, Journal.WEATHER_CLEAR, def.id)
	delivery_completed.emit(def)
	_emit_target()


func _on_entry_added(entry: Dictionary) -> void:
	if entry.get("kind", "") == Journal.KIND_DELIVERY and entry.get("id", "") != "":
		_done[entry["id"]] = true


func _inside(spot_id: String, pos: Vector3) -> bool:
	var s: Dictionary = spots.get(spot_id, {})
	if s.is_empty():
		return false
	var c: Vector3 = s["position"]
	return Vector2(pos.x - c.x, pos.z - c.z).length() <= float(s["radius"])


func _emit_target() -> void:
	target_changed.emit(has_target(), target_position())


func _speed() -> float:
	var body := target as RigidBody3D
	return body.linear_velocity.length() if body != null else 0.0


func _physics_process(_delta: float) -> void:
	if enabled and target != null:
		update_at(target.global_position, _speed())


func _unhandled_input(event: InputEvent) -> void:
	if enabled and target != null and event.is_action_pressed("interact"):
		if interact_at(target.global_position, _speed()):
			get_viewport().set_input_as_handled()
