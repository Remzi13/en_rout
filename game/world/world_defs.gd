class_name WorldDefs
extends RefCounted
## Общие константы мира из чанков-сцен: размеры, типы дорог и поверхностей.

const CHUNK_SIZE := 256.0
const WATER_LEVEL := -4.0
const LAYER_WORLD := 1
const ROAD_LIFT_M := 0.06 ## полотно над осью кривой дороги
const JUNCTION_RADIUS_M := 11.0
const JOIN_DISTANCE_M := 2.0 ## концы дорог ближе этого считаются одним узлом

enum RoadType { HIGHWAY, DIRT }
enum Surface { ASPHALT, DIRT, GRASS }

const ROAD_WIDTHS := [12.0, 7.0]


static func chunk_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / CHUNK_SIZE), floori(pos.z / CHUNK_SIZE))


static func chunk_scene_path(c: Vector2i) -> String:
	return "res://game/world/chunks/chunk_%d_%d.tscn" % [c.x, c.y]


## Прямоугольник в плоскости XZ, покрывающий все чанки списка. Размер мира
## задаёт карта (art/map/map.blend), список чанков — WorldIndex.
static func rect_of_chunks(coords: Array[Vector2i]) -> Rect2:
	if coords.is_empty():
		return Rect2()
	var lo := coords[0]
	var hi := coords[0]
	for c in coords:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	return Rect2(Vector2(lo) * CHUNK_SIZE, Vector2(hi - lo + Vector2i.ONE) * CHUNK_SIZE)
