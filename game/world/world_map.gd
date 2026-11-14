@tool
class_name WorldMap
extends Node3D
## Корень game/world/world.tscn: экземпляры сцен-чанков 5×5, точка старта
## игрока (PlayerStart) и невидимые стены по краю мира (Bounds).
## Чтобы поправить чанк, откройте его сцену или включите «Editable Children».


func contains(pos: Vector3) -> bool:
	return WorldDefs.world_rect().has_point(Vector2(pos.x, pos.z))


func chunks() -> Array[WorldChunk]:
	var out: Array[WorldChunk] = []
	for c in get_children():
		if c is WorldChunk:
			out.append(c)
	return out


func start_transform() -> Transform3D:
	var m := get_node_or_null("PlayerStart") as Node3D
	return m.global_transform if m != null else Transform3D(Basis(), Vector3(0, 5, 0))
