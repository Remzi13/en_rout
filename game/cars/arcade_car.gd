class_name ArcadeCar
extends RigidBody3D
## Аркадная машина открытого мира: лучевая подвеска на 4 колеса, тяга,
## торможение, боковое сцепление и поворот по кинематике колёсной базы.
## Сцепление зависит от поверхности под каждым колесом и от погоды
## (GameState.weather_grip). Ручник срывает заднюю ось в управляемый занос.
## Управление одинаково для игрока и ИИ: driver заполняет CarControls.

signal impacted(strength: float)
signal respawn_requested(car: ArcadeCar)

const LAYER_WORLD := 1
const LAYER_CARS := 2
const MPS_TO_KMH := 3.6
const MODEL_SCENE := preload("res://game/cars/car_model.tscn")
const SURFACE_GRIP := [1.0, 0.78, 0.62] ## асфальт, грунт, трава
const SURFACE_SPEED := [1.0, 0.86, 0.7]
const SURFACE_DRAG := [0.0, 1.0, 2.5] ## доп. замедление, м/с²
const SUSPENSION_EXTRA_RAY_M := 0.35
const STOP_SPEED_MPS := 0.3
const IMPACT_DV_MPS := 4.0
const FLIP_TIMEOUT_S := 2.5
const WATER_TIMEOUT_S := 1.5

class CarControls:
	var throttle: float = 0.0
	var brake: float = 0.0
	var steer: float = 0.0
	var handbrake: bool = false

	func clear() -> void:
		throttle = 0.0
		brake = 0.0
		steer = 0.0
		handbrake = false


@export var stats: CarStats
@export var style: CarModel.Style = CarModel.Style.SPORT
@export var body_color: Color = Color(0.95, 0.4, 0.08)
@export var with_headlights: bool = true

var driver: RefCounted = null ## любой объект с update_input(car, controls, delta)
var controls := CarControls.new()
var model: CarModel
var steer_angle_deg: float = 0.0
var grounded_wheels: int = 0
var surface_grip: float = 1.0
var surface_speed: float = 1.0
var on_road: bool = true
var speed_scale: float = 1.0 ## множитель макс. скорости (догоняющий ИИ)
var slip_angle_deg: float = 0.0
var in_water: bool = false
var drifting: bool = false
var auto_respawn: bool = true

var _mounts: Array[Vector3] = []
var _wheel_dist := PackedFloat32Array()
var _rest_length: float = 0.6
var _prev_velocity := Vector3.ZERO
var _flip_time: float = 0.0
var _water_time: float = 0.0
var _impact_cooldown: float = 0.0
var _lights: Array[SpotLight3D] = []
var _lights_on: bool = false


func _ready() -> void:
	if stats == null:
		stats = CarStats.new()
	mass = stats.mass_kg
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.45, 0.1)
	can_sleep = false
	continuous_cd = true
	angular_damp = 1.2
	collision_layer = LAYER_CARS
	collision_mask = LAYER_WORLD | LAYER_CARS
	contact_monitor = true
	max_contacts_reported = 4
	var pm := PhysicsMaterial.new()
	pm.friction = 0.15
	pm.bounce = 0.15
	physics_material_override = pm

	var shape := BoxShape3D.new()
	shape.size = Vector3(stats.body_size.x, stats.body_size.y * 0.8, stats.body_size.z)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = stats.body_size.y * 0.1
	add_child(cs)

	model = MODEL_SCENE.instantiate() as CarModel
	model.style = style
	model.body_color = body_color
	model.size = stats.body_size
	add_child(model)
	for p in model.wheel_positions():
		_mounts.append(Vector3(p.x, -stats.body_size.y * 0.5 + 0.05, p.z))
	_wheel_dist.resize(_mounts.size())
	_wheel_dist.fill(stats.ride_height_m)
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var static_load := mass * (gravity + stats.extra_gravity_mps2) / _mounts.size()
	_rest_length = stats.ride_height_m + static_load / stats.suspension_stiffness

	if with_headlights:
		for sx in [-1.0, 1.0]:
			var l := SpotLight3D.new()
			l.position = Vector3(sx * stats.body_size.x * 0.33, 0.0, -stats.body_size.z * 0.5 - 0.1)
			l.rotation_degrees = Vector3(-6, 0, 0)
			l.spot_range = 70.0
			l.spot_angle = 35.0
			l.spot_attenuation = 0.5
			l.light_energy = 0.0
			l.light_color = Color(1.0, 0.95, 0.85)
			l.shadow_enabled = false
			l.visible = false
			add_child(l)
			_lights.append(l)


