class_name ChunkManager
extends Node3D
## Стриминг чанков вокруг точки фокуса (обычно — машина игрока).
## Данные чанка считаются в WorkerThreadPool, узлы собираются на основном
## потоке не больше max_builds_per_frame за кадр; дальние чанки выгружаются.

signal chunk_loaded(coord: Vector2i)

@export_range(1, 5) var load_radius: int = 2 ## в чанках
@export_range(1, 4) var max_parallel_tasks: int = 2
@export_range(1, 4) var max_builds_per_frame: int = 1

var world_seed: int = 0
var materials: WorldMaterials
var focus: Node3D

var _chunks: Dictionary = {} ## Vector2i -> WorldChunk
var _tasks: Dictionary = {} ## Vector2i -> task id
var _results: Dictionary = {} ## Vector2i -> Dictionary (пишут рабочие потоки)
var _mutex := Mutex.new()


func setup(seed_value: int, mats: WorldMaterials) -> void:
	world_seed = seed_value
	materials = mats


func is_loaded_at(pos: Vector3) -> bool:
	return _chunks.has(WorldGen.chunk_of(pos))


func loaded_count() -> int:
	return _chunks.size()


func pending_count() -> int:
	return _tasks.size()


## Синхронно строит чанки в радиусе radius вокруг pos (экран загрузки).
func generate_now(pos: Vector3, radius: int) -> void:
	var center := WorldGen.chunk_of(pos)
	var gen := WorldGen.new(world_seed)
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var c := center + Vector2i(dx, dz)
			if not _chunks.has(c) and not _tasks.has(c):
				_build_node(gen.build_chunk_data(c))


func _process(_delta: float) -> void:
	if focus == null or materials == null:
		return
	var center := WorldGen.chunk_of(focus.global_position)

	# Чанк под игроком нужен немедленно — иначе машина провалится.
	if not _chunks.has(center):
		if _tasks.has(center):
			WorkerThreadPool.wait_for_task_completion(_tasks[center])
			_tasks.erase(center)
			_mutex.lock()
			var data: Dictionary = _results.get(center, {})
			_results.erase(center)
			_mutex.unlock()
			_build_node(data if not data.is_empty() else WorldGen.new(world_seed).build_chunk_data(center))
		else:
			_build_node(WorldGen.new(world_seed).build_chunk_data(center))

	_collect_finished()
	_queue_missing(center)
	_unload_far(center)


func _queue_missing(center: Vector2i) -> void:
	if _tasks.size() >= max_parallel_tasks:
		return
	var wanted: Array[Vector2i] = []
	var r2 := (load_radius + 0.5) * (load_radius + 0.5)
	for dz in range(-load_radius, load_radius + 1):
		for dx in range(-load_radius, load_radius + 1):
			if dx * dx + dz * dz > r2:
				continue
			var c := center + Vector2i(dx, dz)
			if not _chunks.has(c) and not _tasks.has(c):
				wanted.append(c)
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - center).length_squared() < (b - center).length_squared())
	for c in wanted:
		if _tasks.size() >= max_parallel_tasks:
			break
		_tasks[c] = WorkerThreadPool.add_task(_generate_task.bind(c), false, "chunk")


## Выполняется в рабочем потоке: только вычисления, без сцены.
func _generate_task(c: Vector2i) -> void:
	var data := WorldGen.new(world_seed).build_chunk_data(c)
	_mutex.lock()
	_results[c] = data
	_mutex.unlock()


func _collect_finished() -> void:
	var built := 0
	for c: Vector2i in _tasks.keys():
		if built >= max_builds_per_frame:
			break
		var id: int = _tasks[c]
		if not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		_tasks.erase(c)
		_mutex.lock()
		var data: Dictionary = _results.get(c, {})
		_results.erase(c)
		_mutex.unlock()
		if not data.is_empty() and not _chunks.has(c):
			_build_node(data)
			built += 1


func _build_node(data: Dictionary) -> void:
	var chunk := WorldChunk.new()
	chunk.build(data, materials)
	add_child(chunk)
	_chunks[chunk.coord] = chunk
	chunk_loaded.emit(chunk.coord)


func _unload_far(center: Vector2i) -> void:
	var limit := load_radius + 1
	for c: Vector2i in _chunks.keys():
		if absi(c.x - center.x) > limit or absi(c.y - center.y) > limit:
			(_chunks[c] as Node).queue_free()
			_chunks.erase(c)


func _exit_tree() -> void:
	for c: Vector2i in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(_tasks[c])
	_tasks.clear()
	_results.clear()
