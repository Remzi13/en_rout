class_name CarModel
extends Node3D
## Визуальная модель машины: кузов и колёса из glTF (tools/blender/make_cars.py).
## Перед машины — направление -Z. ArcadeCar ждёт только методы
## update_wheels / set_lights / set_brake и wheel_positions / wheel_radius.
## Стиль — docs/visual-style.md: гладкий упрощённый кузов с лаком, без текстур.

enum Style { SPORT, SEDAN, VAN, RACER }

const WHEEL_RADIUS := 0.36
const MODELS_DIR := "res://game/cars/models/"
const BODY_FILES := {
	Style.SPORT: "car_sport.glb",
	Style.SEDAN: "car_sedan.glb",
	Style.VAN: "car_van.glb",
	Style.RACER: "car_racer.glb",
}
## Размер, под который сделана модель (CarStats.body_size до SCALE).
const BODY_SIZES := {
	Style.SPORT: Vector3(1.9, 1.3, 4.3),
	Style.SEDAN: Vector3(1.9, 1.5, 4.5),
	Style.VAN: Vector3(2.0, 2.0, 4.8),
	Style.RACER: Vector3(1.9, 1.3, 4.3),
}
const WHEEL_FILE := "wheel.glb"

@export var style: Style = Style.SPORT
@export var body_color: Color = Color(0.9, 0.35, 0.1)
@export var size: Vector3 = Vector3(1.9, 1.3, 4.3)
## Масштаб мелких деталей (колёса, отступы) относительно базовой модели.
@export var unit: float = 1.0

static var _meshes: Dictionary = {} ## имя файла -> Mesh
static var _shared: Dictionary = {} ## имя материала -> общий материал

var _wheels: Array[Node3D] = []
var _spinners: Array[Node3D] = []
var _rest: Array[Vector3] = []
var _paint: StandardMaterial3D
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
	_make_own_materials()

	var body_mesh := _load_mesh(BODY_FILES[style])
	if body_mesh != null:
		var body := MeshInstance3D.new()
		body.name = "Body"
		body.mesh = body_mesh
		body.scale = size / (BODY_SIZES[style] as Vector3)
		_apply_materials(body)
		add_child(body)

	var wheel_mesh := _load_mesh(WHEEL_FILE)
	for p in wheel_positions():
		var pivot := Node3D.new()
		pivot.position = p
		add_child(pivot)
		var spinner := Node3D.new()
		pivot.add_child(spinner)
		if wheel_mesh != null:
			var mi := MeshInstance3D.new()
			mi.mesh = wheel_mesh
			mi.scale = Vector3.ONE * unit
			# Внешняя сторона колеса в модели — +X; слева разворачиваем.
			if p.x < 0.0:
				mi.rotation.y = PI
			_apply_materials(mi)
			spinner.add_child(mi)
		_wheels.append(pivot)
		_spinners.append(spinner)
		_rest.append(p)


func wheel_radius() -> float:
	return WHEEL_RADIUS * unit


## Точки крепления колёс: FL, FR, RL, RR (на уровне низа кузова).
func wheel_positions() -> Array[Vector3]:
	var x := size.x * 0.5 - 0.12 * unit
	var z := size.z * 0.5 - 0.75 * unit
	var y := -size.y * 0.5 + wheel_radius()
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


## Материалы, которые у каждой машины свои: цвет лака и огни.
func _make_own_materials() -> void:
	_paint = StandardMaterial3D.new()
	_paint.albedo_color = body_color
	_paint.metallic = 0.5
	_paint.roughness = 0.3
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


## Материал по имени поверхности из glTF.
func _material_for(mat_name: String) -> Material:
	match mat_name:
		"paint":
			return _paint
		"head":
			return _head_mat
		"tail":
			return _tail_mat
	return _shared_material(mat_name)


func _apply_materials(mi: MeshInstance3D) -> void:
	for i in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(i)
		var mat_name := src.resource_name.to_lower() if src != null else ""
		mi.set_surface_override_material(i, _material_for(mat_name))


## Общие для всех машин материалы: стекло, чёрный пластик, шина, диск.
static func _shared_material(mat_name: String) -> StandardMaterial3D:
	if _shared.has(mat_name):
		return _shared[mat_name] as StandardMaterial3D
	var m := StandardMaterial3D.new()
	match mat_name:
		"glass":
			m.albedo_color = Color(0.05, 0.07, 0.09)
			m.metallic = 0.6
			m.roughness = 0.08
		"tire":
			m.albedo_color = Color(0.05, 0.05, 0.05)
			m.roughness = 0.9
		"rim":
			m.albedo_color = Color(0.72, 0.72, 0.74)
			m.metallic = 0.85
			m.roughness = 0.3
		_: # trim и всё неизвестное — чёрный матовый пластик
			m.albedo_color = Color(0.07, 0.07, 0.08)
			m.roughness = 0.65
	_shared[mat_name] = m
	return m


## Меш из glb (импортированного Godot) с кешем на все машины.
static func _load_mesh(file: String) -> Mesh:
	if _meshes.has(file):
		return _meshes[file] as Mesh
	var mesh: Mesh = null
	var scene := load(MODELS_DIR + file) as PackedScene
	if scene != null:
		var root := scene.instantiate()
		var mi := _find_mesh(root)
		if mi != null:
			mesh = mi.mesh
		root.free()
	if mesh == null:
		push_warning("CarModel: не удалось загрузить модель %s" % file)
	_meshes[file] = mesh
	return mesh


static func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for c in node.get_children():
		var found := _find_mesh(c)
		if found != null:
			return found
	return null