func _physics_process(delta: float) -> void:
	controls.clear()
	if driver != null:
		driver.update_input(self, controls, delta)

	_update_suspension()
	var v := get_forward_speed()
	_update_steer(v, delta)
	if grounded_wheels >= 2:
		_apply_drive(v, delta)
	else:
		_air_control(delta)
	_apply_stability(delta)
	_check_water(delta)
	_detect_impact(delta)
	_check_flip(delta)

	var drop := PackedFloat32Array()
	drop.resize(_wheel_dist.size())
	for i in _wheel_dist.size():
		drop[i] = _wheel_dist[i] - _rest_length + 0.1
	model.update_wheels(steer_angle_deg, drop, v * delta / CarModel.WHEEL_RADIUS)
	model.set_brake(controls.brake > 0.1 and v > 1.0)
	_update_lights()


func get_forward_speed() -> float:
	return linear_velocity.dot(-global_basis.z)


func get_speed_kmh() -> float:
	return linear_velocity.length() * MPS_TO_KMH


func max_speed_mps() -> float:
	return stats.max_speed_kmh / MPS_TO_KMH * speed_scale * surface_speed


func is_flipped() -> bool:
	return global_basis.y.dot(Vector3.UP) < 0.2


## Ставит машину в точку (сбрасывает скорости и интерполяцию).
func place(xform: Transform3D, speed_mps: float = 0.0) -> void:
	global_transform = xform
	linear_velocity = -xform.basis.z * speed_mps
	angular_velocity = Vector3.ZERO
	_prev_velocity = linear_velocity
	steer_angle_deg = 0.0
	_flip_time = 0.0
	_water_time = 0.0
	reset_physics_interpolation()


func _update_suspension() -> void:
	var space := get_world_3d().direct_space_state
	var up := global_basis.y
	var ray_len := _rest_length + SUSPENSION_EXTRA_RAY_M
	grounded_wheels = 0
	var grip_sum := 0.0
	var speed_sum := 0.0
	var road_wheels := 0
	for i in _mounts.size():
		var origin := global_transform * _mounts[i]
		var q := PhysicsRayQueryParameters3D.create(origin, origin - up * ray_len, LAYER_WORLD)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			_wheel_dist[i] = ray_len
			continue
		var surf: int = WorldGen.Surface.GRASS
		var col: Object = hit.get("collider")
		if col != null and col.has_meta("surface"):
			surf = col.get_meta("surface")
		var hp: Vector3 = hit["position"]
		var dist := origin.distance_to(hp)
		_wheel_dist[i] = dist
		var compression := _rest_length - dist
		if compression > -0.05:
			grounded_wheels += 1
			grip_sum += SURFACE_GRIP[surf]
			speed_sum += SURFACE_SPEED[surf]
			if surf != WorldGen.Surface.GRASS:
				road_wheels += 1
		if compression <= 0.0:
			continue
		var offset := origin - global_position
		var pv := linear_velocity + angular_velocity.cross(offset)
		var force := stats.suspension_stiffness * compression - stats.suspension_damping * pv.dot(up)
		if force > 0.0:
			apply_force(up * force, offset)
	if grounded_wheels > 0:
		surface_grip = grip_sum / grounded_wheels
		surface_speed = speed_sum / grounded_wheels
		on_road = road_wheels * 2 >= grounded_wheels


func _update_steer(v: float, delta: float) -> void:
	var t := clampf(absf(v) / (stats.max_speed_kmh / MPS_TO_KMH), 0.0, 1.0)
	var max_angle := lerpf(stats.max_steer_angle_deg, stats.min_steer_angle_deg, sqrt(t))
	var target := controls.steer * max_angle
	var returning := absf(target) < absf(steer_angle_deg) or signf(target) != signf(steer_angle_deg)
	var rate := stats.steer_return_speed_deg_s if returning else stats.steer_speed_deg_s
	steer_angle_deg = move_toward(steer_angle_deg, target, rate * delta)


func _apply_drive(v: float, delta: float) -> void:
	var forward := -global_basis.z
	var right := global_basis.x
	var up := global_basis.y
	apply_central_force(Vector3.DOWN * stats.extra_gravity_mps2 * mass)

	var idle := controls.throttle < 0.01 and controls.brake < 0.01
	if idle and absf(v) < STOP_SPEED_MPS and not controls.handbrake:
		linear_velocity = up * linear_velocity.dot(up)
		angular_velocity -= up * angular_velocity.dot(up)
		slip_angle_deg = 0.0
		drifting = false
		return

	var accel := _longitudinal_accel(v, delta)
	if controls.handbrake:
		accel -= signf(v) * minf(stats.handbrake_decel_mps2, absf(v) / delta)
	apply_central_force(forward * accel * mass)

	var grip := stats.lateral_grip * surface_grip * GameState.weather_grip
	if controls.handbrake:
		grip *= stats.handbrake_grip_factor
	var v_lat := linear_velocity.dot(right)
	var v_lat_new := v_lat * exp(-grip * delta)
	apply_central_impulse(right * (v_lat_new - v_lat) * mass)
	if absf(v) > STOP_SPEED_MPS:
		var energy := stats.lateral_speed_retention * (v_lat * v_lat - v_lat_new * v_lat_new)
		var v_fwd_new := signf(v) * sqrt(v * v + energy)
		apply_central_impulse(forward * (v_fwd_new - v) * mass)

	var flat_v := linear_velocity - up * linear_velocity.dot(up)
	slip_angle_deg = rad_to_deg(flat_v.angle_to(forward * signf(v))) if flat_v.length() > 3.0 else 0.0
	drifting = slip_angle_deg > 12.0 and absf(v) > 9.0

	var yaw := -v * tan(deg_to_rad(steer_angle_deg)) / stats.wheelbase_m
	if controls.handbrake:
		yaw *= stats.handbrake_yaw_boost
	elif drifting:
		yaw *= stats.drift_yaw_factor
	var cur_yaw := angular_velocity.dot(up)
	# При заносе вращение не мгновенное — машину можно «ловить» контррулём.
	var yaw_follow := 1.0 if not (controls.handbrake or drifting) else 1.0 - exp(-6.0 * delta)
	angular_velocity += up * (lerpf(cur_yaw, yaw, yaw_follow) - cur_yaw)


