class_name MapScreen
extends Control
## Полноэкранная карта-схема (задача 6, «Договор задачи 6» в
## docs/vertical-slice.md). Открывается действием map во время игры (если
## дерево не на паузе: не в меню паузы и не поверх настроек), закрывается map
## или Esc; пока открыта — игра на паузе. Появляется плавно (FADE_IN_S).
##
## Мир вписан в экран целиком с полями, север (−Z) сверху, без масштабирования.
## Слои снизу вверх: подложка map_base.png (нет файла — однотонная земля
## с сеткой чанков), дороги из WorldIndex по типам, подписи точек Spots,
## места (открытое — флажок с названием, неоткрытое — «?»), точки взятия,
## цель активной доставки, игрок со стрелкой. Сверху — строка «Везу: …»,
## внизу — легенда и подсказка закрытия. Ночью подложка темнее, значки те же.
##
## Пересчёт «мир → экран» — статические fit_rect / world_to_screen, значки —
## marks(): тесты зовут их без отрисовки. Данные ставит setup() (main.gd —
## из мира, тест — подставные).

signal opened
signal closed

const BASE_PATH := "res://game/world/map_base.png" ## тот же путь, что MapBase.PATH в tools/map_base.gd
const FADE_IN_S := 0.2
## Поля вокруг карты в пикселях холста (холст 1920×1080, canvas_items).
const MARGIN_TOP_PX := 92.0
const MARGIN_BOTTOM_PX := 96.0
const MARGIN_SIDE_PX := 48.0
## Шаг точек дороги при отрисовке (точки осей идут часто).
const ROAD_STEP := 2

const MARK_PLAYER := "player"
const MARK_GOAL := "goal"
const MARK_PICKUP := "pickup"
const MARK_PLACE := "place"
const MARK_UNKNOWN := "unknown"
const MARK_SPOT := "spot"

const BG := Color(0.06, 0.07, 0.09)
## Однотонная земля без подложки: «поле» из палитры, приглушённое.
const GROUND := Color(0.36, 0.44, 0.22)
const GRID := Color(1, 1, 1, 0.06)
const NIGHT_TINT := Color(0.5, 0.56, 0.72)
const ASPHALT := Color(0.9, 0.89, 0.84)
const DIRT := Color(0.84, 0.68, 0.46)
const CASING := Color(0.1, 0.1, 0.08, 0.55)
const OUTLINE := Color(0.02, 0.03, 0.05, 0.9)
const PLAYER := Color(0.95, 0.42, 0.06)

var index: WorldIndex
var player: Node3D
var places: PlaceTracker
var deliveries: Deliveries
var is_open: bool = false
## Подложка или null (нет файла — однотонный фон).
var base_texture: Texture2D

var goal_label: Label
var hint_label: Label

var _world_rect := Rect2()
var _map_rect := Rect2()
var _spots: Array[Dictionary] = []
## Дороги в координатах экрана: [{points: PackedVector2Array, type: int}].
var _roads: Array[Dictionary] = []
var _font: Font


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	theme = UiTheme.get_theme()
	_font = ThemeDB.fallback_font

	goal_label = UiTheme.label("", 26, UiTheme.GOAL)
	UiTheme.anchor(goal_label, Control.PRESET_CENTER_TOP, Rect2(Vector2(-700, 30), Vector2(1400, 40)))
	goal_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(goal_label)
	hint_label = UiTheme.label("", 20, Color(1, 1, 1, 0.7))
	UiTheme.anchor(hint_label, Control.PRESET_BOTTOM_RIGHT, Rect2(Vector2(-460, -64), Vector2(412, 32)))
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(hint_label)
	resized.connect(_rebuild)


func setup(idx: WorldIndex, car: Node3D, pl: PlaceTracker, del: Deliveries) -> void:
	index = idx
	player = car
	places = pl
	deliveries = del
	base_texture = load_base(BASE_PATH)
	_spots = PlaceTracker.normalize(PlaceTracker.from_index(idx, "spots"), 1.0)
	_world_rect = idx.world_rect() if idx != null else Rect2()
	_rebuild()


