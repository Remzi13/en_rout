@tool
class_name TreeModel
extends Resource
## Одна модель дерева и правила её вариаций. Сама модель — glTF из Blender
## (tools/blender/make_trees.py), а всё ниже накладывается из кода на каждый
## экземпляр: пропорции — через трансформ экземпляра MultiMesh, оттенок —
## через цвет экземпляра. Поэтому вариации не требуют новых мешей.

## Модель (glb/gltf) для ближних чанков.
@export_file("*.glb", "*.gltf") var model_path: String = ""
## Упрощённая модель для дальних чанков. Пусто — всегда рисуется основная.
@export_file("*.glb", "*.gltf") var lod_path: String = ""
## Доля модели среди деревьев слоя.
@export_range(0.0, 10.0, 0.01) var weight: float = 1.0
## Радиус ствола у земли при масштабе 1, м — для коллизии.
@export_range(0.05, 1.0, 0.01) var trunk_radius_m: float = 0.2
## Разброс высоты экземпляров: множитель от и до.
@export var height_scale: Vector2 = Vector2(0.85, 1.2)
## Разброс ширины (кроны и ствола): множитель от и до.
@export var width_scale: Vector2 = Vector2(0.9, 1.15)
## Цвет, на который умножается листва модели (белый — как в модели).
@export var leaf_tint: Color = Color.WHITE
## Разброс оттенка листвы между экземплярами (доля круга оттенков).
@export_range(0.0, 0.2, 0.005) var hue_jitter: float = 0.025
## Разброс яркости между экземплярами, доля.
@export_range(0.0, 0.5, 0.01) var value_jitter: float = 0.12


## Модель из кода: TreeModel.create("oak_a", 1.0, 0.36).
## name — имя файла без расширения в папке моделей.
static func create(name: String, model_weight: float = 1.0, trunk_radius: float = 0.2) -> TreeModel:
	var m := TreeModel.new()
	m.model_path = TreeLibrary.MODELS_DIR + name + ".glb"
	m.lod_path = TreeLibrary.MODELS_DIR + name + "_lod.glb"
	m.weight = model_weight
	m.trunk_radius_m = trunk_radius
	return m