func _longitudinal_accel(v: float, delta: float) -> float:
	var max_v := max_speed_mps()
	var rev_max := stats.reverse_max_speed_kmh / MPS_TO_KMH
	var stop_cap := absf(v) / delta
	var drag := SURFACE_DRAG[0] if surface_speed > 0.99 else lerpf(SURFACE_DRAG[2], SURFACE_DRAG[1], (surface_speed - 0.7) / 0.16)
	var a := 0.0
	if controls.brake > 0.01:
		if v > 1.0:
			a = -minf(stats.brake_decel_mps2 * controls.brake, stop_cap)
		else:
			a = -stats.reverse_acceleration_mps2 * controls.brake * clampf(1.0 + v / rev_max, 0.0, 1.0)
	elif controls.throttle > 0.01:
		if v < -1.0:
			a = minf(stats.brake_decel_mps2 * controls.throttle, stop_cap)
		elif v > max_v:
			a = -minf(stats.coast_decel_mps2 * 2.0, (v - max_v) / delta)
		else:
			# Плавная кривая разгона: быстро с места, медленнее у предела.
			a = stats.acceleration_mps2 * controls.throttle * clampf(1.0 - pow(maxf(v, 0.0) / max_v, 1.6), 0.0, 1.0)
	else:
		a = -signf(v) * minf(stats.coast_decel_mps2, stop_cap)
	return a - signf(v) * minf(drag, absf(v) / delta)


## В воздухе машина сама выравнивается — меньше кувырков от мелочей.
func _air_control(delta: float) -> void:
	slip_angle_deg = 0.0
	drifting = false
	var axis := global_basis.y.cross(Vector3.UP)
	apply_torque(axis * mass * 6.0 - angular_velocity * mass * 0.8 * Vector3(1, 0, 1))
	apply_central_force(Vector3.DOWN * stats.extra_gravity_mps2 * mass * 0.5)
	angular_velocity.y = lerpf(angular_velocity.y, 0.0, 1.0 - exp(-1.0 * delta))


## Анти-крен: сильно накренённую машину мягко возвращает на колёса.
func _apply_stability(_delta: float) -> void:
	var up := global_basis.y
	var tilt := up.angle_to(Vector3.UP)
	if tilt > deg_to_rad(25.0):
		var axis := up.cross(Vector3.UP).normalized()
		apply_torque(axis * mass * 10.0 * (tilt - deg_to_rad(25.0)))


func _check_water(delta: float) -> void:
	in_water = global_position.y < WorldGen.WATER_LEVEL - 0.4
	if in_water:
		linear_velocity = linear_velocity.lerp(Vector3.ZERO, 1.0 - exp(-2.5 * delta))
		_water_time += delta
		if _water_time > WATER_TIMEOUT_S and auto_respawn:
			_water_time = 0.0
			respawn_requested.emit(self)
	else:
		_water_time = 0.0


func _check_flip(delta: float) -> void:
	if is_flipped() and linear_velocity.length() < 4.0:
		_flip_time += delta
		if _flip_time > FLIP_TIMEOUT_S and auto_respawn:
			_flip_time = 0.0
			respawn_requested.emit(self)
	else:
		_flip_time = 0.0


func _detect_impact(delta: float) -> void:
	_impact_cooldown = maxf(_impact_cooldown - delta, 0.0)
	var dv := (linear_velocity - _prev_velocity)
	dv.y *= 0.3 # приземления — не удары
	_prev_velocity = linear_velocity
	var expected := 40.0 * delta # обычное ускорение/торможение
	var strength := dv.length() - expected
	if strength > IMPACT_DV_MPS and _impact_cooldown <= 0.0 and get_contact_count() > 0:
		_impact_cooldown = 0.35
		impacted.emit(strength)


func _update_lights() -> void:
	var want := GameState.is_night or GameState.weather_grip < 0.95
	if want == _lights_on:
		return
	_lights_on = want
	model.set_lights(want)
	for l in _lights:
		l.visible = want
		l.light_energy = 8.0 if want else 0.0
