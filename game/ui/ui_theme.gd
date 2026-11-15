class_name UiTheme
extends RefCounted
## Общая тема интерфейса и маленькие помощники для построения UI кодом.

const ACCENT := Color(1.0, 0.55, 0.1)
const DANGER := Color(1.0, 0.22, 0.2)
const OK := Color(0.3, 0.95, 0.5)
const PANEL := Color(0.05, 0.06, 0.08, 0.82)
## Доставки и места (радар, подсказки): цель — тёплый жёлтый (не оранжевый
## игрока и не красный погони), точка взятия — светлый песочный, место —
## приглушённый голубой. Все светлые: читаются на тёмном радаре и ночью.
const GOAL := Color(1.0, 0.84, 0.28)
const PICKUP := Color(0.96, 0.9, 0.72)
const PLACE := Color(0.6, 0.85, 0.95)

static var _theme: Theme


static func get_theme() -> Theme:
	if _theme != null:
		return _theme
	_theme = Theme.new()
	_theme.default_font_size = 22
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.set_corner_radius_all(10)
	panel.set_content_margin_all(18)
	_theme.set_stylebox("panel", "PanelContainer", panel)

	var btn := StyleBoxFlat.new()
	btn.bg_color = Color(0.14, 0.15, 0.18, 0.95)
	btn.set_corner_radius_all(6)
	btn.set_content_margin_all(10)
	var btn_hover := btn.duplicate() as StyleBoxFlat
	btn_hover.bg_color = Color(0.25, 0.22, 0.18)
	var btn_focus := btn.duplicate() as StyleBoxFlat
	btn_focus.bg_color = Color(0.3, 0.2, 0.1)
	btn_focus.border_color = ACCENT
	btn_focus.set_border_width_all(2)
	var btn_pressed := btn.duplicate() as StyleBoxFlat
	btn_pressed.bg_color = ACCENT.darkened(0.4)
	for t in ["Button", "OptionButton"]:
		_theme.set_stylebox("normal", t, btn)
		_theme.set_stylebox("hover", t, btn_hover)
		_theme.set_stylebox("focus", t, btn_focus)
		_theme.set_stylebox("pressed", t, btn_pressed)
		_theme.set_color("font_focus_color", t, ACCENT.lightened(0.4))
		_theme.set_color("font_hover_color", t, Color.WHITE)
	_theme.set_font_size("font_size", "Button", 24)
	var line := btn.duplicate() as StyleBoxFlat
	line.bg_color = Color(0.1, 0.11, 0.13)
	_theme.set_stylebox("normal", "LineEdit", line)
	_theme.set_stylebox("focus", "LineEdit", btn_focus)
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0, 0, 0, 0.55)
	bar_bg.border_color = Color(1, 1, 1, 0.35)
	bar_bg.set_border_width_all(1)
	bar_bg.set_corner_radius_all(4)
	_theme.set_stylebox("background", "ProgressBar", bar_bg)
	return _theme


## Плашка под короткой подсказкой поверх игры.
static func chip() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(PANEL, 0.7)
	sb.border_color = Color(ACCENT, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


## Привязка к якорю с отступами: rect задаёт смещения от точки якоря.
static func anchor(c: Control, preset: Control.LayoutPreset, rect: Rect2) -> void:
	c.set_anchors_preset(preset)
	c.offset_left = rect.position.x
	c.offset_top = rect.position.y
	c.offset_right = rect.end.x
	c.offset_bottom = rect.end.y


static func label(text: String, size: int = 22, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", maxi(size / 6, 3))
	return l


static func bar(color: Color, width: float = 380.0) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(width, 16)
	b.show_percentage = false
	b.max_value = 1.0
	b.step = 0.001
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(4)
	b.add_theme_stylebox_override("fill", fill)
	return b


static func button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320, 52)
	b.pressed.connect(cb)
	return b


static func key_name(physical_keycode: int) -> String:
	if physical_keycode == 0:
		return "—"
	# Физический код совпадает с кодом клавиши в раскладке US.
	return OS.get_keycode_string(physical_keycode as Key)
