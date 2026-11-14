class_name CarStats
extends Resource
## Характеристики машины (аркадная модель ArcadeCar). Отдельные .tres
## для игрока, трафика и уличных гонщиков лежат рядом в game/cars/stats/.

@export_group("Скорость")
@export_range(60.0, 320.0) var max_speed_kmh: float = 200.0
@export_range(4.0, 30.0) var acceleration_mps2: float = 13.0
@export_range(10.0, 40.0) var brake_decel_mps2: float = 24.0
@export_range(1.0, 8.0) var coast_decel_mps2: float = 2.5
@export_range(15.0, 60.0) var reverse_max_speed_kmh: float = 35.0
@export_range(3.0, 15.0) var reverse_acceleration_mps2: float = 7.0

@export_group("Руль")
@export_range(15.0, 45.0) var max_steer_angle_deg: float = 32.0
@export_range(2.0, 15.0) var min_steer_angle_deg: float = 5.0
@export_range(60.0, 400.0) var steer_speed_deg_s: float = 160.0
@export_range(60.0, 500.0) var steer_return_speed_deg_s: float = 240.0
@export_range(2.0, 3.8) var wheelbase_m: float = 2.7

@export_group("Сцепление")
@export_range(1.0, 15.0) var lateral_grip: float = 7.0
@export_range(0.0, 1.0) var lateral_speed_retention: float = 0.85
@export_range(0.05, 1.0) var handbrake_grip_factor: float = 0.22
@export_range(1.0, 2.0) var handbrake_yaw_boost: float = 1.45
@export_range(0.0, 15.0) var handbrake_decel_mps2: float = 5.0
@export_range(1.0, 2.5) var drift_yaw_factor: float = 1.25

@export_group("Кузов")
@export_range(600.0, 3000.0) var mass_kg: float = 1300.0
@export_range(0.0, 20.0) var extra_gravity_mps2: float = 9.0
@export_range(0.3, 0.8) var ride_height_m: float = 0.5
@export_range(20000.0, 200000.0) var suspension_stiffness: float = 70000.0
@export_range(1000.0, 20000.0) var suspension_damping: float = 5500.0
@export var body_size: Vector3 = Vector3(1.9, 1.3, 4.3)
