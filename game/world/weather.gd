class_name Weather
extends Node3D
## Погода: ясно / дождь / туман, случайная смена с плавным переходом.
## Дождь — частицы вокруг камеры, мокрая дорога и сниженное сцепление
## (GameState.weather_grip); туман — плотнее дымка и ниже видимость.

enum Kind { CLEAR, RAIN, FOG }
const NAMES := ["Ясно", "Дождь", "Туман"]

@export_range(10.0, 900.0) var min_duration_s: float = 90.0
@export_range(10.0, 1200.0) var max_duration_s: float = 240.0
@export_range(1.0, 30.0) var transition_s: float = 10.0
@export_range(0.5, 1.0) var rain_grip: float = 0.8

var kind: Kind = Kind.CLEAR
var rain_k: float = 0.0
var fog_k: float = 0.0
var day_night: DayNight
var materials: WorldMaterials
var follow: Node3D
var rng := RandomNumberGenerator.new()

var _left: float = 0.0
var _rain: CPUParticles3D
var _rain_mat: StandardMaterial3D


func setup(dn: DayNight, mats: WorldMaterials, follow_node: Node3D, seed_value: int) -> void:
	day_night = dn
	materials = mats
	follow = follow_node
	rng.seed = seed_value
	_left = rng.randf_range(min_duration_s, max_duration_s)
	_build_rain()


func set_kind(k: Kind) -> void:
	kind = k
	_left = rng.randf_range(min_duration_s, max_duration_s)


func _build_rain() -> void:
	_rain = CPUParticles3D.new()
	_rain.amount = 1800
	_rain.lifetime = 0.9
	_rain.emitting = false
	_rain.local_coords = false
	_rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_rain.emission_box_extents = Vector3(28, 2, 28)
	_rain.direction = Vector3(0.1, -1, 0)
	_rain.spread = 3.0
	_rain.gravity = Vector3(0, -30, 0)
	_rain.initial_velocity_min = 18.0
	_rain.initial_velocity_max = 24.0
	var drop := QuadMesh.new()
	drop.size = Vector2(0.02, 0.6)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.75, 0.8, 0.9, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	drop.material = mat
	_rain_mat = mat
	_rain.mesh = drop
	add_child(_rain)


func _process(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		var r := rng.randf()
		set_kind(Kind.CLEAR if r < 0.5 else (Kind.RAIN if r < 0.8 else Kind.FOG))
	var step := delta / transition_s
	rain_k = move_toward(rain_k, 1.0 if kind == Kind.RAIN else 0.0, step)
	fog_k = move_toward(fog_k, 1.0 if kind == Kind.FOG else 0.0, step)

	GameState.weather_grip = lerpf(1.0, rain_grip, rain_k)
	if materials != null:
		materials.set_wetness(rain_k)
	if day_night != null:
		day_night.overcast = maxf(rain_k, fog_k * 0.7)
		day_night.fog_boost = fog_k * 0.014 + rain_k * 0.003
	if _rain != null:
		_rain.emitting = rain_k > 0.05
		_rain_mat.albedo_color.a = 0.35 * clampf(rain_k, 0.0, 1.0)
		if follow != null:
			var p := follow.global_position
			_rain.global_position = p + Vector3(0, 14, 0)
