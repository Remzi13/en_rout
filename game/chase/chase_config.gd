class_name ChaseConfig
extends Resource
## Параметры погони (game/chase/chase_config.tres).

@export_group("Когда начинается")
@export_range(5.0, 600.0) var min_interval_s: float = 60.0
@export_range(5.0, 900.0) var max_interval_s: float = 180.0
@export_range(0.0, 10.0) var warning_s: float = 3.0
@export_range(0.0, 15.0) var result_s: float = 4.0

@export_group("Состав события")
@export_range(1, 6) var min_pursuers: int = 2
@export_range(1, 6) var max_pursuers: int = 4
@export_range(0.7, 1.3) var min_skill: float = 0.92
@export_range(0.7, 1.3) var max_skill: float = 1.06
@export_range(60.0, 400.0) var spawn_min_m: float = 120.0
@export_range(60.0, 500.0) var spawn_max_m: float = 200.0

@export_group("Победа и поражение")
@export_range(50.0, 1000.0) var escape_distance_m: float = 300.0
@export_range(1.0, 30.0) var escape_time_s: float = 8.0
@export_range(0.0, 40.0) var capture_speed_kmh: float = 10.0
@export_range(3.0, 40.0) var capture_distance_m: float = 15.0
@export_range(1.0, 15.0) var capture_time_s: float = 4.0

@export_group("Очки")
@export var points_per_second: float = 10.0
@export var points_per_kmh_top: float = 3.0
@export var points_near_miss: float = 150.0
@export var points_per_drift_second: float = 40.0
@export var escape_bonus: float = 1000.0
@export var bonus_per_pursuer: float = 250.0
@export_range(0.0, 1.0) var caught_multiplier: float = 0.5
@export_range(40.0, 200.0) var near_miss_min_kmh: float = 60.0
@export_range(1.5, 6.0) var near_miss_distance_m: float = 3.6
