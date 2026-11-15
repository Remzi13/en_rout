extends Node3D
## Проба Terrain3D: рельеф карты в Terrain3D (собирает tools/make_terrain_test.gd)
## и машина игрока, чтобы покататься и сравнить с нынешним миром из чанков.
## Дороги — часть рельефа (высоты и покрытие): грунтовки целиком, а у шоссе
## поверх лежит лента асфальта вровень с землёй. Леса и трафика нет.
##   godot --path . res://game/terrain_test/terrain_test.tscn
## Отладка (после «--»): --drive — газ зажат сам, --at=x,z,угол — старт в
## другой точке, --shot=файл.png — снимок через 6 с и выход.

const PLAYER_STATS := preload("res://game/cars/stats/player.tres")
const START := Vector3(-220.0, 0.0, 85.0) ## PlayerStart из art/map/map.blend
const TEX_DIRT := 2 ## номера текстур рельефа, как в tools/make_terrain_test.gd
const TEX_ASPHALT := 3
const DECK_LIFT_M := 0.03 ## лента шоссе над выровненным рельефом

var car: ArcadeCar
var camera: FollowCamera
var _highways: Node3D
var _fps: Label
var _frame_ms: float = 0.0
var _shot_path: String = ""
var _time: float = 0.0


func _ready() -> void:
	var terrain: Terrain3D = $Terrain3D
	_build_environment()
	_build_water()
	_build_highways()

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


## Свет и небо как в игре (OpenWorld), солнце ведёт DayNight: 10 утра, сутки
## не идут, чтобы снимки можно было сравнивать.
func _build_environment() -> void:
	var lighting := OpenWorld.build_lighting(self)
	var sun: DirectionalLight3D = lighting["sun"]
	sun.shadow_enabled = not OpenWorld.is_software_renderer()
	var day_night := DayNight.new()
	add_child(day_night)
	day_night.setup(sun, lighting["env"], lighting["sky"])
	day_night.set_process(false)


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


## Асфальт шоссе — лента вровень с рельефом: ровная кромка и разметка из
## текстуры шоссе, без юбок. Рельеф под лентой выровнен по её профилю, а в
## середине чуть утоплен (tools/make_terrain_test.gd), чтобы не просвечивал.
func _build_highways() -> void:
	var index := WorldIndex.load_baked()
	if index == null:
		return
	_highways = Node3D.new()
	_highways.name = "Highways"
	add_child(_highways)
	var hw := WorldDefs.ROAD_WIDTHS[WorldDefs.RoadType.HIGHWAY] * 0.5
	var lift := Vector3.UP * DECK_LIFT_M
	for r in index.road_points.size():
		if index.road_types[r] != WorldDefs.RoadType.HIGHWAY:
			continue
		var pts := index.road_points[r]
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var indices := PackedInt32Array()
		var faces := PackedVector3Array()
		var along := 0.0
		for k in pts.size():
			if k > 0:
				along += pts[k].distance_to(pts[k - 1])
			var t := pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)]
			var right := Vector3(-t.z, 0.0, t.x).normalized() * hw
			verts.append_array([pts[k] - right + lift, pts[k] + right + lift])
			normals.append_array([Vector3.UP, Vector3.UP])
			uvs.append_array([Vector2(0.0, along / 10.0), Vector2(1.0, along / 10.0)])
			if k > 0:
				var i := k * 2
				indices.append_array([i - 2, i, i - 1, i - 1, i, i + 1])
				faces.append_array([verts[i - 2], verts[i], verts[i - 1], verts[i - 1], verts[i], verts[i + 1]])
		for node: Node in WorldMaterials.build_static(verts, normals, uvs, indices, faces,
				WorldMaterials.shared().highway, WorldDefs.Surface.ASPHALT):
			_highways.add_child(node)


## Покрытие под машиной вне шоссе — из карты текстур рельефа: ArcadeCar читает
## его из меты "surface" у тела под колесом, а у Terrain3D тело одно на весь
## рельеф. У ленты шоссе мета своя.
func _physics_process(_delta: float) -> void:
	var terrain: Terrain3D = $Terrain3D
	var pos := car.global_position
	var surface := WorldDefs.Surface.GRASS
	if not terrain.data.get_control_auto(pos):
		var id := terrain.data.get_control_base_id(pos)
		if id == TEX_ASPHALT:
			surface = WorldDefs.Surface.ASPHALT
		elif id == TEX_DIRT:
			surface = WorldDefs.Surface.DIRT
	var q := PhysicsRayQueryParameters3D.create(pos, pos + Vector3.DOWN * 3.0, ArcadeCar.LAYER_WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty() and (hit["collider"] as Node).get_parent() != _highways:
		(hit["collider"] as Object).set_meta("surface", surface)


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
