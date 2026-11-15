class_name DeliveryDef
extends Resource
## Доставка: что везём, откуда и куда (id точек Spots из WorldIndex.spots) и
## текст записи в бортовой журнал. Один ресурс на доставку,
## game/missions/*.tres. Доставка с order = 1 выдаётся при новой игре.

const DIR := "res://game/missions"

@export var id: String = ""
## Что везём, со строчной («копчёная рыба»): подсказка «Взять: <cargo>».
@export var cargo: String = ""
@export var from_spot: String = ""
@export var to_spot: String = ""
## Текст записи в журнале при сдаче.
@export_multiline var journal_text: String = ""
## Порядок; 1 — первая, выдаётся сразу при новой игре.
@export var order: int = 0


## Все доставки из папки, по order (затем по id). Ресурсы без id пропускаются.
static func load_all(dir: String = DIR) -> Array[DeliveryDef]:
	var out: Array[DeliveryDef] = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	# list_directory учитывает переименования .remap в собранной игре.
	for file in ResourceLoader.list_directory(dir):
		if not file.ends_with(".tres"):
			continue
		var def := load(dir.path_join(file)) as DeliveryDef
		if def == null or def.id == "":
			push_warning("Доставка %s без id или не DeliveryDef — пропущена" % file)
			continue
		out.append(def)
	out.sort_custom(func(a: DeliveryDef, b: DeliveryDef) -> bool:
		return a.order < b.order if a.order != b.order else a.id < b.id)
	return out
