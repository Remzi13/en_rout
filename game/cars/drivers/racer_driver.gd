class_name RacerDriver
extends RefCounted
## Уличный гонщик-преследователь. Едет к упреждённой позиции игрока
## напрямую (и по дорогам, и по бездорожью), объезжает трафик, деревья
## и камни тремя лучами, вблизи таранит и подрезает. Умеренная «резинка»:
## отставший немного быстрее, догнавший — чуть медленнее.

var target: ArcadeCar
var skill: float = 1.0 ## 0.9..1.1 — множитель скорости события
var side: float = 1.0 ## с какой стороны подрезать
var stuck_time: float = 0.0
var reverse_time: float = 0.0
var rng := RandomNumberGenerator.new()

var far_distance_m: float = 220.0
var close_distance_m: float = 35.0
var catch_up_boost: float = 1.12
var close_slowdown: float = 0.97


func setup(player: ArcadeCar, event_skill: float, seed_value: int) -> void:
	target = player
	skill = event_skill
	rng.seed = seed_value
	side = -1.0 if rng.randf() < 0.5 else 1.0


func distance_to_target(car: ArcadeCar) -> float:
	return car.global_position.distance_to(target.global_position)


func update_input(car: ArcadeCar, c: ArcadeCar.CarControls, delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	var to_player := target.global_position - car.global_position
	var dist := to_player.length()

	# «Резинка» в разумных пределах.
	var band := 1.0
	if dist > far_distance_m:
		band = lerpf(1.0, catch_up_boost, clampf((dist - far_distance_m) / 200.0, 0.0, 1.0))
	elif dist < close_distance_m:
		band = close_slowdown
	car.speed_scale = skill * band

	if reverse_time > 0.0:
		reverse_time -= delta
		c.brake = 1.0
		c.steer = -side
		return

	# Упреждение: куда игрок приедет, пока мы до него доберёмся.
	var lead := clampf(dist / 40.0, 0.0, 1.6)
	var aim := target.global_position + target.linear_velocity * lead
	if dist < close_distance_m:
		# Вблизи — заход сбоку, а потом удар в бок/заднее колесо.
		var right := target.global_basis.x
		aim = target.global_position + right * side * clampf(dist * 0.15, 0.0, 2.5) + target.linear_velocity * 0.25
	c.steer = SteerUtil.steer_to(car, aim, 1.8)

	var v := car.get_forward_speed()
	var look := 10.0 + absf(v) * 0.9
	var mask := ArcadeCar.LAYER_WORLD | ArcadeCar.LAYER_CARS
	var mid := SteerUtil.probe(car, 0.0, look, mask)
	var left := SteerUtil.probe(car, -22.0, look * 0.8, mask)
	var rgt := SteerUtil.probe(car, 22.0, look * 0.8, mask)
	var mid_d := _obstacle_dist(mid)
	var left_d := _obstacle_dist(left)
	var right_d := _obstacle_dist(rgt)
	if mid_d < look:
		c.steer = clampf(c.steer + (1.0 if left_d < right_d else -1.0) * (1.0 - mid_d / look) * 1.6, -1.0, 1.0)
	if left_d < look * 0.8:
		c.steer = clampf(c.steer + 0.6 * (1.0 - left_d / (look * 0.8)), -1.0, 1.0)
	if right_d < look * 0.8:
		c.steer = clampf(c.steer - 0.6 * (1.0 - right_d / (look * 0.8)), -1.0, 1.0)

	# Газ: почти всегда в пол, сбрасывает в крутом развороте.
	var local := car.global_transform.affine_inverse() * aim
	var angle := absf(atan2(local.x, -local.z))
	c.throttle = 1.0
	if angle > 1.2 and v > 18.0:
		c.throttle = 0.3
		c.handbrake = angle > 1.6
	if mid_d < 8.0 and v > 15.0:
		c.throttle = 0.0
		c.brake = 0.6

	# Игрок почти стоит рядом — подъехать вплотную и зажать, а не проскочить.
	var target_kmh := target.get_speed_kmh()
	if dist < 30.0 and target_kmh < 20.0:
		c.handbrake = false
		var stop_at := 5.0 + car.stats.scaled_size().z * 0.5
		var want := maxf((dist - stop_at) * 0.7, 0.0) + target_kmh / 3.6
		c.throttle = 0.0
		c.brake = 0.0
		SteerUtil.hold_speed(car, c, want)
		c.steer = SteerUtil.steer_to(car, target.global_position, 1.8)
		return

	# Застрял (упёрся в дерево/камень) — сдать назад.
	if absf(v) < 1.0 and c.throttle > 0.5:
		stuck_time += delta
		if stuck_time > 1.2:
			stuck_time = 0.0
			reverse_time = 1.3
			side = -side
	else:
		stuck_time = maxf(stuck_time - delta * 0.5, 0.0)


func _obstacle_dist(probe: Dictionary) -> float:
	var d: float = probe["dist"]
	if d == INF:
		return INF
	# Игрок — цель, а не препятствие.
	if probe.get("collider") == target:
		return INF
	return d
