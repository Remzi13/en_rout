class_name GameHud
extends CanvasLayer
## HUD: спидометр, мини-карта, шкалы отрыва и захвата во время погони,
## счёт, время суток и погода, всплывающие сообщения и итог погони.
## Места и доставки — TaskHud (подсказка, надписи, строка цели) и метки радара.

var world: OpenWorld

var _speed: Label
var _speed_unit: Label
var _surface: Label
var _clock: Label
var _chase_title: Label
var _chase_box: VBoxContainer
var _escape_bar: ProgressBar
var _capture_bar: ProgressBar
var _escape_label: Label
var _capture_label: Label
var _score: Label
var _popup: Label
var _popup_t: float = 0.0
var _result: PanelContainer
var _result_title: Label
var _result_text: Label
var _hint: Label
var _hint_t: float = 12.0
var _respawn_hint: Label
var _next_chase: Label
var tasks: TaskHud
var radar: Radar


func setup(w: OpenWorld) -> void:
	world = w
	layer = 5
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiTheme.get_theme()
	add_child(root)

	# Спидометр — справа внизу.
	var sp := VBoxContainer.new()
	UiTheme.anchor(sp, Control.PRESET_BOTTOM_RIGHT, Rect2(Vector2(-320, -230), Vector2(280, 200)))
	sp.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(sp)
	_speed = UiTheme.label("0", 84)
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sp.add_child(_speed)
	_speed_unit = UiTheme.label("км/ч", 22, Color(1, 1, 1, 0.7))
	_speed_unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sp.add_child(_speed_unit)
	_surface = UiTheme.label("", 18, Color(1, 1, 1, 0.6))
	_surface.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sp.add_child(_surface)

	# Мини-карта — слева внизу.
	radar = Radar.new()
	radar.world = w
	radar.places = w.places
	radar.deliveries = w.deliveries
	UiTheme.anchor(radar, Control.PRESET_BOTTOM_LEFT, Rect2(Vector2(30, -270), Vector2(240, 240)))
	radar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(radar)

	# Время и погода — справа вверху.
	_clock = UiTheme.label("", 22)
	UiTheme.anchor(_clock, Control.PRESET_TOP_RIGHT, Rect2(Vector2(-330, 24), Vector2(300, 30)))
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(_clock)
	_next_chase = UiTheme.label("", 18, Color(1, 1, 1, 0.55))
	UiTheme.anchor(_next_chase, Control.PRESET_TOP_RIGHT, Rect2(Vector2(-430, 56), Vector2(400, 30)))
	_next_chase.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(_next_chase)

	# Погоня — сверху по центру.
	_chase_box = VBoxContainer.new()
	UiTheme.anchor(_chase_box, Control.PRESET_CENTER_TOP, Rect2(Vector2(-220, 20), Vector2(440, 160)))
	_chase_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_chase_box.add_theme_constant_override("separation", 4)
	root.add_child(_chase_box)
	_chase_title = UiTheme.label("", 34, UiTheme.DANGER)
	_chase_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chase_box.add_child(_chase_title)
	_score = UiTheme.label("", 26, UiTheme.ACCENT)
	_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chase_box.add_child(_score)
	_escape_label = UiTheme.label("Отрыв", 18, UiTheme.OK)
	_chase_box.add_child(_escape_label)
	_escape_bar = UiTheme.bar(UiTheme.OK, 440)
	_chase_box.add_child(_escape_bar)
	_capture_label = UiTheme.label("Захват", 18, UiTheme.DANGER)
	_chase_box.add_child(_capture_label)
	_capture_bar = UiTheme.bar(UiTheme.DANGER, 440)
	_chase_box.add_child(_capture_bar)

	_popup = UiTheme.label("", 30, UiTheme.ACCENT)
	UiTheme.anchor(_popup, Control.PRESET_CENTER, Rect2(Vector2(-300, -160), Vector2(600, 40)))
	_popup.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_popup)

	_respawn_hint = UiTheme.label("", 22, Color(1, 1, 1, 0.85))
	UiTheme.anchor(_respawn_hint, Control.PRESET_CENTER_BOTTOM, Rect2(Vector2(-300, -120), Vector2(600, 30)))
	_respawn_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_respawn_hint)

	_hint = UiTheme.label("", 18, Color(1, 1, 1, 0.75))
	UiTheme.anchor(_hint, Control.PRESET_CENTER_BOTTOM, Rect2(Vector2(-500, -70), Vector2(1000, 30)))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.text = "%s/%s — газ/тормоз · %s/%s — руль · %s — ручник · %s — на дорогу · %s — вызвать погоню · %s — пауза" % [
		_k("accelerate"), _k("brake"), _k("steer_left"), _k("steer_right"), _k("handbrake"),
		_k("respawn"), _k("call_chase"), _k("pause")]
	root.add_child(_hint)

	tasks = TaskHud.new()
	tasks.name = "Tasks"
	root.add_child(tasks)
	tasks.setup(w.places, w.deliveries)

	_result = PanelContainer.new()
	UiTheme.anchor(_result, Control.PRESET_CENTER, Rect2(Vector2(-260, -110), Vector2(520, 220)))
	_result.visible = false
	root.add_child(_result)
	var rv := VBoxContainer.new()
	rv.alignment = BoxContainer.ALIGNMENT_CENTER
	_result.add_child(rv)
	_result_title = UiTheme.label("", 40)
	_result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rv.add_child(_result_title)
	_result_text = UiTheme.label("", 22)
	_result_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rv.add_child(_result_text)

	w.chase.state_changed.connect(_on_chase_state)
	w.chase.chase_finished.connect(_on_chase_finished)
	w.chase.near_miss_scored.connect(func() -> void: show_popup("+%d  Опасный пролёт!" % int(w.chase.config.points_near_miss)))
	_on_chase_state(w.chase.state)


