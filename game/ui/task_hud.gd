class_name TaskHud
extends Control
## Интерфейс мест и доставок поверх игры: подсказка действия внизу по
## центру («[E] Взять: сети», клавиша — из текущей раскладки interact),
## надписи в две строки («Открыто» / место, «Везём» и «Доставлено» / груз,
## «Все грузы доставлены») сверху на ANNOUNCE_S
## (идут по очереди, не накладываются) и строка цели у радара
## («Везу: <груз> → <точка сдачи>»).
## Данные — сигналы PlaceTracker и Deliveries (setup). Время идёт в
## tick(delta): тесты зовут его напрямую.

const ANNOUNCE_S := 3.0
const FADE_IN_S := 0.25
const FADE_OUT_S := 0.4

var deliveries: Deliveries

var prompt_panel: PanelContainer
var prompt_label: Label
var announce_box: VBoxContainer
var announce_caption: Label
var announce_title: Label
var goal_label: Label
## Надписи в очереди: [caption, title].
var queue: Array[PackedStringArray] = []

var _raw_prompt: String = ""
var _key: String = ""
var _announce_t: float = 0.0


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Подсказка — внизу по центру, выше подсказки «вернуть на дорогу»;
	# шириной не заходит под спидометр даже при 1280.
	prompt_panel = PanelContainer.new()
	UiTheme.anchor(prompt_panel, Control.PRESET_CENTER_BOTTOM, Rect2(Vector2(-280, -186), Vector2(560, 52)))
	prompt_panel.add_theme_stylebox_override("panel", UiTheme.chip())
	prompt_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt_panel.visible = false
	add_child(prompt_panel)
	prompt_label = UiTheme.label("", 26)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	prompt_panel.add_child(prompt_label)

	# Надпись — сверху, ниже блока погони.
	announce_box = VBoxContainer.new()
	UiTheme.anchor(announce_box, Control.PRESET_CENTER_TOP, Rect2(Vector2(-400, 236), Vector2(800, 90)))
	announce_box.add_theme_constant_override("separation", 0)
	announce_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	announce_box.visible = false
	add_child(announce_box)
	announce_caption = UiTheme.label("", 20, UiTheme.ACCENT)
	announce_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	announce_box.add_child(announce_caption)
	announce_title = UiTheme.label("", 40)
	announce_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	announce_box.add_child(announce_title)

	# Цель — над радаром (радар: слева внизу, 30..270 по x, -270..-30 по y).
	goal_label = UiTheme.label("", 18, UiTheme.GOAL)
	UiTheme.anchor(goal_label, Control.PRESET_BOTTOM_LEFT, Rect2(Vector2(30, -304), Vector2(520, 28)))
	add_child(goal_label)


func setup(places: PlaceTracker, d: Deliveries) -> void:
	deliveries = d
	if places != null:
		places.place_discovered.connect(func(_id: String, title: String) -> void: announce("Открыто", title))
	if d != null:
		d.prompt_changed.connect(show_prompt)
		d.delivery_completed.connect(func(def: DeliveryDef) -> void:
			announce("Доставлено", def.cargo)
			# Последняя доставка: больше нечего брать и некуда везти.
			if not d.has_target() and d.available_spots().is_empty():
				announce("Все грузы доставлены", "Дальше — просто дорога"))
		d.delivery_taken.connect(func(def: DeliveryDef) -> void:
			announce("Везём", def.cargo)
			refresh_goal())
		d.target_changed.connect(func(_has: bool, _pos: Vector3) -> void: refresh_goal())
		show_prompt(d.prompt)
	refresh_goal()


## Текст подсказки от Deliveries («Взять: сети»); пусто — скрыть.
func show_prompt(text: String) -> void:
	_raw_prompt = text
	if text == "":
		prompt_panel.visible = false
		return
	_key = UiTheme.key_name(GameState.key_for("interact"))
	prompt_label.text = "[%s]  %s" % [_key, text]
	if not prompt_panel.visible:
		prompt_panel.visible = true
		prompt_panel.modulate.a = 0.0


## Ставит надпись в очередь; первая показывается сразу.
func announce(caption: String, title: String) -> void:
	queue.append(PackedStringArray([caption, title]))
	if not announce_box.visible:
		_next_announce()


func refresh_goal() -> void:
	var text := ""
	if deliveries != null and deliveries.active != null:
		var to: Dictionary = deliveries.spots.get(deliveries.active.to_spot, {})
		text = "Везу: %s → %s" % [deliveries.active.cargo, to.get("title", deliveries.active.to_spot)]
	goal_label.text = text


func tick(delta: float) -> void:
	# Клавишу могли переназначить в паузе (GameState.rebind без сигнала).
	if prompt_panel.visible and UiTheme.key_name(GameState.key_for("interact")) != _key:
		show_prompt(_raw_prompt)
	if prompt_panel.visible and prompt_panel.modulate.a < 1.0:
		prompt_panel.modulate.a = minf(prompt_panel.modulate.a + delta / FADE_IN_S, 1.0)
	if announce_box.visible:
		_announce_t -= delta
		if _announce_t <= 0.0:
			_next_announce()
		else:
			var shown := ANNOUNCE_S - _announce_t
			announce_box.modulate.a = clampf(minf(shown / FADE_IN_S, _announce_t / FADE_OUT_S), 0.0, 1.0)


func _process(delta: float) -> void:
	tick(delta)


func _next_announce() -> void:
	if queue.is_empty():
		announce_box.visible = false
		return
	var item: PackedStringArray = queue.pop_front()
	announce_caption.text = item[0]
	announce_title.text = item[1]
	announce_box.visible = true
	announce_box.modulate.a = 0.0
	_announce_t = ANNOUNCE_S
