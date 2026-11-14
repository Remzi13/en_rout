class_name VegetationLayer
extends MultiMeshInstance3D
## Слой растительности чанка (деревья, камни, кусты) в одном MultiMesh.
## Коллизия строится в игре по трансформам экземпляров: один статический
## body на сервере физики, цилиндр на экземпляр. Поэтому после правки
## MultiMesh в редакторе коллизия совпадёт с тем, что видно.

## Радиус и высота цилиндра при масштабе экземпляра 1. Радиус 0 — без коллизии.
@export var collider_radius: float = 0.0
@export var collider_height: float = 6.0
## Экземпляры меньше этого масштаба коллизии не получают (мелкие камни).
@export var collider_min_scale: float = 0.0

var _body: RID


func _ready() -> void:
	if Engine.is_editor_hint() or collider_radius <= 0.0 or multimesh == null:
		return
	# В headless (тесты) MultiMesh не хранит трансформы — все формы встали бы в угол чанка.
	if DisplayServer.get_name() == "headless":
		return
	_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(_body, WorldDefs.LAYER_WORLD)
	PhysicsServer3D.body_set_collision_mask(_body, 0)
	var mats := WorldMaterials.shared()
	for i in multimesh.instance_count:
		var xf := multimesh.get_instance_transform(i)
		var s := xf.basis.get_scale().x
		if s < collider_min_scale:
			continue
		var h := collider_height * s
		var shape := mats.cylinder_shape(collider_radius * s, h)
		PhysicsServer3D.body_add_shape(_body, shape, Transform3D(Basis(), xf.origin + Vector3(0, h * 0.5, 0)))
	PhysicsServer3D.body_set_state(_body, PhysicsServer3D.BODY_STATE_TRANSFORM, global_transform)
	PhysicsServer3D.body_set_space(_body, get_world_3d().space)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _body.is_valid():
		PhysicsServer3D.free_rid(_body)
