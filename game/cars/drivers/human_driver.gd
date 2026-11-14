class_name HumanDriver
extends RefCounted
## Ввод игрока: клавиатура (дискретно) и геймпад (аналоговые триггеры и стик).

var enabled: bool = true


func update_input(_car: ArcadeCar, c: ArcadeCar.CarControls, _delta: float) -> void:
	if not enabled:
		return
	c.throttle = Input.get_action_strength("accelerate")
	c.brake = Input.get_action_strength("brake")
	c.steer = Input.get_axis("steer_left", "steer_right")
	c.handbrake = Input.is_action_pressed("handbrake")
