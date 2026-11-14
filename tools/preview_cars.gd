extends SceneTree
## Снимок всех стилей машин для проверки глазами (нужен экран, не --headless):
##   godot --path . -s res://tools/preview_cars.gd -- [файл.png] [угол°]
## Ставит машины в ряд на землю в игровом масштабе (CarStats.SCALE).

var _frames := 0
var _out := "res://tools/blender/previews/cars.png"
var _angle := 35.0

const CARS := [
	[CarModel.Style.SPORT, Color(0.95, 0.42, 0.06), Vector3(1.9, 1.3, 4.3)],
	[CarModel.Style.RACER, Color(0.1, 0.9, 0.4), Vector3(1.9, 1.3, 4.3)],
	[CarModel.Style.SEDAN, Color(0.15, 0.25, 0.5), Vector3(1.9, 1.5, 4.5)],
	[CarModel.Style.VAN, Color(0.85, 0.85, 0.86), Vector3(2.0, 2.0, 4.8)],
]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_out = args[0]
	if args.size() >= 2:
		_angle = float(args[1])
	root.size = Vector2i(1600, 900)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.45, 0.56, 0.24)
	gm.roughness = 0.95
	ground.material_override = gm
	root.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, 120.0, 0.0)
	sun.shadow_enabled = true
	sun.light_color = Color(1.0, 0.96, 0.9)
	root.add_child(sun)
	var sky_mat := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var s := CarStats.SCALE
	for i in CARS.size():
		var c: Array = CARS[i]
		var car := CarModel.new()
		car.style = c[0]
		car.body_color = c[1]
		car.size = (c[2] as Vector3) * s
		car.unit = s
		car.position = Vector3((i - 1.5) * 2.2, car.size.y * 0.5, 0.0)
		root.add_child(car)
	var cam := Camera3D.new()
	cam.fov = 40.0
	root.add_child(cam)
	var a := deg_to_rad(_angle)
	cam.look_at_from_position(Vector3(sin(a) * 9.0, 2.6, -cos(a) * 9.0), Vector3(0, 0.4, 0))
	cam.current = true


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 20:
		var img := root.get_texture().get_image()
		img.save_png(_out)
		print("PREVIEW saved ", _out)
		return true
	return false
