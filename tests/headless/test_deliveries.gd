extends SceneTree
## Доставки без сцены (Deliveries на подставных точках и DeliveryDef):
## первая выдаётся при пустом журнале, взять можно только остановившись в
## радиусе точки, одна активная, сдача пишет запись с id в журнал,
## «Продолжить» возвращает активную, сделанная больше не предлагается,
## без данных ничего не падает. Пишет только в user://test_deliveries*.json.

const H := preload("res://tests/headless/helper.gd")
const PATH := "user://test_deliveries.json"


## Как TripStats.add_event, но с заданными временем и погодой.
class FakeSink:
	var journal: Journal
	func add_event(kind: String, text: String, id: String = "") -> Dictionary:
		return journal.add_entry(kind, text, 19.0, Journal.WEATHER_RAIN, id)


func _initialize() -> void:
	_run()


func _spot(id: String, x: float, z: float, r: Variant = null) -> Dictionary:
	var s := {"id": id, "title": id.capitalize(), "position": Vector3(x, 3.0, z)}
	if r != null:
		s["radius"] = r
	return s


func _def(id: String, cargo: String, from: String, to: String, order: int) -> DeliveryDef:
	var d := DeliveryDef.new()
	d.id = id
	d.cargo = cargo
	d.from_spot = from
	d.to_spot = to
	d.journal_text = "Отвёз " + cargo
	d.order = order
	return d


func _make(j: Journal, sink: Object) -> Deliveries:
	var spots := [_spot("smokehouse", 0, 0), _spot("far_end", 500, 0), _spot("store", 100, 100, 10.0),
		_spot("pier", -200, 50), _spot("workshop", 0, 300)]
	var defs := [_def("fish", "копчёная рыба", "smokehouse", "far_end", 1),
		_def("nets", "сети", "store", "pier", 2), _def("motor", "лодочный мотор", "workshop", "store", 3),
		_def("ghost", "ничего", "nowhere", "pier", 4)]
	var dl := Deliveries.new()
	dl.setup(j, null, spots, defs, sink)
	return dl


