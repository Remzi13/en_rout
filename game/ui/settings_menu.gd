class_name SettingsMenu
extends PanelContainer
## Настройки: громкость шин звука, качество графики, дальность прорисовки,
## переназначение клавиш. Изменения сразу применяются и сохраняются.

signal closed

var _waiting_action: String = ""
var _key_buttons: Dictionary = {}
var _first: Control


func _ready() -> void:
	theme = UiTheme.get_theme()
	process_mode = Node.PROCESS_MODE_ALWAYS
	UiTheme.anchor(self, Control.PRESET_CENTER, Rect2(-380, -330, 760, 660))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)
	v.add_child(UiTheme.label("Настройки", 36, UiTheme.ACCENT))

	v.add_child(UiTheme.label("Графика", 24))
	_first = _option(v, "Качество", ["Низкое", "Среднее", "Высокое"], GameState.quality,
		func(i: int) -> void: GameState.quality = i)
	_option(v, "Дальность прорисовки", ["Близко", "Средне", "Далеко", "Очень далеко"], GameState.draw_distance - 1,
		func(i: int) -> void: GameState.draw_distance = i + 1)

	v.add_child(UiTheme.label("Управление (клавиатура)", 24))
	for pair in GameState.REBINDABLE_ACTIONS:
		var row := HBoxContainer.new()
		var l := UiTheme.label(pair[1], 20)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var b := Button.new()
		b.custom_minimum_size = Vector2(200, 40)
		var action: String = pair[0]
		b.pressed.connect(func() -> void: _start_rebind(action))
		row.add_child(b)
		_key_buttons[action] = b
		v.add_child(row)
	v.add_child(UiTheme.label("Геймпад: левый стик — руль, триггеры — газ/тормоз, A — ручник, X — погоня, Y — на дорогу", 16, Color(1, 1, 1, 0.6)))
	var reset := UiTheme.button("Сбросить клавиши", func() -> void:
		GameState.reset_bindings()
		_refresh_keys())
	v.add_child(reset)
	v.add_child(UiTheme.button("Назад", _close))
	_refresh_keys()


func focus_first() -> void:
	if _first != null:
		_first.grab_focus()


func _slider(parent: Control, text: String, value: float, setter: Callable) -> HSlider:
	var row := HBoxContainer.new()
	var l := UiTheme.label(text, 20)
	l.custom_minimum_size.x = 280
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(x: float) -> void:
		setter.call(x)
		GameState.apply_settings()
		GameState.save_settings())
	row.add_child(s)
	parent.add_child(row)
	return s


func _option(parent: Control, text: String, items: Array, selected: int, setter: Callable) -> OptionButton:
	var row := HBoxContainer.new()
	var l := UiTheme.label(text, 20)
	l.custom_minimum_size.x = 280
	row.add_child(l)
	var o := OptionButton.new()
	for it in items:
		o.add_item(it)
	o.selected = selected
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.item_selected.connect(func(i: int) -> void:
		setter.call(i)
		GameState.apply_settings()
		GameState.save_settings())
	row.add_child(o)
	parent.add_child(row)
	return o


func _refresh_keys() -> void:
	for action: String in _key_buttons:
		var b: Button = _key_buttons[action]
		b.text = "Нажмите клавишу…" if action == _waiting_action else UiTheme.key_name(GameState.key_for(action))


func _start_rebind(action: String) -> void:
	_waiting_action = action
	_refresh_keys()


func _input(event: InputEvent) -> void:
	if _waiting_action == "" or not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.physical_keycode != KEY_ESCAPE:
			GameState.rebind(_waiting_action, k.physical_keycode)
		_waiting_action = ""
		_refresh_keys()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if visible and _waiting_action == "" and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


func _close() -> void:
	_waiting_action = ""
	closed.emit()
