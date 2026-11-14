class_name CarModel
extends Node3D
## Визуальная модель машины — заглушка из примитивов (сцена car_model.tscn).
## Перед машины — направление -Z. Чтобы подставить CC0-модель, замените
## сцену: ArcadeCar ждёт только методы update_wheels / set_lights / set_brake.

enum Style { SPORT, SEDAN, VAN, RACER }

const WHEEL_RADIUS := 0.36

@export var style: Style = Style.SPORT
@export var body_color: Color = Color(0.9, 0.35, 0.1)
@export var size: Vector3 = Vector3(1.9, 1.3, 4.3)

var _wheels: Array[Node3D] = []
var _spinners: Array[Node3D] = []
var _rest: Array[Vector3] = []
var _tail_mat: StandardMaterial3D
var _head_mat: StandardMaterial3D
var _built := false


func _ready() -> void:
	if not _built:
		build()


func build() -> void:
	_built = true
	for c in get_children():
		c.queue_free()
	_wheels.clear()
	_spinners.clear()
	_rest.clear()

	var paint := StandardMaterial3D.new()
	paint.albedo_color = body_color
	paint.metallic = 0.55
	paint.roughness = 0.28
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.06, 0.08, 0.1)
	glass.metallic = 0.8
	glass.roughness = 0.08
	var trim := StandardMaterial3D.new()
	trim.albedo_color = Color(0.08, 0.08, 0.09)
	trim.roughness = 0.6
	_head_mat = StandardMaterial3D.new()
	_head_mat.albedo_color = Color(1, 0.97, 0.85)
	_head_mat.emission_enabled = true
	_head_mat.emission = Color(1, 0.95, 0.8)
	_head_mat.emission_energy_multiplier = 0.3
	_tail_mat = StandardMaterial3D.new()
	_tail_mat.albedo_color = Color(0.5, 0.02, 0.02)
	_tail_mat.emission_enabled = true
	_tail_mat.emission = Color(1, 0.05, 0.03)
	_tail_mat.emission_energy_multiplier = 0.4

	var w := size.x
	var l := size.z
	var lower_h := size.y * 0.45
	var lower_y := -size.y * 0.5 + 0.35 + lower_h * 0.5
	var cabin_h := size.y * 0.42
	var cabin_len := l * 0.48
	var cabin_z := 0.15
	var cabin_w := w * 0.86
	match style:
		Style.VAN:
			cabin_h = size.y * 0.55
			cabin_len = l * 0.78
			cabin_z = 0.3
			cabin_w = w * 0.98
		Style.SPORT, Style.RACER:
			cabin_h = size.y * 0.34
			cabin_len = l * 0.42
			cabin_z = 0.25
	_box("Body", Vector3(w, lower_h, l), Vector3(0, lower_y, 0), paint)
	var cabin_y := lower_y + lower_h * 0.5 + cabin_h * 0.5
	_box("Cabin", Vector3(cabin_w, cabin_h, cabin_len), Vector3(0, cabin_y, cabin_z), glass)
	_box("Roof", Vector3(cabin_w * 0.96, 0.06, cabin_len * 0.9), Vector3(0, cabin_y + cabin_h * 0.5, cabin_z), paint)
	_box("Bumper", Vector3(w * 1.02, lower_h * 0.4, 0.2), Vector3(0, lower_y - lower_h * 0.25, -l * 0.5), trim)
	_box("BumperRear", Vector3(w * 1.02, lower_h * 0.4, 0.2), Vector3(0, lower_y - lower_h * 0.25, l * 0.5), trim)
	for sx in [-1.0, 1.0]:
		_box("Head", Vector3(0.4, 0.14, 0.05), Vector3(sx * w * 0.33, lower_y + lower_h * 0.2, -l * 0.5 - 0.01), _head_mat)
		_box("Tail", Vector3(0.38, 0.12, 0.05), Vector3(sx * w * 0.34, lower_y + lower_h * 0.25, l * 0.5 + 0.01), _tail_mat)
	if style == Style.RACER:
		_box("Spoiler", Vector3(w * 0.95, 0.06, 0.4), Vector3(0, lower_y + lower_h * 0.5 + 0.35, l * 0.45), trim)
		for sx in [-1.0, 1.0]:
			_box("Strut", Vector3(0.06, 0.35, 0.1), Vector3(sx * w * 0.35, lower_y + lower_h * 0.5 + 0.17, l * 0.45), trim)
		var stripe := StandardMaterial3D.new()
		stripe.albedo_color = Color(0.95, 0.95, 0.95)
		stripe.roughness = 0.3
		_box("Stripe", Vector3(0.35, 0.02, l * 1.001), Vector3(0, lower_y + lower_h * 0.5 + 0.005, 0), stripe)

	var tire := CylinderMesh.new()
	tire.top_radius = WHEEL_RADIUS
	tire.bottom_radius = WHEEL_RADIUS
	tire.height = 0.28
	tire.radial_segments = 14
	tire.rings = 1
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.05, 0.05, 0.05)
	rubber.roughness = 0.9
	tire.material = rubber
	var rim := CylinderMesh.new()
	rim.top_radius = WHEEL_RADIUS * 0.6
	rim.bottom_radius = WHEEL_RADIUS * 0.6
	rim.height = 0.3
	rim.radial_segments = 8
	rim.rings = 1
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.7, 0.7, 0.72)
	rim_mat.metallic = 0.9
	rim_mat.roughness = 0.3
	rim.material = rim_mat
	for p in wheel_positions():
		var pivot := Node3D.new()
		pivot.position = p
		add_child(pivot)
		var spinner := Node3D.new()
		pivot.add_child(spinner)
		for m: Mesh in [tire, rim]:
			var mi := MeshInstance3D.new()
			mi.mesh = m
			mi.rotation.z = PI * 0.5
			spinner.add_child(mi)
		_wheels.append(pivot)
		_spinners.append(spinner)
		_rest.append(p)


## Точки крепления колёс: FL, FR, RL, RR (на уровне низа кузова).
func wheel_positions() -> Array[Vector3]:
	var x := size.x * 0.5 - 0.12
	var z := size.z * 0.5 - 0.75
	var y := -size.y * 0.5 + WHEEL_RADIUS
	return [Vector3(-x, y, -z), Vector3(x, y, -z), Vector3(-x, y, z), Vector3(x, y, z)]


## wheel_drop — насколько колесо опущено от покоя (м), steer_deg > 0 — вправо.
func update_wheels(steer_deg: float, wheel_drop: PackedFloat32Array, spin_rad: float) -> void:
	for i in _wheels.size():
		_wheels[i].position = _rest[i] + Vector3(0.0, -clampf(wheel_drop[i], -0.25, 0.4), 0.0)
		if i < 2:
			_wheels[i].rotation.y = -deg_to_rad(steer_deg)
		_spinners[i].rotation.x = wrapf(_spinners[i].rotation.x - spin_rad, -PI, PI)


func set_lights(on: bool) -> void:
	if _head_mat == null:
		return
	_head_mat.emission_energy_multiplier = 4.0 if on else 0.3
	_tail_mat.emission_energy_multiplier = 1.5 if on else 0.4


func set_brake(on: bool) -> void:
	if _tail_mat != null:
		_tail_mat.emission_energy_multiplier = 5.0 if on else (1.5 if _head_mat.emission_energy_multiplier > 1.0 else 0.4)


func _box(node_name: String, box_size: Vector3, pos: Vector3, mat: Material) -> void:
	var m := BoxMesh.new()
	m.size = box_size
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
