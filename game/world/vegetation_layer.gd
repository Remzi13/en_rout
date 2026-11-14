@tool
class_name VegetationLayer
extends MultiMeshInstance3D
## Слой растительности чанка (деревья, камни, кусты) в одном MultiMesh.
## Коллизия строится в игре по трансформам экземпляров: один статический
## body на сервере физики, цилиндр на экземпляр. Поэтому после правки
## MultiMesh в редакторе коллизия совпадёт с тем, что видно.
##
## Деревья: если задан набор (tree_set или tree_preset), собственный MultiMesh
## слоя хранит только расстановку (трансформы и оттенки, без меша) и сам
## ничего не рисует. Слой раскладывает экземпляры по моделям набора (glTF из
## Blender, см. TreeLibrary) и создаёт на каждую модель дочерний MultiMesh —
## ближний и, если есть упрощённая модель, дальний (переключаются по расстоянию
## до чанка). Вариации каждого дерева — высота, ширина, оттенок — считаются из
## зерна и кладутся в трансформ и цвет экземпляра, новых мешей не требуют.
## Дочерние узлы внутренние и без owner — в сцену не сохраняются.

enum TreePreset {
	NONE, ## обычный слой: рисуется меш самого MultiMesh
	CONIFER_FOREST, ## TreeSet.conifer_forest()
	LEAFY_FOREST, ## TreeSet.leafy_forest()
}

## Запас радиуса коллизии дерева относительно радиуса ствола.
const TRUNK_COLLIDER_MARGIN := 1.15
## Гистерезис переключения ближней и дальней модели, м.
const LOD_MARGIN_M := 15.0

## Радиус и высота цилиндра при масштабе экземпляра 1. Радиус 0 — без коллизии.
## Для деревьев с набором радиус берётся из толщины ствола модели.
@export var collider_radius: float = 0.0
@export var collider_height: float = 6.0
## Экземпляры меньше этого масштаба коллизии не получают (мелкие камни).
@export var collider_min_scale: float = 0.0

@export_group("Деревья")
## Готовый набор деревьев из кода.
@export var tree_preset: TreePreset = TreePreset.NONE:
	set(v):
		tree_preset = v
		_rebuild_in_editor()
## Свой набор деревьев; если задан — важнее пресета.
@export var tree_set: TreeSet:
	set(v):
		tree_set = v
		_rebuild_in_editor()
## Добавка к зерну набора: разные слои с одним набором выглядят по-разному.
@export var variant_seed: int = 0:
	set(v):
		variant_seed = v
		_rebuild_in_editor()
## Дальше этого расстояния до центра слоя рисуются упрощённые модели. 0 — всегда основные.
@export var lod_distance: float = 270.0:
	set(v):
		lod_distance = v
		_rebuild_in_editor()
## Пересобрать деревья после правки MultiMesh или набора в редакторе.
@export_tool_button("Перестроить деревья", "Reload") var rebuild_action = rebuild_trees

var _body: RID
var _tree_nodes: Array[MultiMeshInstance3D] = []
var _trunk_radius: PackedFloat32Array = PackedFloat32Array() ## радиус ствола каждого экземпляра, м


func _ready() -> void:
	# В headless (тесты) MultiMesh не хранит трансформы — все деревья и формы встали бы в угол чанка.
	if DisplayServer.get_name() == "headless":
		return
	rebuild_trees()
	if Engine.is_editor_hint():
		return
	_build_colliders()


## Набор деревьев слоя: свой tree_set или пресет; null — слой без деревьев.
func active_tree_set() -> TreeSet:
	if tree_set != null:
		return tree_set
	match tree_preset:
		TreePreset.CONIFER_FOREST:
			return TreeSet.conifer_forest()
		TreePreset.LEAFY_FOREST:
			return TreeSet.leafy_forest()
	return null


