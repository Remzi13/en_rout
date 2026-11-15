class_name TripStats
extends Node
## Счётчик поездки: каждый физический кадр берёт путь машины игрока, погоду
## и время суток и прибавляет к статистике журнала (Journal.add_drive).
## Сохраняет журнал раз в AUTOSAVE_S, при выходе из мира и при закрытии окна.
## Создаётся миром (OpenWorld); на паузе не считает (узел мира PAUSABLE).
## add_event — запись в журнал с текущими временем суток и погодой.

const AUTOSAVE_S := 45.0
## Сдвиг за кадр больше этого — телепорт (респаун), путь не считаем.
const TELEPORT_M := 50.0
## Дождь считается, когда он разошёлся хотя бы наполовину.
const RAIN_THRESHOLD := 0.5

var journal: Journal
var target: Node3D
var weather: Weather
var day_night: DayNight

var _last_pos := Vector3.ZERO
var _has_last: bool = false
var _since_save_s: float = 0.0


func setup(j: Journal, car: Node3D, w: Weather, dn: DayNight) -> void:
	journal = j
	target = car
	weather = w
	day_night = dn
	_has_last = false


func _physics_process(delta: float) -> void:
	tick(delta)


## Один шаг учёта (вызывается из _physics_process, тесты зовут напрямую).
func tick(delta: float) -> void:
	if journal == null or target == null:
		return
	var pos := target.global_position
	var moved := 0.0
	if _has_last:
		moved = pos.distance_to(_last_pos)
		if moved > TELEPORT_M:
			moved = 0.0
	_last_pos = pos
	_has_last = true
	journal.add_drive(delta, moved, is_raining(), GameState.is_night)
	_since_save_s += delta
	if _since_save_s >= AUTOSAVE_S:
		save()


func is_raining() -> bool:
	return weather != null and weather.rain_k >= RAIN_THRESHOLD


func weather_key() -> String:
	if weather == null:
		return Journal.WEATHER_CLEAR
	match weather.kind:
		Weather.Kind.RAIN:
			return Journal.WEATHER_RAIN
		Weather.Kind.FOG:
			return Journal.WEATHER_FOG
	return Journal.WEATHER_CLEAR


func hour() -> float:
	return day_night.hour if day_night != null else 12.0


## Запись в журнал с текущими временем суток и погодой (сохраняется сразу).
func add_event(kind: String, text: String) -> Dictionary:
	return journal.add_entry(kind, text, hour(), weather_key())


func save() -> void:
	_since_save_s = 0.0
	if journal != null:
		journal.save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save()


func _exit_tree() -> void:
	save()
