@tool
class_name RoadJunction
extends Node3D
## Площадка развязки шоссе: круг асфальта без разметки чуть выше лент
## (закрывает их наложение). Запекание ставит её там, где сходятся три шоссе
## и больше; остальные перекрёстки — рельеф. На связность сети не влияет.

@export var radius_m: float = WorldDefs.JUNCTION_RADIUS_M:
	set(v):
		radius_m = v
		if is_inside_tree():
			_rebuild()
@export var highway: bool = true:
	set(v):
		highway = v
		if is_inside_tree():
			_rebuild()

var _parts: Array[Node] = []


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for p in _parts:
		p.queue_free()
	_parts.clear()
	const SEGMENTS := 24
	var verts := PackedVector3Array([Vector3.ZERO])
	var uvs := PackedVector2Array([Vector2.ZERO])
	var normals := PackedVector3Array([Vector3.UP])
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	for k in SEGMENTS:
		var ang := TAU * k / SEGMENTS
		var p := Vector3(cos(ang) * radius_m, 0.0, sin(ang) * radius_m)
		verts.append(p)
		uvs.append(Vector2(p.x, p.z) * 0.1)
		normals.append(Vector3.UP)
	for k in SEGMENTS:
		var a := 1 + k
		var b := 1 + (k + 1) % SEGMENTS
		indices.append_array([0, a, b])
		faces.append_array([verts[0], verts[a], verts[b]])
	var mats := WorldMaterials.shared()
	var built := WorldMaterials.build_static(verts, normals, uvs, indices, faces,
		mats.asphalt_plain if highway else mats.dirt_road,
		WorldDefs.Surface.ASPHALT if highway else WorldDefs.Surface.DIRT)
	for node: Node in built:
		add_child(node)
		_parts.append(node)
