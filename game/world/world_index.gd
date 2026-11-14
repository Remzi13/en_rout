@tool
class_name WorldIndex
extends Resource
## Лёгкая сводка мира для игры с подгрузкой чанков: какие чанки есть, где
## старт и вся дорожная сеть (точки осей RoadPath в глобальных координатах).
## Игра строит из неё RoadNetwork, не загружая сами чанки, поэтому трафик,
## респаун и радар видят дороги всего мира.
##
## Пишется запеканием карты (tools/export_map.sh -> tools/bake_world.gd)
## вместе с чанками; тест test_world_map проверяет, что он совпадает со сценой.

const PATH := "res://game/world/world_index.tres"

@export var start_transform: Transform3D = Transform3D(Basis(), Vector3(0, 5, 0))
@export var chunk_coords: Array[Vector2i] = []
@export var road_points: Array[PackedVector3Array] = []
@export var road_types: PackedInt32Array = PackedInt32Array()


static func load_baked() -> WorldIndex:
	return load(PATH) as WorldIndex


## Сводка по собранной сцене мира. map должен быть в дереве сцены
## (иначе глобальные координаты дорог не посчитать).
static func from_map(map: WorldMap) -> WorldIndex:
	var idx := WorldIndex.new()
	idx.start_transform = map.start_transform()
	for c in map.chunks():
		idx.chunk_coords.append(c.coord)
	for path: RoadPath in map.find_children("*", "RoadPath", true, false):
		var pts := path.sample_global_points()
		if pts.size() < 2:
			continue
		idx.road_points.append(pts)
		idx.road_types.append(path.road_type)
	return idx


static func save_from(map: WorldMap) -> Error:
	var idx := from_map(map)
	var err := ResourceSaver.save(idx, PATH)
	if err == OK:
		print("Индекс мира обновлён: %d чанков, %d участков дорог -> %s" % [idx.chunk_coords.size(), idx.road_points.size(), PATH])
	else:
		push_error("Не удалось сохранить %s: %s" % [PATH, error_string(err)])
	return err


func has_chunk(c: Vector2i) -> bool:
	return chunk_coords.has(c)


## Границы мира в плоскости XZ.
func world_rect() -> Rect2:
	return WorldDefs.rect_of_chunks(chunk_coords)
