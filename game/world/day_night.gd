class_name DayNight
extends Node
## Цикл суток: положение солнца/луны, цвет неба, освещение и туман.
## Полный оборот — cycle_seconds. Ночью GameState.is_night = true (фары).

@export_range(60.0, 3600.0) var cycle_seconds: float = 600.0
@export_range(0.0, 24.0) var start_hour: float = 10.0

var hour: float = 10.0
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ProceduralSkyMaterial
## 0..1, насколько погода «гасит» солнце (выставляет Weather).
var overcast: float = 0.0
var fog_boost: float = 0.0

const DAY_TOP := Color(0.24, 0.46, 0.82)
const DAY_HORIZON := Color(0.66, 0.77, 0.88)
const DUSK_HORIZON := Color(0.95, 0.55, 0.3)
const NIGHT_TOP := Color(0.01, 0.015, 0.04)
const NIGHT_HORIZON := Color(0.04, 0.05, 0.09)
const GREY_TOP := Color(0.42, 0.45, 0.5)
const GREY_HORIZON := Color(0.6, 0.62, 0.65)


func _ready() -> void:
	hour = start_hour


func setup(sun_light: DirectionalLight3D, environment: Environment, sky: ProceduralSkyMaterial) -> void:
	sun = sun_light
	env = environment
	sky_mat = sky
	_apply()


func time_text() -> String:
	var h := int(hour)
	var m := int((hour - h) * 60.0)
	return "%02d:%02d" % [h, m]


## Высота солнца, -1..1 (sin угла над горизонтом).
func sun_height() -> float:
	return sin((hour - 6.0) / 12.0 * PI)


func _process(delta: float) -> void:
	hour = fmod(hour + delta * 24.0 / cycle_seconds, 24.0)
	_apply()


func _apply() -> void:
	if sun == null:
		return
	var h := sun_height()
	var day := smoothstep(-0.12, 0.25, h) # 0 — ночь, 1 — день
	var dusk := (1.0 - absf(h) / 0.3) if absf(h) < 0.3 else 0.0
	GameState.is_night = day < 0.25

	# Днём — солнце, ночью — тусклая «луна» с противоположной стороны.
	var elev := asin(clampf(h, -1.0, 1.0))
	var az := (hour / 24.0) * TAU
	if day > 0.05:
		sun.rotation = Vector3(-maxf(elev, 0.05), az, 0.0)
		sun.light_color = Color(1.0, 0.96, 0.9).lerp(Color(1.0, 0.6, 0.35), dusk)
		sun.light_energy = lerpf(0.05, 1.25, day) * (1.0 - overcast * 0.6)
	else:
		sun.rotation = Vector3(-0.7, az + PI, 0.0)
		sun.light_color = Color(0.55, 0.65, 1.0)
		sun.light_energy = 0.3 * (1.0 - overcast * 0.5)

	var top := NIGHT_TOP.lerp(DAY_TOP, day)
	var horizon := NIGHT_HORIZON.lerp(DAY_HORIZON, day).lerp(DUSK_HORIZON, dusk * 0.7)
	top = top.lerp(GREY_TOP * maxf(day, 0.08), overcast * 0.8)
	horizon = horizon.lerp(GREY_HORIZON * maxf(day, 0.08), overcast * 0.8)
	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = horizon
	sky_mat.ground_horizon_color = horizon
	sky_mat.ground_bottom_color = horizon.darkened(0.6)
	sky_mat.sun_angle_max = 30.0
	# Ночью небо почти чёрное — подмешиваем «лунный» окружающий свет.
	env.ambient_light_color = Color(0.32, 0.38, 0.6)
	env.ambient_light_sky_contribution = lerpf(0.35, 1.0, day)
	env.ambient_light_energy = lerpf(0.55, 1.0, day)
	env.fog_light_color = horizon
	env.fog_density = 0.0012 + fog_boost
	env.background_energy_multiplier = lerpf(0.4, 1.0, day)
