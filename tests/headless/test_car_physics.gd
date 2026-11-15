extends SceneTree
# ArcadeCar грузится в рантайме: в режиме -s автозагрузка GameState
# не видна при компиляции этого скрипта.
## Физика машины на ровной площадке: колёса стоят на земле (машина не висит),
## на скорости руль не срывает машину в занос, разгон и торможение в рамках.

const H := preload("res://tests/headless/helper.gd")
const KMH := 3.6

var car
var bot := Bot.new()


class Bot:
	extends RefCounted
	var throttle := 0.0
	var brake := 0.0
	var steer := 0.0

	func update_input(_car, c, _delta: float) -> void:
		c.throttle = throttle
		c.brake = brake
		c.steer = steer


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


## Высота нижней точки колёс над землёй (земля на y = 0).
func _wheel_gap_m() -> float:
	var lowest := INF
	for w in car.model.get_children():
		if w is MeshInstance3D:
			continue
		lowest = minf(lowest, (w as Node3D).global_position.y - car.model.wheel_radius())
	return lowest


func _run() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.set_meta("surface", WorldDefs.Surface.ASPHALT)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 2.0, 4000.0)
	cs.shape = box
	cs.position.y = -1.0
	ground.add_child(cs)
	root.add_child(ground)

	car = load("res://game/cars/arcade_car.gd").new()
	car.stats = load("res://game/cars/stats/player.tres")
	car.auto_respawn = false
	car.with_headlights = false
	car.driver = bot
	root.add_child(car)
	car.place(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0)))
	await _frames(180)

	var gap: float = _wheel_gap_m()
	H.check("колёса стоят на земле", absf(gap) < 0.03, "зазор под колесом %.3f м" % gap)
	H.check("все колёса на земле", car.grounded_wheels == 4, "%d" % car.grounded_wheels)
	var bottom: float = car.global_position.y - car.stats.scaled_size().y * 0.05
	H.check("кузов не лежит на земле", bottom > 0.25, "просвет коробки %.3f м" % bottom)

	# Разгон 0–100.
	bot.throttle = 1.0
	var t100 := 0.0
	while car.get_forward_speed() * KMH < 100.0 and t100 < 20.0:
		await physics_frame
		t100 += H.DT
	H.check("разгон 0–100 за 3–7 с", t100 > 3.0 and t100 < 7.0, "%.1f с" % t100)

	# Руль до упора на 100 км/ч: машина поворачивает, а не скользит боком.
	bot.steer = 1.0
	var max_slip := 0.0
	var max_tilt := 0.0
	var drifted := false
	var yaw0: float = car.global_rotation.y
	for i in 90:
		await physics_frame
		bot.throttle = 1.0 if car.get_forward_speed() * KMH < 100.0 else 0.0
		max_slip = maxf(max_slip, car.slip_angle_deg)
		max_tilt = maxf(max_tilt, rad_to_deg(car.global_basis.y.angle_to(Vector3.UP)))
		drifted = drifted or car.drifting
	var turned := absf(rad_to_deg(angle_difference(yaw0, car.global_rotation.y)))
	H.check("на 100 км/ч руль не срывает в занос", not drifted and max_slip < 8.0, "увод до %.1f°" % max_slip)
	H.check("на 100 км/ч машина поворачивает", turned > 30.0 and turned < 90.0, "%.0f° за 1,5 с" % turned)
	H.check("в повороте машина не опрокидывается", max_tilt < 12.0 and car.grounded_wheels >= 3, "крен до %.1f°" % max_tilt)

	# На малой скорости разворот остаётся тесным.
	bot.steer = 0.0
	bot.throttle = 0.0
	bot.brake = 1.0
	while car.get_forward_speed() > 1.5:
		await physics_frame
	bot.brake = 0.0
	bot.steer = 1.0
	var pts: Array[Vector3] = []
	for i in 240:
		await physics_frame
		bot.throttle = 1.0 if car.get_forward_speed() * KMH < 25.0 else 0.0
		if i >= 120:
			pts.append(car.global_position)
	var a := pts[0]
	var far := 0.0
	for p in pts:
		far = maxf(far, a.distance_to(p))
	H.check("на 25 км/ч разворот в ширину шоссе", far < 12.0, "диаметр не меньше %.1f м" % far)

	# Торможение со 100.
	bot.steer = 0.0
	bot.throttle = 1.0
	while car.get_forward_speed() * KMH < 100.0:
		await physics_frame
	bot.throttle = 0.0
	bot.brake = 1.0
	var start: Vector3 = car.global_position
	while car.get_forward_speed() > 0.5:
		await physics_frame
	var dist: float = start.distance_to(car.global_position)
	H.check("тормозной путь со 100 км/ч 15–35 м", dist > 15.0 and dist < 35.0, "%.1f м" % dist)
	H.finish(self)
