extends SceneTree
## Бортовой журнал без сцены: запись и чтение файла, битый и пустой файл,
## старая версия, повторное открытие места, сигнал entry_added, подсчёт
## статистики (км, дождь, ночь) счётчиком TripStats на подставных данных.
## Атомарное сохранение (.tmp), битый файл откладывается в .bad.json, журнал
## будущей версии — в .v<N>.json; мусорные записи и места отбрасываются;
## TripStats не считает до готовности мира, стоянку, вертикаль и респаун.
## Пишет только в user://test_journal*.json и удаляет за собой.

const H := preload("res://tests/headless/helper.gd")
const DT := 1.0 / 60.0
const PATH := "user://test_journal.json"
const BAD_PATH := "user://test_journal.bad.json"
const V2_PATH := "user://test_journal.v2.json"
const TMP_PATH := "user://test_journal.json.tmp"

# Weather и TripStats обращаются к автозагрузке GameState, которую -s скрипт
# не видит при компиляции, — грузим их в рантайме.
var WeatherScript: GDScript
var TripStatsScript: GDScript


func _initialize() -> void:
	_run()


func _write(text: String) -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _run() -> void:
	await process_frame # корень дерева готов: global_position машины работает
	WeatherScript = load("res://game/world/weather.gd")
	TripStatsScript = load("res://game/core/trip_stats.gd")
	Journal.reset(PATH)
	H.check("нет файла — нет сохранения", not Journal.has_save(PATH))
	var j := Journal.load_or_new(PATH)
	H.check("новый журнал пустой", j.entries.is_empty() and j.places_count() == 0 and j.distance_m == 0.0)

	# Записи, сигнал и сохранение при событии.
	var got: Array[Dictionary] = []
	j.entry_added.connect(func(e: Dictionary) -> void: got.append(e))
	j.add_entry(Journal.KIND_DELIVERY, "Привёз копчёную рыбу", 18.5, Journal.WEATHER_RAIN)
	H.check("сигнал entry_added", got.size() == 1 and got[0]["text"] == "Привёз копчёную рыбу")
	H.check("запись сохраняется сразу", Journal.has_save(PATH))
	H.check("подпись момента", Journal.moment_text(18.5, Journal.WEATHER_RAIN) == "Вечер, дождь",
		Journal.moment_text(18.5, Journal.WEATHER_RAIN))

	# Места: повторное открытие.
	H.check("место открывается", j.open_place("hill_view"))
	H.check("повторно место не открывается", not j.open_place("hill_view"))
	H.check("is_place_open", j.is_place_open("hill_view") and not j.is_place_open("old_bridge"))
	j.add_entry(Journal.KIND_PLACE, "Вид с холма", 7.0, Journal.WEATHER_CLEAR)
	H.check("счётчики доставок и мест", j.deliveries_count() == 1 and j.places_count() == 1)

	# Статистика на подставных данных: 10 с ясным днём, 10 с дождём, 10 с ночью, по 20 м/с.
	var car := Node3D.new()
	root.add_child(car)
	var weather = WeatherScript.new()
	var ts = TripStatsScript.new()
	ts.setup(j, car, weather, null)
	# До готовности мира (active) не считаем ничего.
	car.position.x += 1.0
	ts.tick(DT)
	car.position.x += 1.0
	ts.tick(DT)
	H.check("до готовности мира статистика не идёт", j.distance_m == 0.0 and j.drive_time_s == 0.0)
	ts.active = true
	var gs: Node = root.get_node("GameState")
	for phase in ["day", "rain", "night"]:
		weather.rain_k = 1.0 if phase == "rain" else 0.0
		gs.is_night = phase == "night"
		for i in 600:
			car.position.x += 20.0 * DT
			ts.tick(DT)
	gs.is_night = false
	# Телепорт (респаун) не добавляет путь.
	car.position.x += 500.0
	ts.tick(DT)
	H.check("пройдено ~600 м", absf(j.distance_m - 600.0) < 1.0, "%.1f м" % j.distance_m)
	H.check("под дождём ~200 м", absf(j.rain_distance_m - 200.0) < 1.0, "%.1f м" % j.rain_distance_m)
	H.check("ночью ~200 м", absf(j.night_distance_m - 200.0) < 1.0, "%.1f м" % j.night_distance_m)
	H.check("время за рулём ~30 с", absf(j.drive_time_s - 30.0) < 0.1, "%.2f с" % j.drive_time_s)
	H.check("сводка stats() в км", absf(float(j.stats()["distance_km"]) - 0.6) < 0.001 and int(j.stats()["places"]) == 1)
	H.check("автосохранение не раньше 45 с", ts._since_save_s > 29.0)
	for i in int(16.0 / DT):
		ts.tick(DT)
	H.check("автосохранение раз в 45 с", ts._since_save_s < 5.0)
	H.check("после сохранения нет .tmp", not FileAccess.file_exists(TMP_PATH))

	# Стоянка, вертикаль, респаун.
	var d_before := j.distance_m
	var t_before := j.drive_time_s
	for i in 120:
		ts.tick(DT)
	H.check("на стоянке время за рулём не идёт", is_equal_approx(j.drive_time_s, t_before),
		"+%.2f с" % (j.drive_time_s - t_before))
	for i in 60:
		car.position.y -= 10.0 * DT
		ts.tick(DT)
	H.check("падение по вертикали не даёт метров", is_equal_approx(j.distance_m, d_before),
		"+%.2f м" % (j.distance_m - d_before))
	ts.reset_track()
	car.position.z += 30.0
	ts.tick(DT)
	H.check("респаун (reset_track) не даёт метров", is_equal_approx(j.distance_m, d_before),
		"+%.2f м" % (j.distance_m - d_before))
	car.position.z += 30.0
	ts.tick(DT)
	H.check("рывок 30 м без респауна засчитан (запасной порог 50 м)", absf(j.distance_m - d_before - 30.0) < 0.01)
	j.distance_m = d_before

	# Чтение с диска.
	j.save()
	var j2 := Journal.load_or_new(PATH)
	H.check("записи читаются с диска", j2.entries.size() == 2 and j2.entries[0]["kind"] == Journal.KIND_DELIVERY
		and j2.entries[0]["weather"] == Journal.WEATHER_RAIN and absf(float(j2.entries[0]["hour"]) - 18.5) < 0.01)
	H.check("места читаются с диска", j2.is_place_open("hill_view") and j2.places_count() == 1)
	H.check("статистика читается с диска", absf(j2.distance_m - j.distance_m) < 0.01
		and absf(j2.rain_distance_m - 200.0) < 1.0 and absf(j2.drive_time_s - j.drive_time_s) < 0.01)
	H.check("в записи есть реальное время", int(j2.entries[0]["unix_time"]) > 1_600_000_000)

	# Битый, пустой и старый файл — журнал заново, без падения.
	for bad in ["{ это не json", "{}", "", "[1, 2]", "{\"version\": 0, \"entries\": [{\"text\": \"x\"}]}",
			"{\"version\": 1, \"entries\": 5, \"places\": {\"a\": 1}, \"stats\": {\"distance_m\": \"много\"}}"]:
		_write(bad)
		var jb := Journal.load_or_new(PATH)
		H.check("негодный файл → пустой журнал: %s" % bad.left(24),
			jb != null and jb.entries.is_empty() and jb.places_count() == 0 and jb.distance_m == 0.0)

	# Битый файл откладывается в .bad.json (перезаписывая прежний).
	_write("{ битый 1")
	Journal.load_or_new(PATH)
	_write("{ битый 2")
	var jbad := Journal.load_or_new(PATH)
	H.check("битый файл отложен в .bad.json", FileAccess.file_exists(BAD_PATH)
		and FileAccess.get_file_as_string(BAD_PATH) == "{ битый 2" and not FileAccess.file_exists(PATH))
	H.check("после битого файла журнал пишется заново", jbad.save() and Journal.load_or_new(PATH).entries.is_empty())

	# Мусорные записи и места отбрасываются, остальное читается.
	_write("{\"version\": 1, \"entries\": [{\"kind\": 5, \"text\": \"a\"}, {\"kind\": \"delivery\", \"text\": null},"
		+ " {\"kind\": \"delivery\", \"text\": \"ok\", \"hour\": \"вечер\"}], \"places\": [{\"x\": 1}, 7, null, \"hill\"]}")
	var jm := Journal.load_or_new(PATH)
	H.check("негодные записи отброшены", jm.entries.size() == 1 and jm.deliveries_count() == 1
		and jm.entries[0]["hour"] is float, "записей %d" % jm.entries.size())
	H.check("в places только строки", jm.places_count() == 1 and jm.is_place_open("hill"))

	# Журнал будущей версии не стирается.
	_write("{\"version\": 2, \"stats\": {\"distance_m\": 5000}}")
	var jf := Journal.load_or_new(PATH)
	H.check("журнал v2 отложен в .v2.json, начат новый", jf.distance_m == 0.0 and FileAccess.file_exists(V2_PATH)
		and FileAccess.get_file_as_string(V2_PATH).contains("5000"))

	Journal.reset(PATH)
	H.check("reset удаляет сохранение", not Journal.has_save(PATH))
	for extra in [BAD_PATH, V2_PATH, TMP_PATH]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(extra))
	ts.free()
	weather.free()
	car.queue_free()
	H.finish(self)
