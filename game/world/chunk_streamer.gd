class_name ChunkStreamer
extends Node3D
## Мир в игре: держит загруженными только чанки вокруг target (игрока).
## Сцены чанков читаются с диска в фоновых потоках (ResourceLoader
## threaded), а в дерево добавляются по одной за кадр, ближние первыми.
## Дальние чанки выгружаются. Что есть в мире, где старт и дороги — из
## WorldIndex, поэтому дорожная сеть известна целиком без загрузки чанков.
##
## Если target оказался в незагруженном чанке (телепорт, респаун), этот чанк
## и соседи грузятся сразу, с ожиданием, чтобы машина не провалилась.

signal chunk_loaded(coord: Vector2i)

## Чанки ближе этого к target (по расстоянию до края чанка) должны быть загружены.
@export var load_radius_m: float = 600.0
## Запас сверх load_radius_m до выгрузки: чтобы чанк не мигал на границе.
@export var unload_margin_m: float = 192.0
## Сколько готовых чанков добавлять в дерево за кадр (каждый — заметная работа:
## деревья, коллизия, полотно дорог).
@export var adds_per_frame: int = 1
## При телепорте грузим без ожидания всё ближе этого к новой точке.
const URGENT_RADIUS_M := 64.0

var index: WorldIndex
var target: Node3D

## Замеры для отладки: сколько длилось добавление чанка в дерево, мс.
var last_add_ms: float = 0.0
var max_add_ms: float = 0.0

var _rect := Rect2() ## границы мира
var _loaded: Dictionary = {} ## Vector2i -> WorldChunk
var _pending: Dictionary = {} ## Vector2i -> путь сцены (идёт фоновая загрузка)


static func create(idx: WorldIndex) -> ChunkStreamer:
	var s := ChunkStreamer.new()
	s.name = "World"
	s.index = idx
	s._rect = idx.world_rect()
	return s


func _ready() -> void:
	add_child(make_bounds(_rect))


## Невидимые стены по краю мира (общие для world.tscn и игры).
static func make_bounds(r: Rect2) -> StaticBody3D:
	var bounds := StaticBody3D.new()
	bounds.name = "Bounds"
	bounds.collision_layer = WorldDefs.LAYER_WORLD
	bounds.collision_mask = 0
	var c := r.get_center()
	const T := 20.0
	const H := 400.0
	var walls := [
		[Vector3(r.position.x - T * 0.5, 0, c.y), Vector3(T, H, r.size.y + T * 2.0)],
		[Vector3(r.end.x + T * 0.5, 0, c.y), Vector3(T, H, r.size.y + T * 2.0)],
		[Vector3(c.x, 0, r.position.y - T * 0.5), Vector3(r.size.x + T * 2.0, H, T)],
		[Vector3(c.x, 0, r.end.y + T * 0.5), Vector3(r.size.x + T * 2.0, H, T)],
	]
	for i in walls.size():
		var box := BoxShape3D.new()
		box.size = walls[i][1]
		var wcs := CollisionShape3D.new()
		wcs.name = "Wall%d" % i
		wcs.shape = box
		wcs.position = walls[i][0]
		bounds.add_child(wcs)
	return bounds


# --- Запросы ----------------------------------------------------------------

## Чанк под точкой загружен (по нему можно ездить и спавнить).
func contains(pos: Vector3) -> bool:
	return _loaded.has(WorldDefs.chunk_of(pos))


## Точка внутри границ мира (загружен там чанк или нет).
func in_world(pos: Vector3) -> bool:
	return _rect.has_point(Vector2(pos.x, pos.z))


func chunks() -> Array[WorldChunk]:
	var out: Array[WorldChunk] = []
	for c: WorldChunk in _loaded.values():
		out.append(c)
	return out


func start_transform() -> Transform3D:
	return index.start_transform


## Все чанки в радиусе загрузки уже в дереве, фоновых загрузок нет.
func is_settled() -> bool:
	if not _pending.is_empty():
		return false
	if target == null:
		return true
	for c in _wanted(target.global_position, load_radius_m):
		if not _loaded.has(c):
			return false
	return true


# --- Загрузка ----------------------------------------------------------------

## Стартовая загрузка (корутина): чанки в radius_m вокруг pos грузятся
## параллельно в фоне, кадры при этом идут (экран загрузки не замирает).
func load_initial(pos: Vector3, radius_m: float) -> void:
	var need := _wanted(pos, radius_m)
	for c in need:
		_request(c)
	while true:
		var waiting := false
		for c in need:
			if _pending.has(c):
				var st := ResourceLoader.load_threaded_get_status(_pending[c])
				if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					waiting = true
				else:
					_finish(c)
		if not waiting:
			break
		await get_tree().process_frame


