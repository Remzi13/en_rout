extends SceneTree
## Логика погони без сцены: условия побега и захвата, сброс таймеров,
## подсчёт очков, таблица рекордов.

const H := preload("res://tests/headless/helper.gd")
const DT := 1.0 / 60.0


func _initialize() -> void:
	var cfg := ChaseConfig.new()
	var r := ChaseRules.new(cfg)

	# Побег: 8 с непрерывно дальше 300 м.
	var t := 0.0
	var out := ChaseRules.Outcome.NONE
	while out == ChaseRules.Outcome.NONE and t < 20.0:
		out = r.update(DT, 320.0, 150.0)
		t += DT
	H.check("побег через 8 с на дистанции > 300 м", out == ChaseRules.Outcome.ESCAPED and absf(t - 8.0) < 0.05, "%.2f с" % t)

	# Сброс таймера отрыва, если преследователь приблизился.
	r.reset()
	for i in 300:
		r.update(DT, 320.0, 150.0)
	r.update(DT, 250.0, 150.0)
	H.check("отрыв сбрасывается при сближении", r.escape_t == 0.0)

	# Захват: стоит (< 10 км/ч) и преследователь ближе 15 м 4 с подряд.
	r.reset()
	t = 0.0
	out = ChaseRules.Outcome.NONE
	while out == ChaseRules.Outcome.NONE and t < 20.0:
		out = r.update(DT, 8.0, 5.0)
		t += DT
	H.check("захват через 4 с", out == ChaseRules.Outcome.CAUGHT and absf(t - 4.0) < 0.05, "%.2f с" % t)

	r.reset()
	for i in 200:
		r.update(DT, 8.0, 5.0)
	r.update(DT, 8.0, 30.0)
	H.check("захват сбрасывается, если игрок поехал", r.capture_t == 0.0)
	r.reset()
	for i in 600:
		out = r.update(DT, 20.0, 0.0)
	H.check("нет захвата, если преследователь дальше 15 м", out == ChaseRules.Outcome.NONE)

	# Очки.
	var sc := ChaseScore.new(cfg)
	for i in 600: # 10 с
		sc.tick(DT, 150.0 if i == 100 else 100.0, i < 120)
	sc.add_near_miss()
	var expected := int(10.0 * 10.0 + 150.0 * 3.0 + 150.0 + 2.0 * 40.0)
	H.check("текущие очки", absi(sc.running_total() - expected) <= 2, "%d vs %d" % [sc.running_total(), expected])
	H.check("бонус за побег", sc.final_total(ChaseRules.Outcome.ESCAPED, 3) == sc.running_total() + 1000 + 750)
	H.check("пойман — половина очков", sc.final_total(ChaseRules.Outcome.CAUGHT, 3) == int(sc.running_total() * 0.5))

	# Рекорды: сортировка, обрезка до 10, сохранение и загрузка.
	var gs: Node = root.get_node("GameState")
	gs.save_path = "user://test_save.json"
	gs.records = []
	gs.stats = {"escapes": 0, "caught": 0, "distance_m": 0.0, "chases": 0}
	for i in 12:
		gs.add_record({"score": i * 100, "result": "escaped" if i % 2 == 0 else "caught", "duration": 1.0})
	H.check("рекордов не больше 10", gs.records.size() == 10)
	H.check("рекорды по убыванию очков", int(gs.records[0]["score"]) == 1100 and int(gs.records[9]["score"]) == 200)
	H.check("статистика побегов/поимок", int(gs.stats["escapes"]) == 6 and int(gs.stats["caught"]) == 6)
	gs.records = []
	gs.load_save()
	H.check("рекорды загружаются с диска", gs.records.size() == 10 and int(gs.records[0]["score"]) == 1100)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_save.json"))
	H.finish(self)
