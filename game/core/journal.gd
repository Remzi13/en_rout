class_name Journal
extends RefCounted
## Бортовой журнал: записи о событиях (доставки, места), открытые места и
## статистика поездок. Без зависимостей от сцены: время суток и погоду
## передаёт тот, кто добавляет запись (обычно TripStats).
##
## Хранится в JSON (user://journal.json) с полем version. Пустой, битый или
## старый файл не роняет игру: журнал начинается заново, в лог — предупреждение.
## add_entry и open_place сразу сохраняют файл; статистику сохраняет TripStats
## раз в AUTOSAVE_S и при выходе.

signal entry_added(entry: Dictionary)

const PATH := "user://journal.json"
const VERSION := 1

const KIND_DELIVERY := "delivery"
const KIND_PLACE := "place"
const KIND_OTHER := "other"

const WEATHER_CLEAR := "clear"
const WEATHER_RAIN := "rain"
const WEATHER_FOG := "fog"

## Куда сохраняется этот журнал (тесты подставляют свой путь).
var path: String = PATH
## Записи по порядку: {kind, text, hour, weather, unix_time, date}.
var entries: Array[Dictionary] = []
## Открытые места: id -> true.
var places: Dictionary = {}
## Накопленная статистика поездок.
var distance_m: float = 0.0
var drive_time_s: float = 0.0
var rain_distance_m: float = 0.0
var night_distance_m: float = 0.0


## Есть ли сохранённый журнал (для «Продолжить» в меню).
static func has_save(file_path: String = PATH) -> bool:
	return FileAccess.file_exists(file_path)


## Удаляет сохранение («Новая игра»).
static func reset(file_path: String = PATH) -> void:
	if FileAccess.file_exists(file_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file_path))


## Читает журнал с диска; нет файла или он негодный — новый пустой журнал.
static func load_or_new(file_path: String = PATH) -> Journal:
	var j := Journal.new()
	j.path = file_path
	if not FileAccess.file_exists(file_path):
		return j
	var text := FileAccess.get_file_as_string(file_path)
	# JSON.new().parse не печатает ERROR на битом файле, в отличие от parse_string.
	var json := JSON.new()
	var parsed: Variant = json.data if json.parse(text) == OK else null
	if not parsed is Dictionary or int((parsed as Dictionary).get("version", 0)) != VERSION:
		push_warning("Журнал %s повреждён или устарел — начинаем заново" % file_path)
		return j
	j._from_dict(parsed)
	return j


func save() -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Не удалось сохранить журнал %s" % path)
		return false
	f.store_string(JSON.stringify(to_dict(), "  "))
	return true


## Добавляет запись и сохраняет журнал. hour — игровое время суток 0..24,
## weather — WEATHER_* (clear/rain/fog).
func add_entry(kind: String, text: String, hour: float, weather: String) -> Dictionary:
	var entry := {
		"kind": kind,
		"text": text,
		"hour": snappedf(hour, 0.01),
		"weather": weather,
		"unix_time": int(Time.get_unix_time_from_system()),
		"date": Time.get_datetime_string_from_system(false, true),
	}
	entries.append(entry)
	save()
	entry_added.emit(entry)
	return entry


## Отмечает место открытым и сохраняет журнал; false — уже было открыто.
## Запись о месте добавляется отдельно через add_entry(KIND_PLACE, ...).
func open_place(id: String) -> bool:
	if places.has(id):
		return false
	places[id] = true
	save()
	return true


func is_place_open(id: String) -> bool:
	return places.has(id)


func deliveries_count() -> int:
	var n := 0
	for e in entries:
		if e.get("kind", "") == KIND_DELIVERY:
			n += 1
	return n


func places_count() -> int:
	return places.size()


## Учёт езды за кадр: dt — время за рулём, meters — пройденный путь.
func add_drive(dt: float, meters: float, raining: bool, night: bool) -> void:
	drive_time_s += dt
	distance_m += meters
	if raining:
		rain_distance_m += meters
	if night:
		night_distance_m += meters


## Сводка для экрана журнала (км и секунды).
func stats() -> Dictionary:
	return {
		"distance_km": distance_m / 1000.0,
		"drive_time_s": drive_time_s,
		"rain_km": rain_distance_m / 1000.0,
		"night_km": night_distance_m / 1000.0,
		"deliveries": deliveries_count(),
		"places": places_count(),
	}


## «Вечер, дождь» — подпись момента записи для экрана журнала.
static func moment_text(hour: float, weather: String) -> String:
	var part := "Ночь"
	if hour >= 5.0 and hour < 11.0:
		part = "Утро"
	elif hour >= 11.0 and hour < 17.0:
		part = "День"
	elif hour >= 17.0 and hour < 22.0:
		part = "Вечер"
	var w: String = {WEATHER_CLEAR: "ясно", WEATHER_RAIN: "дождь", WEATHER_FOG: "туман"}.get(weather, weather)
	return part + (", " + w if w != "" else "")


func to_dict() -> Dictionary:
	return {
		"version": VERSION,
		"entries": entries,
		"places": places.keys(),
		"stats": {
			"distance_m": distance_m,
			"drive_time_s": drive_time_s,
			"rain_distance_m": rain_distance_m,
			"night_distance_m": night_distance_m,
		},
	}


func _from_dict(d: Dictionary) -> void:
	var list: Variant = d.get("entries")
	if list is Array:
		for e: Variant in list:
			if e is Dictionary:
				entries.append(e)
	var ids: Variant = d.get("places")
	if ids is Array:
		for id: Variant in ids:
			places[str(id)] = true
	var s: Variant = d.get("stats")
	if s is Dictionary:
		distance_m = _num(s.get("distance_m"))
		drive_time_s = _num(s.get("drive_time_s"))
		rain_distance_m = _num(s.get("rain_distance_m"))
		night_distance_m = _num(s.get("night_distance_m"))


static func _num(v: Variant) -> float:
	return float(v) if v is float or v is int else 0.0
