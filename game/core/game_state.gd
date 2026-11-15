extends Node
## Автозагрузка GameState: настройки, рекорды и статистика (user://),
## шины звука, глобальные условия мира (сцепление от погоды, ночь).

signal settings_changed

var settings_path := "user://settings.cfg"
var save_path := "user://save.json"
const MAX_RECORDS := 10
const REBINDABLE_ACTIONS := [
	["accelerate", "Газ"], ["brake", "Тормоз / задний ход"], ["steer_left", "Влево"],
	["steer_right", "Вправо"], ["handbrake", "Ручник"], ["respawn", "Вернуть на дорогу"],
	["call_chase", "Вызвать погоню"], ["interact", "Действие: взять / сдать"], ["pause", "Пауза"],
]

# --- Настройки ---
var master_volume: float = 0.8
var music_volume: float = 0.6
var sfx_volume: float = 0.8
var quality: int = 1 ## 0 — низкое, 1 — среднее, 2 — высокое
var draw_distance: int = 2 ## дальность прорисовки 1..4 (камера видит на 300 + 300·N м)
var key_overrides: Dictionary = {} ## действие -> physical_keycode

# --- Сохранение ---
var records: Array = [] ## [{score, duration, result, pursuers, seed, date}]
var stats: Dictionary = {"escapes": 0, "caught": 0, "distance_m": 0.0, "chases": 0}

# --- Состояние мира (заполняет текущая сессия) ---
var weather_grip: float = 1.0
var is_night: bool = false
var world_seed: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()
	load_settings()
	load_save()
	apply_settings()


func _ensure_buses() -> void:
	for bus_name in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")


func apply_settings() -> void:
	_set_bus("Master", master_volume)
	_set_bus("Music", music_volume)
	_set_bus("SFX", sfx_volume)
	for action: String in key_overrides:
		_apply_key(action, int(key_overrides[action]))
	settings_changed.emit()


func _set_bus(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))
		AudioServer.set_bus_mute(idx, linear <= 0.001)


## Клавиатурная клавиша действия (первая) — для меню переназначения.
func key_for(action: String) -> int:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return (ev as InputEventKey).physical_keycode
	return 0


func rebind(action: String, physical_keycode: int) -> void:
	key_overrides[action] = physical_keycode
	_apply_key(action, physical_keycode)
	save_settings()


func reset_bindings() -> void:
	key_overrides.clear()
	InputMap.load_from_project_settings()
	save_settings()


func _apply_key(action: String, physical_keycode: int) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			InputMap.action_erase_event(action, ev)
			break
	var key := InputEventKey.new()
	key.physical_keycode = physical_keycode as Key
	InputMap.action_add_event(action, key)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(settings_path) != OK:
		return
	master_volume = cfg.get_value("audio", "master", master_volume)
	music_volume = cfg.get_value("audio", "music", music_volume)
	sfx_volume = cfg.get_value("audio", "sfx", sfx_volume)
	quality = cfg.get_value("video", "quality", quality)
	draw_distance = clampi(cfg.get_value("video", "draw_distance", draw_distance), 1, 4)
	key_overrides = cfg.get_value("input", "keys", {})


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("video", "quality", quality)
	cfg.set_value("video", "draw_distance", draw_distance)
	cfg.set_value("input", "keys", key_overrides)
	cfg.save(settings_path)


func load_save() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		var d: Dictionary = parsed
		if d.get("records") is Array:
			records = d["records"]
		if d.get("stats") is Dictionary:
			stats.merge(d["stats"], true)


func save_game() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_warning("Не удалось сохранить %s" % save_path)
		return
	f.store_string(JSON.stringify({"records": records, "stats": stats}, "  "))


## Добавляет результат погони; возвращает место в таблице (1..) или 0.
func add_record(entry: Dictionary) -> int:
	stats["chases"] = int(stats["chases"]) + 1
	if entry.get("result", "") == "escaped":
		stats["escapes"] = int(stats["escapes"]) + 1
	else:
		stats["caught"] = int(stats["caught"]) + 1
	records.append(entry)
	records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["score"]) > int(b["score"]))
	var place := records.find(entry) + 1
	if records.size() > MAX_RECORDS:
		records.resize(MAX_RECORDS)
	save_game()
	return place if place <= MAX_RECORDS else 0


func add_distance(meters: float) -> void:
	stats["distance_m"] = float(stats["distance_m"]) + meters
