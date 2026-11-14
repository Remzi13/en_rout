class_name CarAudio
extends Node3D
## Звук машины: петля двигателя (высота тона от скорости и газа) и визг шин
## в заносе. Звуки — процедурные заглушки из Synth.

var _engine: AudioStreamPlayer3D
var _tires: AudioStreamPlayer3D
var _rev: float = 0.0


func _ready() -> void:
	_engine = _player(Synth.engine_loop(), -6.0)
	_tires = _player(Synth.tire_loop(), -80.0)
	if is_inside_tree() and not Engine.is_editor_hint():
		_engine.play()
		_tires.play()


func _player(stream: AudioStream, db: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = &"SFX"
	p.volume_db = db
	p.unit_size = 8.0
	p.max_distance = 160.0
	p.attenuation_filter_cutoff_hz = 6000.0
	add_child(p)
	return p


func update_sound(car: ArcadeCar) -> void:
	var ratio := clampf(absf(car.get_forward_speed()) / maxf(car.max_speed_mps(), 1.0), 0.0, 1.2)
	# Имитация передач: тон растёт внутри «передачи» и проседает при переключении.
	var gears := 5.0
	var g := ratio * gears
	var in_gear := g - floorf(g)
	var target := 0.55 + in_gear * 0.6 + floorf(g) * 0.12
	_rev = lerpf(_rev, target + car.controls.throttle * 0.1, 0.15)
	_engine.pitch_scale = clampf(_rev, 0.4, 2.4)
	_engine.volume_db = lerpf(-12.0, -3.0, maxf(car.controls.throttle, ratio * 0.6))
	var skid := 0.0
	if car.grounded_wheels >= 2:
		skid = clampf((car.slip_angle_deg - 8.0) / 25.0, 0.0, 1.0) * clampf(car.get_speed_kmh() / 40.0, 0.0, 1.0)
		if car.controls.handbrake and car.get_speed_kmh() > 15.0:
			skid = maxf(skid, 0.6)
	_tires.volume_db = linear_to_db(maxf(skid * (1.0 if car.on_road else 0.4), 0.0001)) - 4.0
	_tires.pitch_scale = 0.9 + skid * 0.2
