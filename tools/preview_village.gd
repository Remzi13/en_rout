extends SceneTree
## Снимок построек деревни для проверки глазами (нужен экран, не --headless):
##   godot --path . -s res://tools/preview_village.gd -- [файл.png] [угол°] [дистанция_м] [x z точки взгляда]
## Модели из game/world/models/village/ стоят в ряд фасадом к камере (фасад — −Z), у каждой
## постройки — машина игрока в игровом масштабе (CarStats.SCALE). Справа от ряда
## берег и вода на высоте −0,6 м: причал и лодка стоят как у озера.

var _frames := 0
var _out := "res://tools/blender/previews/village.png"
var _angle := 10.0
var _dist := 35.0
var _target := Vector3(-3.0, 0.5, 1.0)

const DIR := "res://game/world/models/village/"
## Имя модели, ширина места в ряду, м.
const ROW := [
	["house_a", 6.0], ["house_b", 5.4], ["smokehouse", 4.0], ["net_shed", 5.8],
	["shop", 5.6], ["net_rack", 4.0],
]
const SHORE_X := 17.5
const WATER_Y := -0.6


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_out = args[0]
	if args.size() >= 2:
		_angle = float(args[1])
	if args.size() >= 3:
		_dist = float(args[2])
	if args.size() >= 5:
		_target = Vector3(float(args[3]), 0.5, float(args[4]))
	root.size = Vector2i(1600, 900)
	# Камера смотрит в +Z, поэтому на экране −X справа: ряд идёт слева направо в −X.
	_add_plane(Vector3(-SHORE_X + 100.0, 0.0, 0.0), Vector2(200, 200), Color(0.45, 0.56, 0.24))
	_add_plane(Vector3(-SHORE_X - 100.0, WATER_Y, 0.0), Vector2(200, 200), Color(0.16, 0.32, 0.45))
	_add_plane(Vector3(-SHORE_X - 100.0, -4.2, 0.0), Vector2(200, 200), Color(0.40, 0.33, 0.24))
	_add_env()
	var x := 16.0
	for item in ROW:
		var w: float = item[1]
		var node := _model(item[0])
		node.position = Vector3(x - w * 0.5, 0.0, 0.0)
		root.add_child(node)
		_car(Vector3(x - w * 0.5 - 1.2, 0.0, -4.6), 90.0)
		x -= w
	# причал: начало на берегу, уходит в воду наискось от камеры
	var p := _model("pier")
	p.position = Vector3(-SHORE_X + 0.4, 0.0, -3.0)
	p.rotation_degrees.y = -45.0
	root.add_child(p)
	var b := _model("boat")
	b.position = Vector3(-SHORE_X - 7.3, WATER_Y, 1.1)
	b.rotation_degrees.y = -45.0
	root.add_child(b)
	_car(Vector3(-SHORE_X - 2.0, 0.3, -1.6), 135.0)
	var cam := Camera3D.new()
	cam.fov = 40.0
	root.add_child(cam)
	var a := deg_to_rad(_angle)
	var target := _target
	cam.look_at_from_position(target + Vector3(sin(a) * _dist, _dist * 0.28, -cos(a) * _dist), target)
	cam.current = true


func _model(name: String) -> Node3D:
	var scene: PackedScene = load(DIR + name + ".glb")
	return scene.instantiate() as Node3D


func _car(pos: Vector3, yaw_deg: float) -> void:
	var s := CarStats.SCALE
	var car := CarModel.new()
	car.style = CarModel.Style.SPORT
	car.body_color = Color(0.95, 0.42, 0.06)
	car.size = Vector3(1.9, 1.3, 4.3) * s
	car.unit = s
	car.position = pos + Vector3(0.0, car.size.y * 0.5, 0.0)
	car.rotation_degrees.y = yaw_deg
	root.add_child(car)


func _add_plane(pos: Vector3, size: Vector2, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = size
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.95
	mi.material_override = mat
	mi.position = pos
	root.add_child(mi)


func _add_env() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, 30.0, 0.0)
	sun.shadow_enabled = true
	sun.light_color = Color(1.0, 0.96, 0.9)
	root.add_child(sun)
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 20:
		var img := root.get_texture().get_image()
		img.save_png(_out)
		print("PREVIEW saved ", _out)
		return true
	return false
