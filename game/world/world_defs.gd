class_name WorldDefs
extends RefCounted
## Общие константы мира из чанков-сцен: размеры, типы дорог и поверхностей.

const CHUNK_SIZE := 256.0
const CHUNKS_X := 5
const CHUNKS_Z := 5
const CHUNK_MIN := Vector2i(-2, -2) ## координата левого нижнего чанка
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


## Прямоугольник мира в плоскости XZ.
static func world_rect() -> Rect2:
	return Rect2(CHUNK_MIN.x * CHUNK_SIZE, CHUNK_MIN.y * CHUNK_SIZE, CHUNKS_X * CHUNK_SIZE, CHUNKS_Z * CHUNK_SIZE)
