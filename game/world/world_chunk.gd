class_name WorldChunk
extends Node3D
## Узел одного чанка мира. Собирается на основном потоке из данных,
## посчитанных WorldGen.build_chunk_data() в рабочем потоке.
## Поверхность для физики машины — метаданные "surface" у StaticBody3D.

const LAYER_WORLD := 1

var coord: Vector2i
var _veg_body: RID


func build(data: Dictionary, mats: WorldMaterials) -> void:
	coord = data["coord"]
	position = data["origin"]
	name = "Chunk_%d_%d" % [coord.x, coord.y]

	var t: Dictionary = data["terrain"]
	_add_mesh_and_body("Terrain", t, mats.terrain, WorldGen.Surface.GRASS, true)

	var roads: Dictionary = data["roads"]
	var hw: Dictionary = roads[WorldGen.RoadType.HIGHWAY]
	if not (hw["indices"] as PackedInt32Array).is_empty():
		_add_mesh_and_body("Highway", hw, mats.highway, WorldGen.Surface.ASPHALT, false)
	var dr: Dictionary = roads[WorldGen.RoadType.DIRT]
	if not (dr["indices"] as PackedInt32Array).is_empty():
		_add_mesh_and_body("DirtRoad", dr, mats.dirt_road, WorldGen.Surface.DIRT, false)

	for pad in data["pads"]:
		_add_pad(pad["pos"], pad["highway"], mats)

	if data["water"]:
		var water := MeshInstance3D.new()
		water.name = "Water"
		water.mesh = mats.water_mesh
		water.position.y = WorldGen.WATER_LEVEL
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(water)

	var veg: Dictionary = data["vegetation"]
	_add_multimesh("Conifers", mats.conifer_mesh, veg["conifer"], 520.0, true)
	_add_multimesh("Trees", mats.leafy_mesh, veg["leafy"], 520.0, true)
	_add_multimesh("Rocks", mats.rock_mesh, veg["rocks"], 380.0, true)
	_add_multimesh("Bushes", mats.bush_mesh, veg["bushes"], 220.0, false)
	_build_vegetation_collision(veg["colliders"], mats)


func _add_mesh_and_body(node_name: String, arrays: Dictionary, mat: Material, surface: int, has_colors: bool) -> void:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = arrays["vertices"]
	a[Mesh.ARRAY_NORMAL] = arrays["normals"]
	a[Mesh.ARRAY_INDEX] = arrays["indices"]
	if has_colors:
		a[Mesh.ARRAY_COLOR] = arrays["colors"]
	if arrays.has("uvs"):
		a[Mesh.ARRAY_TEX_UV] = arrays["uvs"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	add_child(mi)

	var body := StaticBody3D.new()
	body.name = node_name + "Body"
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	body.set_meta("surface", surface)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(arrays["faces"])
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


func _add_pad(pos: Vector3, highway: bool, mats: WorldMaterials) -> void:
	const SEGMENTS := 24
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	var r := WorldGen.PAD_RADIUS_M + 1.0
	verts.append(pos)
	uvs.append(Vector2.ZERO)
	normals.append(Vector3.UP)
	for k in SEGMENTS:
		var ang := TAU * k / SEGMENTS
		var p := pos + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		verts.append(p)
		uvs.append(Vector2(p.x, p.z) * 0.1)
		normals.append(Vector3.UP)
	for k in SEGMENTS:
		var a := 1 + k
		var b := 1 + (k + 1) % SEGMENTS
		indices.append_array([0, a, b])
		faces.append_array([verts[0], verts[a], verts[b]])
	var mat := mats.asphalt_plain if highway else mats.dirt_road
	var surf := WorldGen.Surface.ASPHALT if highway else WorldGen.Surface.DIRT
	_add_mesh_and_body("Pad", {"vertices": verts, "normals": normals, "uvs": uvs, "indices": indices, "faces": faces}, mat, surf, false)


func _add_multimesh(node_name: String, mesh: Mesh, xforms: Array, range_end: float, shadows: bool) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(coord) + node_name.hash()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		var v := rng.randf_range(0.8, 1.15)
		mm.set_instance_color(i, Color(v * rng.randf_range(0.92, 1.08), v, v * rng.randf_range(0.85, 1.0)))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.visibility_range_end = range_end
	mmi.visibility_range_end_margin = 20.0
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


## Одно статическое тело на сервере физики с формами всех стволов и камней:
## дешевле сотен узлов CollisionShape3D.
func _build_vegetation_collision(colliders: Array, mats: WorldMaterials) -> void:
	if colliders.is_empty():
		return
	_veg_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_veg_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(_veg_body, LAYER_WORLD)
	PhysicsServer3D.body_set_collision_mask(_veg_body, 0)
	for c in colliders:
		var pos: Vector3 = c[0]
		var radius: float = c[1]
		var height: float = c[2]
		var shape := mats.cylinder_shape(radius, height)
		PhysicsServer3D.body_add_shape(_veg_body, shape, Transform3D(Basis(), pos + Vector3(0, height * 0.5, 0)))
	PhysicsServer3D.body_set_state(_veg_body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), position))


func _enter_tree() -> void:
	if _veg_body.is_valid():
		PhysicsServer3D.body_set_space(_veg_body, get_world_3d().space)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _veg_body.is_valid():
		PhysicsServer3D.free_rid(_veg_body)
