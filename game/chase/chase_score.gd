class_name ChaseScore
extends RefCounted
## Счёт одной погони: время, максимальная скорость, опасные пролёты мимо
## трафика, заносы и бонус за исход.

var config: ChaseConfig
var duration_s: float = 0.0
var top_speed_kmh: float = 0.0
var near_misses: int = 0
var drift_s: float = 0.0


func _init(cfg: ChaseConfig) -> void:
	config = cfg


func tick(delta: float, speed_kmh: float, drifting: bool) -> void:
	duration_s += delta
	top_speed_kmh = maxf(top_speed_kmh, speed_kmh)
	if drifting:
		drift_s += delta


func add_near_miss() -> void:
	near_misses += 1


## Очки без бонуса за исход (идут на HUD во время погони).
func running_total() -> int:
	return int(duration_s * config.points_per_second + top_speed_kmh * config.points_per_kmh_top
		+ near_misses * config.points_near_miss + drift_s * config.points_per_drift_second)


func final_total(outcome: int, pursuers: int) -> int:
	var base := float(running_total())
	if outcome == ChaseRules.Outcome.ESCAPED:
		return int(base + config.escape_bonus + config.bonus_per_pursuer * pursuers)
	return int(base * config.caught_multiplier)