## Сразу, с ожиданием, загрузить чанки в radius_m вокруг pos.
func load_now(pos: Vector3, radius_m: float = URGENT_RADIUS_M) -> void:
	for c in _wanted(pos, radius_m):
		if _loaded.has(c):
			continue
		if not _pending.has(c):
			_add(c, load(WorldDefs.chunk_scene_path(c)) as PackedScene)
		else:
			_finish(c) # load_threaded_get дождётся конца фоновой загрузки


func _physics_process(_delta: float) -> void:
	# До физики машин (стример раньше них в дереве): под target должна быть земля.
	if target == null:
		return
	var p := target.global_position
	if in_world(p) and not contains(p):
		load_now(p)


func _process(_delta: float) -> void:
	if target == null or index == null:
		return
	var p := target.global_position
	for c in index.chunk_coords:
		var d := distance_to_chunk(p, c)
		if d <= load_radius_m:
			if not _loaded.has(c) and not _pending.has(c):
				_request(c)
		elif d > load_radius_m + unload_margin_m and _loaded.has(c):
			_unload(c)

	# Готовые фоновые загрузки — в дерево, ближние первыми.
	var done: Array[Vector2i] = []
	for c: Vector2i in _pending:
		var st := ResourceLoader.load_threaded_get_status(_pending[c])
		if st != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			done.append(c)
	done.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return distance_to_chunk(p, a) < distance_to_chunk(p, b))
	var added := 0
	for c in done:
		if added >= adds_per_frame:
			break
		if distance_to_chunk(p, c) > load_radius_m + unload_margin_m:
			# Пока грузился, игрок уехал: результат забираем (иначе висит в
			# ResourceLoader) и выбрасываем.
			ResourceLoader.load_threaded_get(_pending[c])
			_pending.erase(c)
			continue
		_finish(c)
		added += 1


func _request(c: Vector2i) -> void:
	if _loaded.has(c) or _pending.has(c):
		return
	var path := WorldDefs.chunk_scene_path(c)
	if DisplayServer.get_name() == "headless":
		# Пустой рендер headless (тесты) не потокобезопасен: меши чанка из
		# фонового потока и меши дорог в главном портят его хранилище.
		_add(c, load(path) as PackedScene)
		return
	var err := ResourceLoader.load_threaded_request(path, "PackedScene")
	if err != OK:
		push_error("Чанк %s: не удалось начать загрузку (%s)" % [path, error_string(err)])
		return
	_pending[c] = path


## Забрать результат фоновой загрузки (ждёт, если ещё идёт) и добавить чанк.
func _finish(c: Vector2i) -> void:
	var path: String = _pending[c]
	_pending.erase(c)
	var ps := ResourceLoader.load_threaded_get(path) as PackedScene
	if ps == null:
		push_error("Чанк %s не загрузился" % path)
		return
	_add(c, ps)


func _add(c: Vector2i, ps: PackedScene) -> void:
	if _loaded.has(c) or ps == null:
		return
	var t0 := Time.get_ticks_usec()
	var chunk := ps.instantiate() as WorldChunk
	chunk.name = "Chunk_%d_%d" % [c.x, c.y]
	chunk.position = Vector3(c.x, 0.0, c.y) * WorldDefs.CHUNK_SIZE
	add_child(chunk)
	last_add_ms = (Time.get_ticks_usec() - t0) / 1000.0
	max_add_ms = maxf(max_add_ms, last_add_ms)
	_loaded[c] = chunk
	chunk_loaded.emit(c)


func _unload(c: Vector2i) -> void:
	var chunk: WorldChunk = _loaded[c]
	_loaded.erase(c)
	chunk.queue_free()


## Существующие чанки ближе radius_m к pos.
func _wanted(pos: Vector3, radius_m: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in index.chunk_coords:
		if distance_to_chunk(pos, c) <= radius_m:
			out.append(c)
	return out


## Расстояние от pos до ближайшей точки чанка в плоскости XZ (0 — внутри).
static func distance_to_chunk(pos: Vector3, c: Vector2i) -> float:
	var s := WorldDefs.CHUNK_SIZE
	var dx := maxf(maxf(c.x * s - pos.x, pos.x - (c.x + 1) * s), 0.0)
	var dz := maxf(maxf(c.y * s - pos.z, pos.z - (c.y + 1) * s), 0.0)
	return sqrt(dx * dx + dz * dz)
