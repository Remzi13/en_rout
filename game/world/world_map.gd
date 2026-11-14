@tool
class_name WorldMap
extends Node3D
## Корень game/world/world.tscn: все сцены-чанки, точка старта игрока
## (PlayerStart) и невидимые стены по краю мира (Bounds). Сцена для обзора
## в редакторе и для запекания индекса: игра её не грузит (чанки подгружает
## ChunkStreamer, старт и дороги — из WorldIndex).
## Сцена и чанки пересоздаются tools/export_map.sh из art/map/map.blend:
## править карту нужно в Blender, правки здесь пропадут.


func chunks() -> Array[WorldChunk]:
	var out: Array[WorldChunk] = []
	for c in get_children():
		if c is WorldChunk:
			out.append(c)
	return out


func start_transform() -> Transform3D:
	var m := get_node_or_null("PlayerStart") as Node3D
	return m.global_transform if m != null else Transform3D(Basis(), Vector3(0, 5, 0))

