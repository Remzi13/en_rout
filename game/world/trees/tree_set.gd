@tool
class_name TreeSet
extends Resource
## Набор деревьев для слоя растительности: какие модели и в каких долях
## стоят в лесу, плюс общие для набора поправки (размер, цвет листвы, зерно).
## Пример из кода — осенний березняк:
##   var s := TreeSet.new()
##   s.add(TreeModel.create("birch_a", 2.0, 0.13))
##   s.add(TreeModel.create("oak_a", 1.0, 0.36))
##   s.leaf_tint = Color(1.0, 0.75, 0.35)
##   layer.tree_set = s

## Модели набора.
@export var models: Array[TreeModel] = []
## Общий множитель размера всех деревьев набора.
@export_range(0.3, 3.0, 0.01) var size_scale: float = 1.0
## Общий цвет, на который умножается листва (поверх leaf_tint модели).
@export var leaf_tint: Color = Color.WHITE
## Зерно вариаций: меняет раскладку моделей и разбросы у всех экземпляров.
@export var variation_seed: int = 0

static var _conifer: TreeSet
static var _leafy: TreeSet


## Добавить модель из кода. Возвращает её, чтобы донастроить поля.
func add(model: TreeModel) -> TreeModel:
	models.append(model)
	return model


## Хвойный лес: ели двух видов, сосны, изредка сухие деревья.
static func conifer_forest() -> TreeSet:
	if _conifer == null:
		var s := TreeSet.new()
		s.variation_seed = 101
		s.add(TreeModel.create("spruce_a", 0.36, 0.2))
		s.add(TreeModel.create("spruce_b", 0.26, 0.21))
		s.add(TreeModel.create("pine_a", 0.17, 0.21))
		s.add(TreeModel.create("pine_b", 0.15, 0.23))
		s.add(TreeModel.create("dead_a", 0.06, 0.22))
		_conifer = s
	return _conifer


## Лиственный лес: берёзы, дубы, тополя, изредка сухие деревья.
static func leafy_forest() -> TreeSet:
	if _leafy == null:
		var s := TreeSet.new()
		s.variation_seed = 202
		s.add(TreeModel.create("birch_a", 0.22, 0.13))
		s.add(TreeModel.create("birch_b", 0.18, 0.14))
		s.add(TreeModel.create("oak_a", 0.2, 0.36))
		s.add(TreeModel.create("oak_b", 0.17, 0.4))
		var poplar := s.add(TreeModel.create("poplar_a", 0.18, 0.2))
		poplar.width_scale = Vector2(0.9, 1.1)
		s.add(TreeModel.create("dead_a", 0.05, 0.22))
		_leafy = s
	return _leafy
