@tool
class_name WorldChunk
extends Node3D
## Корень сцены одного чанка (game/world/chunks/chunk_X_Z.tscn).
## Состав сцены:
##   Roads — узлы RoadPath (оси дорог и лента шоссе), Junctions — RoadJunction
##     (площадки развязок шоссе);
##   Vegetation — слои VegetationLayer
##     (у слоёв деревьев модели — glTF из game/world/trees/models, набор задаётся tree_preset / tree_set);
##   Props — объекты из коллекции Props карты (tools/map_props.gd, docs/map-pipeline.md):
##     StaticBody3D с коробкой на слое 1 или Node3D, внутри — экземпляр модели «Model».
## Рельефа и воды в чанке нет: они общие на весь мир (WorldTerrain).
## Позиция корня = левый нижний угол чанка; содержимое — в локальных координатах 0..CHUNK_SIZE.

@export var coord: Vector2i = Vector2i.ZERO
