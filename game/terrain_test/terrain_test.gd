extends Node3D
## Проба Terrain3D: рельеф карты в Terrain3D (собирает tools/make_terrain_test.gd)
## и машина игрока, чтобы покататься и сравнить с нынешним миром из чанков.
## Дорог, леса, трафика здесь нет — только рельеф, вода и машина.
##   godot --path . res://game/terrain_test/terrain_test.tscn
## Отладка (после «--»): --drive — газ зажат сам, --at=x,z,угол — старт в
## другой точке, --shot=файл.png — снимок через 6 с и выход.

const PLAYER_STATS := preload("res://game/cars/stats/player.tres")
const START := Vector3(-220.0, 0.0, 85.0) ## PlayerStart из art/map/map.blend

var car: ArcadeCar
var camera: FollowCamera
var _fps: Label
var _frame_ms: float = 0.0
var _shot_path: String = ""
var _time: float = 0.0


func _ready() -> void:
	var terrain: Terrain3D = $Terrain3D
	_build_environment()
	_build_water()

	car = ArcadeCar.new()
	car.name = "Player"
	car.stats = PLAYER_STATS
	car.body_color = Color(0.95, 0.42, 0.06)
	car.driver = HumanDriver.new()
	car.respawn_requested.connect(func(_c: ArcadeCar) -> void: _respawn())
	add_child(car)

	camera = FollowCamera.new()
	camera.target = car
	camera.far = 1200.0
	add_child(camera)
	camera.current = true
	terrain.set_camera(camera)
	_respawn(START, Vector3.RIGHT)

	if OpenWorld.is_software_renderer():
		get_viewport().scaling_3d_scale = 0.5
	_build_hud()

	var args := OS.get_cmdline_user_args()
	if "--drive" in args:
		Input.action_press("accelerate")
	for a in args:
		if a.begins_with("--shot="):
			_shot_path = a.trim_prefix("--shot=")
		elif a.begins_with("--at="): # --at=x,z,угол — старт в другой точке карты
			var v := a.trim_prefix("--at=").split_floats(",")
			_respawn(Vector3(v[0], 0.0, v[1]), Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(v[2])))


func _respawn(pos: Vector3 = Vector3.INF, forward: Vector3 = Vector3.ZERO) -> void:
	var terrain: Terrain3D = $Terrain3D
	if pos == Vector3.INF:
		pos = car.global_position
	if forward == Vector3.ZERO:
		forward = -car.global_basis.z
	forward.y = 0.0
	var h := terrain.data.get_height(pos)
	if is_nan(h):
		h = 0.0
	pos.y = maxf(h, WorldDefs.WATER_LEVEL) + 1.5
	car.place(Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), pos))
	camera.snap()


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.0012
	env.fog_aerial_perspective = 0.4
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.shadow_enabled = not OpenWorld.is_software_renderer()
	add_child(sun)


func _build_water() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.26, 0.32, 0.82)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.08
	var plane := PlaneMesh.new()
	plane.size = Vector2(2048.0, 2048.0)
	plane.material = mat
	var water := MeshInstance3D.new()
	water.mesh = plane
	water.position.y = WorldDefs.WATER_LEVEL
	add_child(water)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_fps = Label.new()
	_fps.position = Vector2(16, 12)
	_fps.add_theme_font_size_override("font_size", 22)
	_fps.add_theme_color_override("font_outline_color", Color.BLACK)
	_fps.add_theme_constant_override("outline_size", 6)
	layer.add_child(_fps)


func _process(delta: float) -> void:
	_time += delta
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)
	var p := car.global_position
	_fps.text = "Terrain3D · %d FPS (%.1f мс) · %d км/ч · x %.0f z %.0f · R — на место" % [
		Engine.get_frames_per_second(), _frame_ms,
		car.linear_velocity.length() * ArcadeCar.MPS_TO_KMH, p.x, p.z]
	if _shot_path != "" and _time > 6.0:
		var path := _shot_path
		_shot_path = ""
		print("Кадр: %.1f мс, позиция %s" % [_frame_ms, p])
		get_viewport().get_texture().get_image().save_png(path)
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("respawn"):
		_respawn()
