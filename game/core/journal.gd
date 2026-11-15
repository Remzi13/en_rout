class_name Journal
extends RefCounted
## Бортовой журнал: записи о событиях (доставки, места), открытые места и
## статистика поездок. Без зависимостей от сцены: время суток и погоду
## передаёт тот, кто добавляет запись (обычно TripStats).
##
## Хранится в JSON (user://journal.json) с полем version. Сохранение атомарное:
## пишем в <path>.tmp и переименовываем поверх основного файла.
## Пустой, битый, старый файл или поля неверного типа не роняют игру: файл
## откладывается рядом как journal.bad.json (перезаписывая прошлый), журнал
## начинается заново, в лог — предупреждение. Журнал из будущей версии не
## стирается: откладывается как journal.v<N>.json. Отдельные негодные записи
## и места (не строки) при чтении просто отбрасываются.
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
	var v: Variant = (parsed as Dictionary).get("version") if parsed is Dictionary else null
	if _is_num(v) and float(v) == floorf(float(v)) and int(v) > VERSION:
		var future := _side_path(file_path, ".v%d.json" % int(v))
		push_warning("Журнал %s из новой версии (%d) — отложен в %s, начинаем заново" % [file_path, int(v), future])
		_move_aside(file_path, future)
		return j
	if not (_is_num(v) and float(v) == VERSION) or not j._from_dict(parsed):
		var bad := _side_path(file_path, ".bad.json")
		push_warning("Журнал %s повреждён или устарел — отложен в %s, начинаем заново" % [file_path, bad])
		_move_aside(file_path, bad)
		j = Journal.new()
		j.path = file_path
	return j


## Сохраняет атомарно: <path>.tmp, затем переименование поверх основного.
func save() -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("Не удалось сохранить журнал %s" % path)
		return false
	f.store_string(JSON.stringify(to_dict(), "  "))
	var write_ok := f.get_error() == OK
	f.close()
	if not write_ok:
		push_warning("Не удалось записать журнал %s" % tmp)
		return false
	if DirAccess.rename_absolute(_abs(tmp), _abs(path)) != OK:
		push_warning("Не удалось заменить журнал %s" % path)
		return false
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


## Заполняет журнал из словаря файла; false — поля неверного типа (файл негодный).
## Записи без строковых kind/text и места не строками отбрасываются.
func _from_dict(d: Dictionary) -> bool:
	var list: Variant = d.get("entries", [])
	var ids: Variant = d.get("places", [])
	var s: Variant = d.get("stats", {})
	if not list is Array or not ids is Array or not s is Dictionary:
		return false
	for key: String in ["distance_m", "drive_time_s", "rain_distance_m", "night_distance_m"]:
		if not _is_num((s as Dictionary).get(key, 0.0)):
			return false
	for e: Variant in list:
		if not e is Dictionary:
			continue
		var ed := e as Dictionary
		if typeof(ed.get("kind")) != TYPE_STRING or typeof(ed.get("text")) != TYPE_STRING:
			continue
		var w: Variant = ed.get("weather", "")
		var ut: Variant = ed.get("unix_time", 0)
		var date: Variant = ed.get("date", "")
		entries.append({
			"kind": ed["kind"],
			"text": ed["text"],
			"hour": _num(ed.get("hour")),
			"weather": w if typeof(w) == TYPE_STRING else "",
			"unix_time": int(ut) if _is_num(ut) else 0,
			"date": date if typeof(date) == TYPE_STRING else "",
		})
	for id: Variant in ids:
		if typeof(id) == TYPE_STRING:
			places[id] = true
	distance_m = _num(s.get("distance_m"))
	drive_time_s = _num(s.get("drive_time_s"))
	rain_distance_m = _num(s.get("rain_distance_m"))
	night_distance_m = _num(s.get("night_distance_m"))
	return true


static func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT


static func _num(v: Variant) -> float:
	return float(v) if _is_num(v) else 0.0


static func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)


## user://journal.json + ".bad.json" → user://journal.bad.json.
static func _side_path(file_path: String, suffix: String) -> String:
	return file_path.get_basename() + suffix


## Откладывает файл в сторону, перезаписывая прежний с тем же именем.
static func _move_aside(from: String, to: String) -> void:
	if FileAccess.file_exists(to):
		DirAccess.remove_absolute(_abs(to))
	if DirAccess.rename_absolute(_abs(from), _abs(to)) != OK:
		push_warning("Не удалось отложить журнал %s в %s" % [from, to])
