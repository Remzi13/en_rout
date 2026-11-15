extends SceneTree
## Объекты карты (коллекция Props из Blender -> узел Props чанков,
## tools/map_props.gd): разбор записей map.json на синтетических данных,
## узлы объектов (поворот, масштаб, высота по рельефу, коллизия-коробка),
## подгрузка и выгрузка чанка с объектами через ChunkStreamer, узел Props
## во всех запечённых чанках.

const H := preload("res://tests/headless/helper.gd")
const MapProps := preload("res://tools/map_props.gd")
const VAN := "res://game/cars/models/car_van.glb"


func _initialize() -> void:
	_run()


func _run() -> void:
	# --- Разбор: плохие записи пропускаются, хорошие — с осями Godot.
	var src: Array = JSON.parse_string("""[
		{"name": "Дом.001", "model": "%s", "pos": [300.5, 12.0, -40.0], "yaw": 1.5707963,
		 "scale": [2.0, 1.0, 1.0], "snap_to_ground": false, "collision": "box"},
		{"name": "Нет модели", "model": "res://нет/такой.glb", "pos": [0, 0, 0]},
		{"name": "Пусто", "pos": [0, 0, 0]},
		{"name": "Без позиции", "model": "%s"},
		"мусор",
		{"name": "Камень", "model": "%s", "pos": [10, 0, 20], "snap_to_ground": true, "collision": "none"},
		{"name": "Странная", "model": "%s", "pos": [1, 2, 3], "collision": "mesh"}
	]""" % [VAN, VAN, VAN, VAN])
	var props := MapProps.parse(src)
	H.check("разбор: неизвестные и битые записи пропущены", props.size() == 3, "%d из 7" % props.size())
	if props.size() != 3:
		H.finish(self)
		return
	var house: Dictionary = props[0]
	var xf: Transform3D = house["transform"]
	H.check("имя узла очищено от недопустимых символов", house["name"] == "Дом_001", house["name"])
	H.check("позиция из записи", xf.origin.is_equal_approx(Vector3(300.5, 12.0, -40.0)), "%s" % xf.origin)
	# yaw 90° вокруг Y: локальная X смотрит в -Z мира; масштаб — отдельно.
	H.check("поворот вокруг вертикали без масштаба",
		xf.basis.x.is_equal_approx(Vector3(0, 0, -1)) and xf.basis.z.is_equal_approx(Vector3(1, 0, 0)),
		"x %s, z %s" % [xf.basis.x, xf.basis.z])
	H.check("масштаб по осям модели", (house["scale"] as Vector3).is_equal_approx(Vector3(2, 1, 1)),
		"%s" % house["scale"])
	H.check("collision по умолчанию и неизвестное значение — box",
		props[0]["collision"] == "box" and props[2]["collision"] == "box" and props[1]["collision"] == "none")
	H.check("snap_to_ground читается", props[1]["snap"] == true and props[0]["snap"] == false)

	# --- Узел объекта в координатах чанка.
	var origin := Vector3(256, 0, -256)
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var node := MapProps.build(house, origin, flat)
	var model := node.get_node("Model") as Node3D
	var box := MapProps.model_aabb(model)
	# AABB той же модели без масштаба: коробка должна быть шире ровно по X.
	var plain := (load(VAN) as PackedScene).instantiate() as Node3D
	var raw := MapProps.model_aabb(plain)
	plain.free()
	H.check("масштаб на модели, у тела — 1", model.scale.is_equal_approx(Vector3(2, 1, 1))
		and node.basis.get_scale().is_equal_approx(Vector3.ONE), "модель %s, тело %s" % [model.scale, node.basis.get_scale()])
	H.check("коробка учитывает неравный масштаб [2,1,1]",
		box.size.is_equal_approx(raw.size * Vector3(2, 1, 1))
		and box.get_center().is_equal_approx(raw.get_center() * Vector3(2, 1, 1)),
		"коробка %s, модель %s" % [box.size, raw.size])
	H.check("узел в координатах чанка", node.position.is_equal_approx(Vector3(44.5, 12.0, 216.0)), "%s" % node.position)
	var body := node as StaticBody3D
	var shape_ok := false
	if body != null:
		var cs := body.get_node("Shape") as CollisionShape3D
		var bs := cs.shape as BoxShape3D
		shape_ok = body.collision_layer == WorldDefs.LAYER_WORLD and bs != null \
			and bs.size.is_equal_approx(box.size) and cs.position.is_equal_approx(box.get_center())
	H.check("collision=box: StaticBody3D с коробкой по AABB модели", shape_ok, "AABB %s" % box)
	H.check("модель фургона не пустая", box.size.x > 1.5 and box.size.z > 3.0, "%s" % box.size)

	# snap_to_ground: низ модели — на самой низкой точке рельефа под основанием.
	var slope := func(x: float, _z: float) -> float: return 5.0 + x * 0.1
	var rock := MapProps.build(props[1], Vector3.ZERO, slope)
	var rbox := MapProps.model_aabb(rock.get_node("Model") as Node3D)
	var bottom := rock.position.y + rbox.position.y
	var want := 5.0 + (10.0 + rbox.position.x) * 0.1
	H.check("snap_to_ground: низ модели на нижней точке рельефа", absf(bottom - want) < 0.01,
		"низ %.2f, ждём %.2f" % [bottom, want])
	H.check("collision=none: без тела и формы", not rock is CollisionObject3D
		and rock.find_children("*", "CollisionShape3D", true, false).is_empty())
	rock.free()

	# Машина не проезжает сквозь объект: луч по слою мира упирается в коробку.
	var world := Node3D.new()
	root.add_child(world)
	node.position = Vector3(0, 0, 0)
	world.add_child(node)
	await physics_frame
	await physics_frame
	var q := PhysicsRayQueryParameters3D.create(Vector3(0, box.get_center().y, 20), Vector3(0, box.get_center().y, -20),
		WorldDefs.LAYER_WORLD)
	var hit := world.get_world_3d().direct_space_state.intersect_ray(q)
	H.check("коробка объекта на слое мира ловит луч", not hit.is_empty() and hit["collider"] == node)
	world.free()

	# --- ChunkStreamer: чанк с объектами грузится и выгружается целиком.
	var chunk := WorldChunk.new()
	chunk.name = "Chunk"
	var holder := Node3D.new()
	holder.name = "Props"
	chunk.add_child(holder)
	holder.add_child(MapProps.build(props[0], Vector3(256, 0, -256), flat))
	_own(chunk, chunk)
	var ps := PackedScene.new()
	ps.pack(chunk)
	chunk.free()
	var idx := WorldIndex.new()
	idx.chunk_coords.assign([Vector2i(1, -1)])
	var streamer := ChunkStreamer.create(idx)
	root.add_child(streamer)
	streamer._add(Vector2i(1, -1), ps)
	var loaded := streamer.chunks()
	var prop: Node = null
	if loaded.size() == 1:
		prop = loaded[0].get_node_or_null("Props/Дом_001")
	H.check("стример: объект на месте после загрузки чанка",
		prop != null and (prop as Node3D).global_position.is_equal_approx(Vector3(300.5, 12.0, -40.0)) \
		and prop.get_node_or_null("Model") != null,
		"%s" % ((prop as Node3D).global_position if prop != null else "нет узла"))
	streamer._unload(Vector2i(1, -1))
	await process_frame
	H.check("стример: при выгрузке чанка объект удаляется", not is_instance_valid(prop) and streamer.chunks().is_empty())
	streamer.free()

	# --- Запечённые чанки: у каждого есть узел Props, у объектов — модель.
	var base := WorldIndex.load_baked()
	var with_props := 0
	var ok := true
	var count := 0
	for cc in base.chunk_coords:
		var inst := (load(WorldDefs.chunk_scene_path(cc)) as PackedScene).instantiate()
		var p := inst.get_node_or_null("Props")
		ok = ok and p != null
		if p != null:
			for c in p.get_children():
				ok = ok and c.get_node_or_null("Model") != null
				count += 1
			with_props += 1 if p.get_child_count() > 0 else 0
		inst.free()
	H.info("объектов в запечённых чанках: %d (в %d чанках)" % [count, with_props])
	H.check("запечённые чанки: узел Props есть, у объектов есть модель", ok)
	H.finish(self)


func _own(node: Node, owner_node: Node) -> void:
	for c in node.get_children():
		c.owner = owner_node
		if c.scene_file_path.is_empty():
			_own(c, owner_node)
