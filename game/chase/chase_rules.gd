class_name ChaseRules
extends RefCounted
## Условия исхода погони без сцены (тестируется headless):
## побег — все преследователи дальше escape_distance_m непрерывно escape_time_s;
## захват — игрок почти стоит (< capture_speed_kmh) рядом с преследователем
## (< capture_distance_m) непрерывно capture_time_s.

enum Outcome { NONE, ESCAPED, CAUGHT }

var config: ChaseConfig
var escape_t: float = 0.0
var capture_t: float = 0.0


func _init(cfg: ChaseConfig) -> void:
	config = cfg


func reset() -> void:
	escape_t = 0.0
	capture_t = 0.0


func escape_progress() -> float:
	return clampf(escape_t / config.escape_time_s, 0.0, 1.0)


func capture_progress() -> float:
	return clampf(capture_t / config.capture_time_s, 0.0, 1.0)


## min_dist — расстояние до ближайшего преследователя.
func update(delta: float, min_dist: float, player_speed_kmh: float) -> Outcome:
	if min_dist > config.escape_distance_m:
		escape_t += delta
	else:
		escape_t = 0.0
	if player_speed_kmh < config.capture_speed_kmh and min_dist < config.capture_distance_m:
		capture_t += delta
	else:
		capture_t = 0.0
	if capture_t >= config.capture_time_s:
		return Outcome.CAUGHT
	if escape_t >= config.escape_time_s:
		return Outcome.ESCAPED
	return Outcome.NONE
