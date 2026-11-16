@tool
extends MeshInstance3D
## Оси дорог поверх базового рельефа в сцене правки (terrain_edit.tscn):
## линии по точкам из world_index.tres, то есть по прошлому запеканию.
## Шоссе — светлые, грунтовки — рыжие. Только ориентир: в игру не попадает.

const LIFT_M := 0.6


func _ready() -> void:
	var index := WorldIndex.load_baked()
	if index == null:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	var im := ImmediateMesh.new()
	for r in index.road_points.size():
		var highway := index.road_types[r] == WorldDefs.RoadType.HIGHWAY
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
		im.surface_set_color(Color(0.95, 0.95, 0.9) if highway else Color(0.9, 0.55, 0.2))
		for p in index.road_points[r]:
			im.surface_add_vertex(p + Vector3.UP * LIFT_M)
		im.surface_end()
	mesh = im
