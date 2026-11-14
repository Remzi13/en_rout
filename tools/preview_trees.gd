extends SceneTree
## Снимок деревьев в игре для проверки глазами (нужен экран, не --headless):
##   godot --path . -s res://tools/preview_trees.gd -- [x z] [файл.png]
## Загружает чанк, ставит камеру у первого дерева слоя и сохраняет кадр.

var _frames := 0
var _out := "res://tools/blender/previews/godot_chunk.png"
var _cc := Vector2i(0, 0)
var _cam: Camera3D
var _chunk: Node3D


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2:
		_cc = Vector2i(int(args[0]), int(args[1]))
	if args.size() >= 3:
		_out = args[2]
	root.size = Vector2i(1600, 900)
	var chunk := (load(WorldDefs.chunk_scene_path(_cc)) as PackedScene).instantiate() as Node3D
	root.add_child(chunk)
	_chunk = chunk
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 100.0, 0.0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.72, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.78, 0.9)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	# Камера смотрит на середину слоя лиственных деревьев с небольшой высоты.
	var layer := chunk.get_node("Vegetation/Trees") as MultiMeshInstance3D
	var count := layer.multimesh.instance_count
	var center := Vector3.ZERO
	for i in count:
		center += layer.multimesh.get_instance_transform(i).origin
	center /= maxf(float(count), 1.0)
	var best := layer.multimesh.get_instance_transform(0).origin
	for i in count:
		var o := layer.multimesh.get_instance_transform(i).origin
		if o.distance_to(center) < best.distance_to(center):
			best = o
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.far = 1200.0
	root.add_child(_cam)
	_cam.look_at_from_position(best + Vector3(22.0, 5.0, 22.0), best + Vector3(0.0, 4.0, 0.0))
	_cam.current = true
	print("PREVIEW chunk=", _cc, " trees=", count, " cam=", _cam.position)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 20:
		for layer_name in ["Conifers", "Trees"]:
			var l := _chunk.get_node_or_null("Vegetation/" + layer_name)
			if l != null:
				print("PREVIEW ", layer_name, " child_multimeshes=", l.get_child_count(true))
		root.get_texture().get_image().save_png(_out)
		print("PREVIEW saved ", _out)
		return true
	return false