## Заново разложить экземпляры по моделям и создать дочерние MultiMesh.
## Вызывать после изменения расстановки, набора или его параметров из кода.
func rebuild_trees() -> void:
	for n in _tree_nodes:
		if is_instance_valid(n):
			remove_child(n)
			n.queue_free()
	_tree_nodes.clear()
	_trunk_radius = PackedFloat32Array()
	var ts := active_tree_set()
	if ts == null or multimesh == null or multimesh.instance_count == 0:
		return
	if DisplayServer.get_name() == "headless":
		return
	var models: Array[TreeModel] = []
	var total := 0.0
	for tm in ts.models:
		if tm != null and tm.weight > 0.0:
			models.append(tm)
			total += tm.weight
	if models.is_empty():
		return

	# Для каждого экземпляра: модель по весам, пропорции и оттенок — всё из хеша
	# зерна, номера и позиции, поэтому результат одинаков при каждой загрузке.
	var count := multimesh.instance_count
	var colors := multimesh.use_colors
	var rng := RandomNumberGenerator.new()
	var xforms: Array[Array] = [] ## по моделям: Array[Transform3D]
	var tints: Array[Array] = [] ## по моделям: Array[Color]
	for k in models.size():
		xforms.append([])
		tints.append([])
	_trunk_radius.resize(count)
	for i in count:
		var xf := multimesh.get_instance_transform(i)
		rng.seed = hash([ts.variation_seed, variant_seed, i, roundi(xf.origin.x * 10.0), roundi(xf.origin.z * 10.0)])
		var r := rng.randf() * total
		var mi := models.size() - 1
		var acc := 0.0
		for k in models.size():
			acc += models[k].weight
			if r < acc:
				mi = k
				break
		var tm := models[mi]
		# Высота и ширина связаны: высокое дерево шире и толще молодого, иначе
		# крупные деревья выходят тощими, а мелкие — пухлыми.
		var t := rng.randf()
		var tw := clampf(t * 0.7 + rng.randf() * 0.3, 0.0, 1.0)
		var width := lerpf(tm.width_scale.x, tm.width_scale.y, tw) * ts.size_scale
		var height := lerpf(tm.height_scale.x, tm.height_scale.y, t) * ts.size_scale
		_trunk_radius[i] = tm.trunk_radius_m * width * xf.basis.get_scale().x
		# Масштаб в локальных осях дерева: поворот экземпляра сохраняется.
		xf.basis = xf.basis * Basis.from_scale(Vector3(width, height, width))
		xforms[mi].append(xf)
		var value := 1.0 + rng.randf_range(-tm.value_jitter, tm.value_jitter)
		var hue := rng.randf_range(-tm.hue_jitter, tm.hue_jitter)
		# Сдвиг оттенка: в плюс — желтее, в минус — холоднее.
		var tint := Color(value * (1.0 + hue * 6.0), value, value * (1.0 - hue * 4.0))
		if colors:
			var base := multimesh.get_instance_color(i)
			tint = Color(tint.r * base.r, tint.g * base.g, tint.b * base.b)
		tints[mi].append(tint)

	for mi in models.size():
		if xforms[mi].is_empty():
			continue
		var tm := models[mi]
		var leaf := Color(tm.leaf_tint.r * ts.leaf_tint.r, tm.leaf_tint.g * ts.leaf_tint.g, tm.leaf_tint.b * ts.leaf_tint.b)
		var near_mesh := TreeLibrary.mesh_for(tm.model_path, leaf)
		var far_mesh: Mesh = null
		if lod_distance > 0.0:
			far_mesh = TreeLibrary.mesh_for(tm.lod_path, leaf)
		if near_mesh == null:
			near_mesh = far_mesh
			far_mesh = null
		if near_mesh == null:
			continue
		var near_end := visibility_range_end
		if far_mesh != null:
			near_end = lod_distance
			if visibility_range_end > 0.0:
				near_end = minf(lod_distance, visibility_range_end)
		_add_tree_node("Tree%d" % mi, near_mesh, xforms[mi], tints[mi], visibility_range_begin, near_end,
			far_mesh != null)
		if far_mesh != null and (visibility_range_end <= 0.0 or visibility_range_end > lod_distance):
			_add_tree_node("Tree%dFar" % mi, far_mesh, xforms[mi], tints[mi], lod_distance, visibility_range_end, false)


## Дочерний MultiMesh одной модели. lod_split — это ближняя половина пары «ближний/дальний».
func _add_tree_node(node_name: String, mesh: Mesh, xforms: Array, tints: Array,
		range_begin: float, range_end: float, lod_split: bool) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for k in xforms.size():
		mm.set_instance_transform(k, xforms[k] as Transform3D)
		mm.set_instance_color(k, tints[k] as Color)
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	node.visibility_range_begin = range_begin
	node.visibility_range_end = range_end
	# На стыке ближней и дальней модели — свой гистерезис, на краях — как у слоя.
	var is_far := range_begin > visibility_range_begin
	node.visibility_range_begin_margin = LOD_MARGIN_M if is_far else visibility_range_begin_margin
	node.visibility_range_end_margin = LOD_MARGIN_M if lod_split else visibility_range_end_margin
	node.cast_shadow = cast_shadow
	node.layers = layers
	add_child(node, false, Node.INTERNAL_MODE_BACK)
	_tree_nodes.append(node)


func _rebuild_in_editor() -> void:
	if Engine.is_editor_hint() and is_node_ready():
		rebuild_trees()


func _build_colliders() -> void:
	if multimesh == null:
		return
	var trees := _trunk_radius.size() == multimesh.instance_count and multimesh.instance_count > 0
	if not trees and collider_radius <= 0.0:
		return
	_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(_body, WorldDefs.LAYER_WORLD)
	PhysicsServer3D.body_set_collision_mask(_body, 0)
	var mats := WorldMaterials.shared()
	for i in multimesh.instance_count:
		var xf := multimesh.get_instance_transform(i)
		var s := xf.basis.get_scale().x
		if s < collider_min_scale:
			continue
		var radius := collider_radius * s
		if trees:
			radius = _trunk_radius[i] * TRUNK_COLLIDER_MARGIN
		var h := collider_height * s
		var shape := mats.cylinder_shape(radius, h)
		PhysicsServer3D.body_add_shape(_body, shape, Transform3D(Basis(), xf.origin + Vector3(0, h * 0.5, 0)))
	PhysicsServer3D.body_set_state(_body, PhysicsServer3D.BODY_STATE_TRANSFORM, global_transform)
	PhysicsServer3D.body_set_space(_body, get_world_3d().space)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _body.is_valid():
		PhysicsServer3D.free_rid(_body)
