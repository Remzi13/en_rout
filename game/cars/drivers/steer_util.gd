class_name SteerUtil
extends RefCounted
## Общие вычисления для ИИ-водителей.


## Руль -1..1, чтобы ехать в точку target (в мировых координатах): дуга
## через точку даёт нужный угол колёс, он делится на доступный на этой
## скорости. Руль в упоре (±1) значит, что на такой скорости не вписаться.
static func steer_to(car: ArcadeCar, target: Vector3, gain: float = 1.6) -> float:
	var local := car.global_transform.affine_inverse() * target
	var angle := atan2(local.x, -local.z)
	var dist := maxf(Vector2(local.x, local.z).length(), 1.0)
	var wheel_deg := rad_to_deg(atan(car.stats.wheelbase_m * 2.0 * sin(angle) / dist))
	if absf(angle) > PI * 0.5:
		wheel_deg = signf(angle) * car.stats.max_steer_angle_deg
	return clampf(wheel_deg * gain / car.max_steer_deg(), -1.0, 1.0)


## Регулятор скорости: заполняет газ/тормоз, чтобы держать target_mps.
static func hold_speed(car: ArcadeCar, c: ArcadeCar.CarControls, target_mps: float) -> void:
	var err := target_mps - car.get_forward_speed()
	if err > 0.0:
		c.throttle = clampf(err * 0.5, 0.15, 1.0)
	elif err < -2.0:
		c.brake = clampf(-err * 0.15, 0.0, 1.0)


## Луч вперёд по курсу машины; возвращает дистанцию до препятствия или INF.
static func probe(car: ArcadeCar, yaw_deg: float, length: float, mask: int, ignore_ground: bool = true) -> Dictionary:
	var fwd := (-car.global_basis.z).rotated(Vector3.UP, deg_to_rad(-yaw_deg))
	fwd.y *= 0.3
	fwd = fwd.normalized()
	var from := car.global_position + Vector3.UP * 0.4 + fwd * (car.stats.scaled_size().z * 0.5 + 0.2)
	var q := PhysicsRayQueryParameters3D.create(from, from + fwd * length, mask, [car.get_rid()])
	var hit := car.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"dist": INF}
	var col: Object = hit.get("collider")
	if ignore_ground and col != null and col.has_meta("surface"):
		var n: Vector3 = hit["normal"]
		if n.y > 0.6: # пологий рельеф — не препятствие
			return {"dist": INF}
	var hp: Vector3 = hit["position"]
	return {"dist": from.distance_to(hp), "collider": col}
