class_name FollowCamera
extends Camera3D
## Камера от третьего лица: плавно следует за машиной по горизонтальному
## курсу, FOV растёт со скоростью, трясётся при ударах и не проходит
## сквозь рельеф (луч от машины к камере).

@export_range(4.0, 12.0) var distance_m: float = 6.5
@export_range(1.0, 5.0) var height_m: float = 2.3
@export_range(0.0, 8.0) var look_ahead_m: float = 3.0
@export_range(2.0, 20.0) var follow_lerp: float = 6.0
@export_range(55.0, 80.0) var fov_base_deg: float = 68.0
@export_range(65.0, 100.0) var fov_max_deg: float = 86.0
@export_range(0.0, 1.0) var shake_decay: float = 0.9

var target: ArcadeCar
var _dir := Vector3.FORWARD
var _snapped := false
var _shake: float = 0.0
var _noise := FastNoiseLite.new()
var _t: float = 0.0


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_noise.frequency = 2.0
	near = 0.1
	far = 1500.0


func add_shake(amount: float) -> void:
	_shake = clampf(_shake + amount, 0.0, 1.0)


func snap() -> void:
	_snapped = false


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	_t += delta
	var xf := target.get_global_transform_interpolated()
	var pos := xf.origin
	# Курс — по скорости, если машина едет (в заносе камера смотрит по траектории).
	var heading := -xf.basis.z
	var vel := target.linear_velocity
	vel.y = 0.0
	if vel.length() > 8.0 and target.get_forward_speed() > 0.0:
		heading = heading.lerp(vel.normalized(), 0.35)
	heading.y = 0.0
	if heading.length_squared() > 0.0001:
		heading = heading.normalized()
		if _snapped:
			var ang := _dir.signed_angle_to(heading, Vector3.UP)
			_dir = _dir.rotated(Vector3.UP, ang * (1.0 - exp(-follow_lerp * delta))).normalized()
		else:
			_dir = heading
			_snapped = true

	var pivot := pos + Vector3.UP * 1.2
	var desired := pos - _dir * distance_m + Vector3.UP * height_m
	var q := PhysicsRayQueryParameters3D.create(pivot, desired, ArcadeCar.LAYER_WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		var hp: Vector3 = hit["position"]
		desired = hp + (pivot - hp).normalized() * 0.4

	var speed_t := clampf(target.get_speed_kmh() / target.stats.max_speed_kmh, 0.0, 1.0)
	var offset := Vector3.ZERO
	if _shake > 0.001:
		var s := _shake * _shake * 0.35
		offset = Vector3(_noise.get_noise_2d(_t * 40.0, 0.0), _noise.get_noise_2d(0.0, _t * 40.0), 0.0) * s
		_shake *= pow(1.0 - shake_decay, delta)
	# Лёгкая вибрация на большой скорости.
	offset += Vector3(0, _noise.get_noise_2d(_t * 25.0, 99.0) * 0.02 * speed_t * speed_t, 0)
	global_position = desired + offset
	look_at(pos + _dir * look_ahead_m + Vector3.UP * 0.9, Vector3.UP)
	fov = lerpf(fov, lerpf(fov_base_deg, fov_max_deg, speed_t * speed_t), 1.0 - exp(-4.0 * delta))