func _k(action: String) -> String:
	return UiTheme.key_name(GameState.key_for(action))


func show_popup(text: String) -> void:
	_popup.text = text
	_popup_t = 1.6


func _process(delta: float) -> void:
	if world == null or world.player == null:
		return
	var p := world.player
	_speed.text = "%d" % roundi(p.get_speed_kmh())
	_surface.text = "асфальт" if p.surface_speed > 0.99 else ("грунт" if p.surface_speed > 0.8 else "бездорожье")
	_clock.text = "%s  ·  %s" % [world.day_night.time_text(), Weather.NAMES[world.weather.kind]]
	var ch := world.chase
	if ch.state == ChaseDirector.State.FREE:
		_next_chase.text = "Свободная езда"
	else:
		_next_chase.text = ""
	if ch.state == ChaseDirector.State.ACTIVE:
		_escape_bar.value = ch.rules.escape_progress()
		_capture_bar.value = ch.rules.capture_progress()
		var d := ch.min_pursuer_distance()
		_escape_label.text = "Отрыв: %d / %d м" % [mini(int(d), 9999), int(ch.config.escape_distance_m)]
		_score.text = "%d очков" % ch.score.running_total()
		_capture_label.modulate.a = 1.0 if _capture_bar.value > 0.0 else 0.5
		_chase_title.modulate.a = 0.75 + 0.25 * sin(Time.get_ticks_msec() / 150.0)
	elif ch.state == ChaseDirector.State.WARNING:
		_chase_title.modulate.a = 0.5 + 0.5 * sin(Time.get_ticks_msec() / 80.0)
	if _popup_t > 0.0:
		_popup_t -= delta
		_popup.modulate.a = clampf(_popup_t, 0.0, 1.0)
	else:
		_popup.text = ""
	if _hint_t > 0.0:
		_hint_t -= delta
		_hint.modulate.a = clampf(_hint_t / 2.0, 0.0, 1.0)
	_respawn_hint.text = ("%s — вернуть машину на дорогу" % _k("respawn")) if (p.is_flipped() or (p.get_speed_kmh() < 2.0 and p.controls.throttle > 0.5)) else ""


func _on_chase_state(s: int) -> void:
	var active := s == ChaseDirector.State.ACTIVE
	_chase_box.visible = s == ChaseDirector.State.WARNING or active
	_escape_bar.visible = active
	_capture_bar.visible = active
	_escape_label.visible = active
	_capture_label.visible = active
	_score.visible = active
	match s:
		ChaseDirector.State.WARNING:
			_chase_title.text = "Уличные гонщики вышли на охоту! (%d)" % world.chase.event_size
		ChaseDirector.State.ACTIVE:
			_chase_title.text = "ПОГОНЯ — оторвись!"
		_:
			_chase_title.text = ""
	if s != ChaseDirector.State.RESULT:
		_result.visible = false


func _on_chase_finished(outcome: int, score: int, place: int) -> void:
	_result.visible = true
	var ch := world.chase
	if outcome == ChaseRules.Outcome.ESCAPED:
		_result_title.text = "Ушёл от погони!"
		_result_title.add_theme_color_override("font_color", UiTheme.OK)
	else:
		_result_title.text = "Тебя зажали"
		_result_title.add_theme_color_override("font_color", UiTheme.DANGER)
	var lines := "Очки: %d\nВремя: %.1f с · макс. %d км/ч\nОпасных пролётов: %d" % [
		score, ch.score.duration_s, int(ch.score.top_speed_kmh), ch.score.near_misses]
	if place > 0:
		lines += "\nМесто в рекордах: %d" % place
	_result_text.text = lines