## Подложка: импортированная текстура, иначе картинка с диска; нет — null.
static func load_base(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex != null:
			return tex
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img != null and not img.is_empty():
			return ImageTexture.create_from_image(img)
	return null


# --- Пересчёт «мир → экран» ---------------------------------------------

## Прямоугольник карты на экране: мир целиком внутри area, пропорции
## сохранены, по центру. Пустой мир — пустой прямоугольник в центре area.
static func fit_rect(world_rect: Rect2, area: Rect2) -> Rect2:
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0 or area.size.x <= 0.0 or area.size.y <= 0.0:
		return Rect2(area.get_center(), Vector2.ZERO)
	var k := minf(area.size.x / world_rect.size.x, area.size.y / world_rect.size.y)
	var sz := world_rect.size * k
	return Rect2(area.position + (area.size - sz) * 0.5, sz)


## Точка мира на экране: x мира — вправо, z мира — вниз (север, −Z, сверху),
## как у подложки по договору. Высота не учитывается.
static func world_to_screen(world_pos: Vector3, world_rect: Rect2, map_rect: Rect2) -> Vector2:
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return map_rect.get_center()
	var u := (world_pos.x - world_rect.position.x) / world_rect.size.x
	var v := (world_pos.z - world_rect.position.y) / world_rect.size.y
	return map_rect.position + Vector2(u, v) * map_rect.size


## Направление курса на экране по повороту машины вокруг Y (вперёд — −Z).
static func heading_dir(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


## Курс машины на карте по её базису: «вперёд» (−Z) без наклона.
## Надёжнее угла Эйлера, когда машина перевернулась или сильно накренилась.
static func heading_of(basis: Basis) -> Vector2:
	var fwd := -basis.z
	var flat := Vector2(fwd.x, fwd.z)
	return flat.normalized() if flat.length() > 0.001 else Vector2(0, -1)


## Поле для карты внутри экрана размера screen.
static func map_area(screen: Vector2) -> Rect2:
	return Rect2(MARGIN_SIDE_PX, MARGIN_TOP_PX,
		screen.x - MARGIN_SIDE_PX * 2.0, screen.y - MARGIN_TOP_PX - MARGIN_BOTTOM_PX)


func map_rect() -> Rect2:
	return _map_rect


func _rebuild() -> void:
	_map_rect = fit_rect(_world_rect, map_area(size))
	_roads.clear()
	if index == null:
		return
	for i in index.road_points.size():
		var pts: PackedVector3Array = index.road_points[i]
		var out := PackedVector2Array()
		for j in range(0, pts.size(), ROAD_STEP):
			out.append(world_to_screen(pts[j], _world_rect, _map_rect))
		if pts.size() > 0 and (pts.size() - 1) % ROAD_STEP != 0:
			out.append(world_to_screen(pts[pts.size() - 1], _world_rect, _map_rect))
		if out.size() >= 2:
			var t: int = index.road_types[i] if i < index.road_types.size() else WorldDefs.RoadType.HIGHWAY
			_roads.append({"points": out, "type": t})


# --- Открытие и закрытие ------------------------------------------------

## Открывает карту и ставит игру на паузу. Не открывается поверх паузы
## (дерево уже на паузе: меню паузы, настройки) и без данных мира.
func open() -> bool:
	if is_open or not is_inside_tree() or get_tree().paused or index == null:
		return false
	is_open = true
	_rebuild()
	refresh_texts()
	visible = true
	modulate.a = 0.0
	get_tree().paused = true
	opened.emit()
	return true


func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	get_tree().paused = false
	closed.emit()


func refresh_texts() -> void:
	var goal := ""
	if deliveries != null and deliveries.active != null:
		var to: Dictionary = deliveries.spots.get(deliveries.active.to_spot, {})
		goal = "Везу: %s → %s" % [deliveries.active.cargo, to.get("title", deliveries.active.to_spot)]
	goal_label.text = goal
	hint_label.text = "%s / Esc — закрыть" % UiTheme.key_name(GameState.key_for("map"))


func _unhandled_input(event: InputEvent) -> void:
	if is_open:
		if event.is_action_pressed("map") or event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			close()
	elif event.is_action_pressed("map") and open():
		get_viewport().set_input_as_handled()


func tick(delta: float) -> void:
	if is_open and modulate.a < 1.0:
		modulate.a = minf(modulate.a + delta / FADE_IN_S, 1.0)


func _process(delta: float) -> void:
	if is_open:
		tick(delta)
		queue_redraw()


# --- Значки -------------------------------------------------------------

## Значки на экране: {kind, pos (px), title, dir (только у игрока)}.
## Порядок — порядок рисования: подписи точек, места, точки взятия, цель, игрок.
func marks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in _spots:
		out.append({"kind": MARK_SPOT, "pos": _to_screen(s["position"]), "title": s["title"]})
	if places != null:
		for pl in places.all_places():
			var open_place: bool = pl["open"]
			out.append({"kind": MARK_PLACE if open_place else MARK_UNKNOWN, "pos": _to_screen(pl["position"]),
				"title": pl["title"] if open_place else ""})
	if deliveries != null:
		for s in deliveries.available_spots():
			out.append({"kind": MARK_PICKUP, "pos": _to_screen(s["position"]), "title": s.get("cargo", "")})
		if deliveries.has_target():
			out.append({"kind": MARK_GOAL, "pos": _to_screen(deliveries.target_position()), "title": ""})
	if player != null and is_instance_valid(player) and player.is_inside_tree():
		out.append({"kind": MARK_PLAYER, "pos": _to_screen(player.global_position), "title": "",
			"dir": heading_of(player.global_basis)})
	return out


func _to_screen(p: Vector3) -> Vector2:
	return world_to_screen(p, _world_rect, _map_rect)


# --- Отрисовка ----------------------------------------------------------

func _draw() -> void:
	var night := GameState.is_night
	draw_rect(Rect2(Vector2.ZERO, size), BG.darkened(0.3) if night else BG)
	if _map_rect.size.x <= 0.0:
		_draw_legend()
		return
	var tint := NIGHT_TINT if night else Color.WHITE
	draw_rect(_map_rect.grow(3.0), Color(1, 1, 1, 0.18))
	if base_texture != null:
		draw_texture_rect(base_texture, _map_rect, false, tint)
	else:
		draw_rect(_map_rect, GROUND * tint)
		_draw_grid()
	_draw_roads()
	_draw_marks(marks())
	_draw_north()
	_draw_legend()


func _draw_grid() -> void:
	var step := WorldDefs.CHUNK_SIZE * _map_rect.size.x / _world_rect.size.x
	var x := _map_rect.position.x + step
	while x < _map_rect.end.x - 1.0:
		draw_line(Vector2(x, _map_rect.position.y), Vector2(x, _map_rect.end.y), GRID, 1.0)
		x += step
	var y := _map_rect.position.y + step
	while y < _map_rect.end.y - 1.0:
		draw_line(Vector2(_map_rect.position.x, y), Vector2(_map_rect.end.x, y), GRID, 1.0)
		y += step


func _road_width(t: int) -> float:
	var k := _map_rect.size.x / _world_rect.size.x
	var w: float = WorldDefs.ROAD_WIDTHS[clampi(t, 0, WorldDefs.ROAD_WIDTHS.size() - 1)] * k
	return maxf(w, 4.0 if t == WorldDefs.RoadType.HIGHWAY else 3.0)


func _draw_roads() -> void:
	# Сначала обводка всех дорог, потом полотно: перекрёстки без швов.
	# Грунтовки под асфальтом.
	for pass_i in 2:
		for t in [WorldDefs.RoadType.DIRT, WorldDefs.RoadType.HIGHWAY]:
			var w := _road_width(t)
			for r in _roads:
				if r["type"] != t:
					continue
				if pass_i == 0:
					draw_polyline(r["points"], CASING, w + 2.5, true)
				else:
					draw_polyline(r["points"], ASPHALT if t == WorldDefs.RoadType.HIGHWAY else DIRT, w, true)


func _draw_marks(list: Array[Dictionary]) -> void:
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 260.0)
	var labels: Array[Dictionary] = []
	for m in list:
		var q: Vector2 = m["pos"]
		match m["kind"]:
			MARK_SPOT:
				draw_circle(q, 4.5, OUTLINE)
				draw_circle(q, 2.8, Color(1, 1, 1, 0.85))
				labels.append({"pos": q, "text": m["title"], "size": 18, "color": Color(1, 1, 1, 0.88)})
			MARK_PLACE:
				_draw_flag(q)
				labels.append({"pos": q, "text": m["title"], "size": 20, "color": UiTheme.PLACE})
			MARK_UNKNOWN:
				draw_circle(q, 13.0, OUTLINE)
				draw_arc(q, 13.0, 0.0, TAU, 28, Color(UiTheme.PLACE, 0.9), 2.5, true)
				draw_string(_font, q + Vector2(-13, 8), "?", HORIZONTAL_ALIGNMENT_CENTER, 26, 22, UiTheme.PLACE)
			MARK_PICKUP:
				_draw_pickup(q, 8.0)
			MARK_GOAL:
				draw_arc(q, 18.0 + 8.0 * pulse, 0.0, TAU, 32, Color(UiTheme.GOAL, 0.85 * (1.0 - pulse)), 3.0, true)
				_draw_goal(q, 13.0)
			MARK_PLAYER:
				_draw_player(q, m["dir"], 1.0)
	# Подписи обходят и чужие значки.
	var icons: Array[Rect2] = []
	for m in list:
		icons.append(Rect2(m["pos"] - Vector2(11, 11), Vector2(22, 22)))
	_draw_labels(labels, icons)


func _draw_flag(q: Vector2, s: float = 1.3) -> void:
	var pole: PackedVector2Array = [q + Vector2(-4, 8) * s, q + Vector2(-4, -10) * s]
	var flag := PackedVector2Array([q + Vector2(-4, -10) * s, q + Vector2(8, -5.5) * s, q + Vector2(-4, -1) * s])
	draw_line(pole[0], pole[1], OUTLINE, 6.0)
	draw_colored_polygon(PackedVector2Array([flag[0] + Vector2(-2, -2.5), flag[1] + Vector2(3.5, 0), flag[2] + Vector2(-2, 2.5)]), OUTLINE)
	draw_line(pole[0], pole[1], UiTheme.PLACE, 3.0)
	draw_colored_polygon(flag, UiTheme.PLACE)


func _draw_pickup(q: Vector2, h: float) -> void:
	draw_rect(Rect2(q - Vector2(h + 2.5, h + 2.5), Vector2(h + 2.5, h + 2.5) * 2.0), OUTLINE)
	draw_rect(Rect2(q - Vector2(h, h), Vector2(h, h) * 2.0), UiTheme.PICKUP)


func _draw_goal(q: Vector2, d: float) -> void:
	var o := d + 3.5
	draw_colored_polygon(PackedVector2Array([q + Vector2(0, -o), q + Vector2(o, 0), q + Vector2(0, o), q + Vector2(-o, 0)]), OUTLINE)
	draw_colored_polygon(PackedVector2Array([q + Vector2(0, -d), q + Vector2(d, 0), q + Vector2(0, d), q + Vector2(-d, 0)]), UiTheme.GOAL)


func _draw_player(q: Vector2, dir: Vector2, s: float) -> void:
	var side := Vector2(-dir.y, dir.x)
	var tip := q + dir * 18.0 * s
	var tri := PackedVector2Array([tip, q - dir * 11.0 * s + side * 12.0 * s, q - dir * 5.0 * s, q - dir * 11.0 * s - side * 12.0 * s])
	var big := PackedVector2Array([q + dir * 23.0 * s, q - dir * 14.5 * s + side * 16.0 * s, q - dir * 8.0 * s, q - dir * 14.5 * s - side * 16.0 * s])
	draw_colored_polygon(big, OUTLINE)
	draw_colored_polygon(tri, PLAYER)


## Подписи справа от значка; если место занято (подписью или значком,
## taken) — слева, ниже или выше.
func _draw_labels(labels: Array[Dictionary], taken: Array[Rect2]) -> void:
	for l in labels:
		var text: String = l["text"]
		if text == "":
			continue
		var fs: int = l["size"]
		var sz := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var q: Vector2 = l["pos"]
		var h := sz.y
		var tries: Array[Vector2] = [Vector2(14, -h * 0.5), Vector2(-14 - sz.x, -h * 0.5), Vector2(14, h * 0.5), Vector2(14, -h * 1.5),
			Vector2(-14 - sz.x, h * 0.5), Vector2(-14 - sz.x, -h * 1.5), Vector2(14, h * 1.5), Vector2(14, -h * 2.5)]
		var at: Rect2 = Rect2(q + tries[0], sz)
		for off: Vector2 in tries:
			var r := Rect2(q + off, sz)
			var free := true
			for t in taken:
				if t.intersects(r):
					free = false
					break
			if free:
				at = r
				break
		taken.append(at)
		var base := at.position + Vector2(0, _font.get_ascent(fs))
		draw_string_outline(_font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, OUTLINE)
		draw_string(_font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, l["color"])


func _draw_north() -> void:
	var c := Vector2(_map_rect.end.x - 30.0, _map_rect.position.y + 40.0)
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -20), c + Vector2(9, 4), c + Vector2(0, -1), c + Vector2(-9, 4)]), Color(1, 1, 1, 0.8))
	draw_string_outline(_font, c + Vector2(-12, 28), "С", HORIZONTAL_ALIGNMENT_CENTER, 24, 20, 4, OUTLINE)
	draw_string(_font, c + Vector2(-12, 28), "С", HORIZONTAL_ALIGNMENT_CENTER, 24, 20, Color(1, 1, 1, 0.85))