func _run() -> void:
	await process_frame
	# Ресурсы из game/missions.
	var all := DeliveryDef.load_all()
	H.check("доставки грузятся из game/missions", all.size() >= 1 and all[0].order == 1, "%d шт." % all.size())
	H.check("заглушка delivery_test на месте", all.any(func(d: DeliveryDef) -> bool:
		return d.id == "test" and d.from_spot == "test_from" and d.to_spot == "test_to"))
	H.check("нет папки — пустой список", DeliveryDef.load_all("res://нет_такой").is_empty())

	# Нет данных — ничего не падает.
	Journal.reset(PATH)
	var j0 := Journal.load_or_new(PATH)
	var d0 := Deliveries.new()
	d0.setup(j0, null, [], all, null)
	d0.start()
	d0.update_at(Vector3.ZERO, 0.0)
	H.check("без точек: доставок нет, ничего не выдано", d0.defs.is_empty() and d0.active == null
		and d0.available_spots().is_empty() and not d0.interact_at(Vector3.ZERO, 0.0) and d0.prompt == "")
	var dn := Deliveries.new()
	dn.start()
	dn.update_at(Vector3.ZERO, 0.0)
	H.check("без журнала и данных: не падает", dn.available_spots().is_empty() and not dn.interact_at(Vector3.ZERO, 0.0))
	d0.free()
	dn.free()

	# Новая игра: первая выдаётся сразу.
	Journal.reset(PATH)
	var j := Journal.load_or_new(PATH)
	var sink := FakeSink.new()
	sink.journal = j
	var dl := _make(j, sink)
	H.check("доставка без точки на карте пропущена", dl.find("ghost") == null and dl.defs.size() == 3)
	var targets: Array = []
	var prompts: Array[String] = []
	var taken: Array[String] = []
	var completed: Array[String] = []
	dl.target_changed.connect(func(has: bool, p: Vector3) -> void: targets.append([has, p]))
	dl.prompt_changed.connect(func(t: String) -> void: prompts.append(t))
	dl.delivery_taken.connect(func(d: DeliveryDef) -> void: taken.append(d.id))
	dl.delivery_completed.connect(func(d: DeliveryDef) -> void: completed.append(d.id))
	dl.start()
	H.check("при пустом журнале первая (order 1) активна", dl.active != null and dl.active.id == "fish"
		and taken == ["fish"])
	H.check("активная записана в журнал и на диск", j.active_delivery == "fish"
		and Journal.load_or_new(PATH).active_delivery == "fish")
	H.check("target_changed на точку сдачи", targets.size() == 1 and targets[0][0] == true
		and targets[0][1] == Vector3(500, 3, 0))
	H.check("пока есть активная, взять негде", dl.available_spots().is_empty())

	# Одна активная: у склада сетей стоим — взять нельзя.
	dl.update_at(Vector3(100, 0, 100), 0.0)
	H.check("с активной вторую не взять", dl.prompt == "" and not dl.interact_at(Vector3(100, 0, 100), 0.0)
		and dl.active.id == "fish")

	# Сдача: только стоя в радиусе.
	dl.update_at(Vector3(495, 0, 0), 10.0)
	H.check("на ходу подсказки нет", dl.prompt == "" and not dl.interact_at(Vector3(495, 0, 0), 10.0))
	dl.update_at(Vector3(490, 0, 0), 0.5)
	H.check("вне радиуса (10 м при 8) подсказки нет", dl.prompt == "")
	dl.update_at(Vector3(495, 50, 0), 1.5)
	H.check("стоим в радиусе — «Сдать: копчёная рыба»", dl.prompt == "Сдать: копчёная рыба"
		and prompts.back() == "Сдать: копчёная рыба", dl.prompt)
	var n_entries := j.entries.size()
	H.check("сдача по interact", dl.interact_at(Vector3(495, 50, 0), 1.5) and completed == ["fish"] and dl.active == null)
	var e: Dictionary = j.entries.back() if j.entries.size() > n_entries else {}
	H.check("запись в журнале: текст, id, время и погода", e.get("kind") == Journal.KIND_DELIVERY
		and e.get("text") == "Отвёз копчёная рыба" and e.get("id") == "fish" and e.get("weather") == Journal.WEATHER_RAIN
		and absf(float(e.get("hour", 0.0)) - 19.0) < 0.01)
	H.check("после сдачи цели нет, активной в журнале нет", targets.back()[0] == false and j.active_delivery == ""
		and dl.prompt == "")
	H.check("сделанная читается с диска по id", Journal.load_or_new(PATH).delivered_ids().has("fish"))
	var avail := dl.available_spots()
	var avail_ids := avail.map(func(s: Dictionary) -> String: return s["delivery_id"])
	H.check("available_spots — точки взятия несделанных", avail_ids == ["nets", "motor"]
		and avail[0]["id"] == "store" and avail[0]["cargo"] == "сети" and avail[0]["position"] is Vector3, str(avail_ids))

	# Взять: только стоя в радиусе точки (радиус склада 10 м).
	H.check("взять на ходу нельзя", not dl.interact_at(Vector3(105, 0, 100), 3.0) and dl.active == null)
	H.check("взять вне радиуса нельзя", not dl.interact_at(Vector3(112, 0, 100), 0.0) and dl.active == null)
	H.check("у сделанной точки взять нечего", not dl.interact_at(Vector3(0, 0, 0), 0.0) and dl.active == null)
	dl.update_at(Vector3(108, 0, 100), 0.0)
	H.check("подсказка «Взять: сети»", dl.prompt == "Взять: сети", dl.prompt)
	H.check("взять стоя в радиусе", dl.interact_at(Vector3(108, 0, 100), 0.0) and dl.active.id == "nets"
		and taken.back() == "nets" and targets.back() == [true, Vector3(-200, 3, 50)])
	H.check("после взятия подсказка «Сдать» не висит у точки взятия", dl.prompt == "")
	dl.free()

	# «Продолжить»: активная возвращается, первая не выдаётся повторно.
	var j2 := Journal.load_or_new(PATH)
	var dl2 := _make(j2, null)
	var t2: Array = []
	dl2.target_changed.connect(func(has: bool, p: Vector3) -> void: t2.append([has, p]))
	dl2.start()
	H.check("«Продолжить» вернуло активную", dl2.active != null and dl2.active.id == "nets"
		and t2 == [[true, Vector3(-200, 3, 50)]])
	dl2.interact_at(Vector3(-200, 0, 50), 0.0)
	H.check("сдача без sink пишет прямо в журнал", j2.delivered_ids().has("nets") and j2.entries.back()["id"] == "nets")
	dl2.interact_at(Vector3(0, 0, 300), 0.0)
	dl2.interact_at(Vector3(100, 0, 100), 0.0)
	H.check("все три сделаны — маркеров нет, взять нечего", j2.deliveries_count() == 3
		and dl2.available_spots().is_empty() and dl2.active == null and not dl2.interact_at(Vector3(0, 0, 0), 0.0))
	dl2.free()

	# Активная из журнала, которой больше нет (или уже сделана), — сбрасывается.
	var j3 := Journal.load_or_new(PATH)
	j3.active_delivery = "removed_one"
	var dl3 := _make(j3, null)
	dl3.start()
	H.check("неизвестная активная сброшена, первая не выдана (журнал не пустой)",
		dl3.active == null and j3.active_delivery == "")
	dl3.free()

	# Старый журнал без id и active_delivery читается.
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string("{\"version\": 1, \"entries\": [{\"kind\": \"delivery\", \"text\": \"старая\"}], \"places\": []}")
	f.close()
	var jo := Journal.load_or_new(PATH)
	H.check("старый журнал без id читается", jo.entries.size() == 1 and jo.entries[0]["id"] == ""
		and jo.active_delivery == "" and jo.delivered_ids().is_empty())

	Journal.reset(PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH + ".tmp"))
	H.finish(self)
