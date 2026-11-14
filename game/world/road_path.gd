@tool
class_name RoadPath
extends Path3D
## Участок дороги в чанке. Форма задаётся кривой Path3D и правится прямо в
## редакторе: полотно и коллизия перестраиваются при изменении кривой.
## Концы участков, которые ближе WorldDefs.JOIN_DISTANCE_M друг к другу,
## игра считает одним узлом дорожной сети (так связываются чанки и перекрёстки).

const SAMPLE_M := 4.0
const SKIRT_M := 0.8

@export var road_type: WorldDefs.RoadType = WorldDefs.RoadType.HIGHWAY:
	set(v):
		road_type = v
		_queue_rebuild()
## Сдвиг текстуры вдоль дороги, чтобы разметка не рвалась на стыке чанков.
@export var uv_offset_m: float = 0.0:
	set(v):
		uv_offset_m = v
		_queue_rebuild()

var _mesh_instance: MeshInstance3D
var _body: StaticBody3D
var _rebuild_queued := false


func _ready() -> void:
	if not curve_changed.is_connected(_queue_rebuild):
		curve_changed.connect(_queue_rebuild)
	_rebuild()


func width() -> float:
	return WorldDefs.ROAD_WIDTHS[road_type]


func is_highway() -> bool:
	return road_type == WorldDefs.RoadType.HIGHWAY


## Точки оси в глобальных координатах с шагом ~SAMPLE_M.
func sample_global_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	if curve == null or curve.point_count < 2:
		return out
	var length := curve.get_baked_length()
	var n := maxi(2, ceili(length / SAMPLE_M))
	var xf := global_transform if is_inside_tree() else transform
	for k in n + 1:
		out.append(xf * curve.sample_baked(length * k / n, true))
	return out


func _queue_rebuild() -> void:
	if _rebuild_queued or not is_inside_tree():
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	if _mesh_instance != null:
		_mesh_instance.queue_free()
		_mesh_instance = null
	if _body != null:
		_body.queue_free()
		_body = null
	if curve == null or curve.point_count < 2:
		return
	var length := curve.get_baked_length()
	var n := maxi(2, ceili(length / SAMPLE_M))
	var pts := PackedVector3Array()
	for k in n + 1:
		pts.append(curve.sample_baked(length * k / n, true))
	var step := length / n
	var hw := width() * 0.5
	var lift := Vector3(0.0, WorldDefs.ROAD_LIFT_M, 0.0)
	var skirt := Vector3(0.0, -SKIRT_M, 0.0)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	for k in n:
		var p0 := pts[k]
		var p1 := pts[k + 1]
		var r0 := _right(pts, k) * hw
		var r1 := _right(pts, k + 1) * hw
		var l0 := p0 - r0 + lift
		var rr0 := p0 + r0 + lift
		var l1 := p1 - r1 + lift
		var rr1 := p1 + r1 + lift
		var nrm := (l1 - l0).cross(rr0 - l0).normalized()
		if nrm.y < 0.0:
			nrm = -nrm
		var v0 := (uv_offset_m + k * step) / 10.0
		var v1 := (uv_offset_m + (k + 1) * step) / 10.0
		var base := verts.size()
		verts.append_array([l0, rr0, l1, rr1])
		normals.append_array([nrm, nrm, nrm, nrm])
		uvs.append_array([Vector2(0, v0), Vector2(1, v0), Vector2(0, v1), Vector2(1, v1)])
		indices.append_array([base, base + 2, base + 1, base + 1, base + 2, base + 3])
		faces.append_array([l0, l1, rr0, rr0, l1, rr1])
		# Боковые «юбки» закрывают щель между полотном и рельефом.
		var sb := verts.size()
		var ln := -r0.normalized()
		verts.append_array([l0, l1, l0 + skirt, l1 + skirt])
		normals.append_array([ln, ln, ln, ln])
		uvs.append_array([Vector2(0, v0), Vector2(0, v1), Vector2(0, v0), Vector2(0, v1)])
		indices.append_array([sb, sb + 2, sb + 1, sb + 1, sb + 2, sb + 3])
		var rb := verts.size()
		var rn := r0.normalized()
		verts.append_array([rr0, rr1, rr0 + skirt, rr1 + skirt])
		normals.append_array([rn, rn, rn, rn])
		uvs.append_array([Vector2(1, v0), Vector2(1, v1), Vector2(1, v0), Vector2(1, v1)])
		indices.append_array([rb, rb + 1, rb + 2, rb + 1, rb + 3, rb + 2])

	var mats := WorldMaterials.shared()
	var surface := WorldDefs.Surface.ASPHALT if is_highway() else WorldDefs.Surface.DIRT
	var built := WorldMaterials.build_static(verts, normals, uvs, indices, faces,
		mats.highway if is_highway() else mats.dirt_road, surface)
	_mesh_instance = built[0]
	_body = built[1]
	add_child(_mesh_instance)
	add_child(_body)


static func _right(pts: PackedVector3Array, i: int) -> Vector3:
	var a := pts[maxi(i - 1, 0)]
	var b := pts[mini(i + 1, pts.size() - 1)]
	var t := Vector3(b.x - a.x, 0.0, b.z - a.z)
	t = t.normalized() if t.length_squared() > 0.0001 else Vector3.FORWARD
	return Vector3(-t.z, 0.0, t.x)