## Легенда одной строкой внизу по центру: значок и подпись.
func _draw_legend() -> void:
	var items: Array[Array] = [["player", "Я"], ["goal", "Цель"], ["pickup", "Взять груз"], ["place", "Место"],
		["unknown", "Не открыто"], ["asphalt", "Асфальт"], ["dirt", "Грунтовка"]]
	var fs := 20
	var icon_w := 30.0
	var gap := 34.0
	var total := 0.0
	for it in items:
		total += icon_w + 8.0 + _font.get_string_size(it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	total += gap * (items.size() - 1)
	var y := size.y - 48.0
	var x := (size.x - total) * 0.5
	for it in items:
		var c := Vector2(x + icon_w * 0.5, y)
		match it[0]:
			"player": _draw_player(c + Vector2(0, 2), Vector2.UP, 0.6)
			"goal": _draw_goal(c, 9.0)
			"pickup": _draw_pickup(c, 6.5)
			"place": _draw_flag(c + Vector2(2, 1), 1.0)
			"unknown":
				draw_circle(c, 11.0, OUTLINE)
				draw_arc(c, 11.0, 0.0, TAU, 24, UiTheme.PLACE, 2.0, true)
				draw_string(_font, c + Vector2(-11, 7), "?", HORIZONTAL_ALIGNMENT_CENTER, 22, 18, UiTheme.PLACE)
			"asphalt", "dirt":
				var t := WorldDefs.RoadType.HIGHWAY if it[0] == "asphalt" else WorldDefs.RoadType.DIRT
				var w := 6.0 if t == WorldDefs.RoadType.HIGHWAY else 3.5
				draw_line(c - Vector2(14, 0), c + Vector2(14, 0), CASING, w + 2.5)
				draw_line(c - Vector2(14, 0), c + Vector2(14, 0), ASPHALT if t == WorldDefs.RoadType.HIGHWAY else DIRT, w)
		var base := Vector2(x + icon_w + 8.0, y + _font.get_ascent(fs) * 0.5 - 2.0)
		draw_string_outline(_font, base, it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, OUTLINE)
		draw_string(_font, base, it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.8))
		x += icon_w + 8.0 + _font.get_string_size(it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + gap
