@tool
class_name WorldChunk
extends Node3D
## Корень сцены одного чанка (game/world/chunks/chunk_X_Z.tscn).
## Состав сцены:
##   Terrain / TerrainBody — рельеф и его коллизия (меш и форма в *.res рядом);
##   Roads — узлы RoadPath (дороги, правятся кривой), Junctions — RoadJunction;
##   Water — вода (если есть), Vegetation — слои VegetationLayer
##     (у слоёв деревьев модели — glTF из game/world/trees/models, набор задаётся tree_preset / tree_set);
##   Props — пусто, сюда можно ставить свои объекты (со своей коллизией на слое 1).
## Позиция корня = левый нижний угол чанка; содержимое — в локальных координатах 0..CHUNK_SIZE.

@export var coord: Vector2i = Vector2i.ZERO
