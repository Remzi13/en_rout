extends Node
## Точка входа (game/main.tscn): главное меню, рекорды, настройки,
## запуск сессии в открытом мире и меню паузы.

var world: OpenWorld
var _ui: CanvasLayer
var _screen: Control
var _seed_edit: LineEdit
var _paused_ui: Control
var _loading: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ui = CanvasLayer.new()
	_ui.layer = 10
	add_child(_ui)
	var args := OS.get_cmdline_user_args()
	if "--autostart" in args:
		_start_game(_parse_seed_arg(args))
	else:
		_show_main_menu()


func _parse_seed_arg(args: PackedStringArray) -> int:
	for a in args:
		if a.begins_with("--seed="):
			return int(a.trim_prefix("--seed="))
	return 1


func _clear_screen() -> void:
	if _screen != null:
		_screen.queue_free()
		_screen = null


func _backdrop() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UiTheme.get_theme()
	if world == null:
		var bg := ColorRect.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.color = Color(0.06, 0.07, 0.09)
		root.add_child(bg)
		var glow := ColorRect.new()
		glow.set_anchors_preset(Control.PRESET_FULL_RECT)
		var g := Gradient.new()
		g.set_color(0, Color(1.0, 0.45, 0.1, 0.25))
		g.set_color(1, Color(0, 0, 0, 0))
		glow.color = Color(0, 0, 0, 0)
		var tex := GradientTexture2D.new()
		tex.gradient = g
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 1.1)
		tex.fill_to = Vector2(0.5, 0.2)
		var tr := TextureRect.new()
		tr.texture = tex
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		root.add_child(tr)
	else:
		var dim := ColorRect.new()
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.color = Color(0, 0, 0, 0.55)
		root.add_child(dim)
	return root


func _menu_column(root: Control, title: String, subtitle: String = "") -> VBoxContainer:
	var v := VBoxContainer.new()
	UiTheme.anchor(v, Control.PRESET_CENTER, Rect2(-260, -300, 520, 600))
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 14)
	root.add_child(v)
	var t := UiTheme.label(title, 64, UiTheme.ACCENT)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	if subtitle != "":
		var s := UiTheme.label(subtitle, 20, Color(1, 1, 1, 0.65))
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(s)
	return v


# --- Главное меню ---------------------------------------------------------

func _show_main_menu() -> void:
	_clear_screen()
	_screen = _backdrop()
	_ui.add_child(_screen)
	var v := _menu_column(_screen, "ОТРЫВ", "Аркадные погони в бесконечном мире")
	v.add_child(UiTheme.label("Сид мира (пусто — случайный):", 18, Color(1, 1, 1, 0.7)))
	_seed_edit = LineEdit.new()
	_seed_edit.placeholder_text = "например, 12345"
	_seed_edit.custom_minimum_size = Vector2(320, 46)
	_seed_edit.text_submitted.connect(func(_t: String) -> void: _on_play())
	v.add_child(_seed_edit)
	var play := UiTheme.button("Играть", _on_play)
	v.add_child(play)
	v.add_child(UiTheme.button("Рекорды", _show_records))
	v.add_child(UiTheme.button("Настройки", func() -> void: _show_settings(_show_main_menu)))
	v.add_child(UiTheme.button("Выход", func() -> void: get_tree().quit()))
	play.grab_focus()


func _on_play() -> void:
	var text := _seed_edit.text.strip_edges() if _seed_edit != null else ""
	var s := 0
	if text == "":
		s = randi() % 1000000
	elif text.is_valid_int():
		s = int(text)
	else:
		s = text.hash() % 1000000
	_start_game(s)


# --- Рекорды --------------------------------------------------------------

