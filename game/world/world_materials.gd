@tool
class_name WorldMaterials
extends RefCounted
## Общие материалы и меши мира. Лежат файлами в game/world/assets/ (их
## создаёт tools/bake_world.gd, править можно в редакторе). Загружаются
## один раз и разделяются всеми чанками; погода меняет их на лету.

const DIR := "res://game/world/assets/"

static var _shared: WorldMaterials

var terrain: StandardMaterial3D
var highway: StandardMaterial3D
var asphalt_plain: StandardMaterial3D
var dirt_road: StandardMaterial3D
var water: StandardMaterial3D

var _road_mats: Array[StandardMaterial3D] = []
var _dry_roughness: Dictionary = {}
var _shape_cache: Dictionary = {}


static func shared() -> WorldMaterials:
	if _shared == null:
		_shared = WorldMaterials.new()
	return _shared


func _init() -> void:
	terrain = load(DIR + "terrain.res")
	highway = load(DIR + "highway.res")
	asphalt_plain = load(DIR + "asphalt_plain.res")
	dirt_road = load(DIR + "dirt_road.res")
	water = load(DIR + "water.tres")
	_road_mats = [highway, asphalt_plain, dirt_road]
	for m in _road_mats:
		_dry_roughness[m] = m.roughness


## Мокрая дорога: темнее и глаже (0 — сухо, 1 — ливень).
func set_wetness(k: float) -> void:
	for m in _road_mats:
		m.roughness = lerpf(_dry_roughness[m], 0.28, k)
		m.albedo_color = Color.WHITE.lerp(Color(0.62, 0.62, 0.66), k)
	terrain.albedo_color = Color.WHITE.lerp(Color(0.78, 0.8, 0.78), k)


## Физическая форма-цилиндр для коллизии растительности (кэш по размеру).
func cylinder_shape(radius: float, height: float) -> RID:
	var key := Vector2i(roundi(radius * 10.0), roundi(height))
	if not _shape_cache.has(key):
		var shape := CylinderShape3D.new()
		shape.radius = maxf(key.x / 10.0, 0.2)
		shape.height = maxf(float(key.y), 1.0)
		_shape_cache[key] = shape
	return (_shape_cache[key] as Shape3D).get_rid()


## Меш + статическое тело с метаданными поверхности для физики машины.
## Узлы без owner — в сцену не сохраняются, строятся заново при загрузке.
static func build_static(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		indices: PackedInt32Array, faces: PackedVector3Array, mat: Material, surface: int) -> Array[Node]:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	a[Mesh.ARRAY_NORMAL] = normals
	a[Mesh.ARRAY_TEX_UV] = uvs
	a[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var body := StaticBody3D.new()
	body.collision_layer = WorldDefs.LAYER_WORLD
	body.collision_mask = 0
	body.set_meta("surface", surface)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	return [mi, body]
