extends RefCounted
## Объекты карты: пустышки коллекции Props из art/map/map.blend -> узлы в
## Props чанков. Соглашение о свойствах пустышек — docs/map-pipeline.md.
## Используется запеканием (tools/bake_world.gd) и тестом test_map_props.
##
## Запись в map.json (её пишет tools/blender/export_map.py, оси уже Godot):
##   {name, model: "res://...glb", pos: [x, y, z], yaw: рад, scale: [x, y, z],
##    snap_to_ground: bool, collision: "box" | "none"}
## Узел объекта: StaticBody3D (collision = box; коробка по AABB модели, слой
## мира) или Node3D (collision = none), внутри — экземпляр модели «Model».

const LAYER_WORLD := WorldDefs.LAYER_WORLD


## Проверяет записи из map.json. Плохие и с неизвестной моделью —
## предупреждение и пропуск. Результат: [{name, scene: PackedScene,
## transform (глобальный; высота — пустышки), snap: bool, collision: String}].
static func parse(list: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item: Variant in list:
		if not item is Dictionary:
			push_warning("Props: запись не словарь — пропускаю")
			continue
		var d: Dictionary = item
		var pname := str(d.get("name", "?"))
		var model := str(d.get("model", ""))
		if model == "" or not ResourceLoader.exists(model):
			push_warning("Props/%s: модель «%s» не найдена — пропускаю" % [pname, model])
			continue
		var scene := load(model) as PackedScene
		if scene == null:
			push_warning("Props/%s: «%s» — не сцена (.glb/.tscn) — пропускаю" % [pname, model])
			continue
		var p: Variant = d.get("pos")
		if not p is Array or (p as Array).size() != 3:
			push_warning("Props/%s: нет позиции — пропускаю" % pname)
			continue
		var s: Variant = d.get("scale", [1.0, 1.0, 1.0])
		var scale := Vector3.ONE
		if s is Array and (s as Array).size() == 3:
			scale = Vector3(float(s[0]), float(s[1]), float(s[2]))
		var basis := Basis(Vector3.UP, float(d.get("yaw", 0.0))) * Basis.from_scale(scale)
		var collision := str(d.get("collision", "box"))
		if collision != "none":
			collision = "box"
		out.append({
			"name": pname.validate_node_name(),
			"scene": scene,
			"transform": Transform3D(basis, Vector3(float(p[0]), float(p[1]), float(p[2]))),
			"snap": bool(d.get("snap_to_ground", false)),
			"collision": collision,
		})
	return out


## Узел объекта в координатах чанка с углом origin. ground(x, z) -> высота
## рельефа (для snap: низ модели ставится на самую низкую точку рельефа под
## её основанием — на склоне дом чуть врезается, но не висит).
static func build(prop: Dictionary, origin: Vector3, ground: Callable) -> Node3D:
	var model: Node3D = (prop["scene"] as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	model.name = "Model"
	var box := model_aabb(model)
	var xf: Transform3D = prop["transform"]
	if prop["snap"]:
		var low := INF
		var lo := box.position
		var hi := box.end
		var c := box.get_center()
		for q: Vector2 in [Vector2(lo.x, lo.z), Vector2(hi.x, lo.z), Vector2(lo.x, hi.z), Vector2(hi.x, hi.z), Vector2(c.x, c.z)]:
			var w := xf * Vector3(q.x, 0.0, q.y) # углы основания и центр
			low = minf(low, float(ground.call(w.x, w.z)))
		xf.origin.y = low - (xf.basis * Vector3(0.0, box.position.y, 0.0)).y
	var node: Node3D
	if prop["collision"] == "box" and box.size.length() > 0.01:
		var body := StaticBody3D.new()
		body.collision_layer = LAYER_WORLD
		body.collision_mask = 0
		var shape := BoxShape3D.new()
		shape.size = box.size
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		cs.shape = shape
		cs.position = box.get_center()
		body.add_child(cs)
		node = body
	else:
		node = Node3D.new()
	node.name = prop["name"]
	node.transform = Transform3D(xf.basis, xf.origin - origin)
	node.add_child(model)
	return node


## AABB всех мешей модели в координатах её родителя (узел может быть вне дерева).
static func model_aabb(root: Node3D) -> AABB:
	var acc := [AABB(), false]
	_collect_aabb(root, root.transform, acc)
	return acc[0]


static func _collect_aabb(node: Node, xf: Transform3D, acc: Array) -> void:
	if node is VisualInstance3D:
		var b := xf * (node as VisualInstance3D).get_aabb()
		acc[0] = b if not acc[1] else (acc[0] as AABB).merge(b)
		acc[1] = true
	for c in node.get_children():
		var cx := xf * (c as Node3D).transform if c is Node3D else xf
		_collect_aabb(c, cx, acc)