func _show_records() -> void:
	_clear_screen()
	_screen = _backdrop()
	_ui.add_child(_screen)
	var panel := PanelContainer.new()
	UiTheme.anchor(panel, Control.PRESET_CENTER, Rect2(-420, -320, 840, 640))
	_screen.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(UiTheme.label("Рекорды", 40, UiTheme.ACCENT))
	var st := GameState.stats
	v.add_child(UiTheme.label("Погонь: %d · ушёл: %d · пойман: %d · проехано: %.1f км" % [
		int(st["chases"]), int(st["escapes"]), int(st["caught"]), float(st["distance_m"]) / 1000.0], 20, Color(1, 1, 1, 0.75)))
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 28)
	v.add_child(grid)
	for h in ["#", "Очки", "Исход", "Время", "Гонщиков", "Сид"]:
		grid.add_child(UiTheme.label(h, 18, Color(1, 1, 1, 0.55)))
	if GameState.records.is_empty():
		v.add_child(UiTheme.label("Пока пусто — переживите первую погоню!", 22))
	for i in GameState.records.size():
		var r: Dictionary = GameState.records[i]
		var ok: bool = r.get("result", "") == "escaped"
		grid.add_child(UiTheme.label(str(i + 1), 22))
		grid.add_child(UiTheme.label(str(int(r.get("score", 0))), 22, UiTheme.ACCENT))
		grid.add_child(UiTheme.label("ушёл" if ok else "пойман", 22, UiTheme.OK if ok else UiTheme.DANGER))
		grid.add_child(UiTheme.label("%.1f с" % float(r.get("duration", 0.0)), 22))
		grid.add_child(UiTheme.label(str(int(r.get("pursuers", 0))), 22))
		grid.add_child(UiTheme.label(str(int(r.get("seed", 0))), 22))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(spacer)
	var back := UiTheme.button("Назад", _show_main_menu)
	v.add_child(back)
	back.grab_focus()


# --- Настройки ------------------------------------------------------------

func _show_settings(on_close: Callable) -> void:
	var holder := _backdrop()
	var menu := SettingsMenu.new()
	holder.add_child(menu)
	_ui.add_child(holder)
	menu.closed.connect(func() -> void:
		holder.queue_free()
		on_close.call())
	if _screen != null and world == null:
		_clear_screen()
	_screen = holder if world == null else _screen
	menu.focus_first()


# --- Игра -----------------------------------------------------------------

func _start_game(seed_value: int) -> void:
	_clear_screen()
	_loading = UiTheme.label("Загрузка мира…  сид %d" % seed_value, 36)
	UiTheme.anchor(_loading, Control.PRESET_CENTER, Rect2(-400, -30, 800, 60))
	_loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bg := _backdrop()
	bg.add_child(_loading)
	_ui.add_child(bg)
	_screen = bg
	# Дать кадру отрисовать экран загрузки до загрузки мира.
	await get_tree().process_frame
	await get_tree().process_frame
	world = OpenWorld.create(seed_value)
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	world.pause_requested.connect(_pause)
	add_child(world)
	_clear_screen()
	get_tree().paused = false
	# Отладка: --autopilot — машина игрока едет по дорогам сама, --chase — сразу погоня.
	var args := OS.get_cmdline_user_args()
	if "--autopilot" in args:
		var auto := TrafficDriver.new()
		var near := world.roads.nearest_road(world.player.global_position)
		auto.setup(world.roads, near["edge"], true, near["s"], 1)
		auto.cruise_kmh = 120.0
		world.player.driver = auto
	if "--chase" in args:
		world.chase.trigger_now()
	for a in args:
		if a.begins_with("--hour="):
			world.day_night.hour = float(a.trim_prefix("--hour="))
		elif a.begins_with("--weather="):
			world.weather.set_kind(int(a.trim_prefix("--weather=")) as Weather.Kind)
			world.weather.rain_k = 1.0 if world.weather.kind == Weather.Kind.RAIN else 0.0
			world.weather.fog_k = 1.0 if world.weather.kind == Weather.Kind.FOG else 0.0


func _pause() -> void:
	if world == null or _paused_ui != null:
		return
	get_tree().paused = true
	_paused_ui = _backdrop()
	_ui.add_child(_paused_ui)
	var v := _menu_column(_paused_ui, "Пауза", "Сид мира: %d" % world.world_seed)
	var cont := UiTheme.button("Продолжить", _resume)
	v.add_child(cont)
	v.add_child(UiTheme.button("Настройки", func() -> void:
		_paused_ui.visible = false
		_show_settings(func() -> void:
			if _paused_ui != null:
				_paused_ui.visible = true
				(_paused_ui.find_children("*", "Button", true, false)[0] as Button).grab_focus())))
	v.add_child(UiTheme.button("В главное меню", _to_menu))
	cont.grab_focus()


func _resume() -> void:
	if _paused_ui != null:
		_paused_ui.queue_free()
		_paused_ui = null
	get_tree().paused = false


func _to_menu() -> void:
	_resume()
	if world != null:
		world.queue_free()
		world = null
	await get_tree().process_frame
	_show_main_menu()


func _unhandled_input(event: InputEvent) -> void:
	if _paused_ui != null and _paused_ui.visible and (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		get_viewport().set_input_as_handled()
		_resume()
