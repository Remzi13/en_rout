class_name WorldTerrain
extends RefCounted
## Рельеф мира на Terrain3D (addons/terrain_3d): где лежат данные и как
## собрать узел рельефа для игры, сцены обзора и сцены правки.
##
## Данных два набора (docs/map-pipeline.md):
##   BASE_DIR  — базовый рельеф без дорог. Его правят кистями Terrain3D в сцене
##               EDIT_SCENE; это источник высот карты.
##   BAKED_DIR — рельеф для игры: базовый + дороги (высоты и покрытие), песок у
##               воды, тёмная земля под лесом. Пишет запекание
##               (tools/export_map.sh), руками не правится.
## Текстуры и материал общие (ASSETS_PATH, MATERIAL_PATH), их создаёт
## tools/terrain_assets.gd, если файлов нет; дальше правятся в редакторе.

const DIR := "res://game/world/terrain/"
const BASE_DIR := DIR + "base"
const BAKED_DIR := DIR + "baked"
const ASSETS_PATH := DIR + "terrain_assets.res"
const MATERIAL_PATH := DIR + "terrain_material.res"
const EDIT_SCENE := DIR + "terrain_edit.tscn"

## Номера текстур рельефа в ASSETS_PATH.
const TEX_FIELD := 0
const TEX_ROCK := 1
const TEX_DIRT := 2
const TEX_ASPHALT := 3
const TEX_SAND := 4

const REGION_SIZE := 256 ## пикселей (и метров) на регион; равен WorldDefs.CHUNK_SIZE


## Узел рельефа с общими текстурами и материалом. Данные читаются из data_dir,
## когда узел попадает в дерево. Коллизия — на весь мир сразу: машины трафика
## и погони ездят далеко от камеры.
static func create(data_dir: String = BAKED_DIR) -> Terrain3D:
	var t := Terrain3D.new()
	t.name = "Terrain3D"
	t.region_size = Terrain3D.SIZE_256
	t.assets = load(ASSETS_PATH)
	t.material = load(MATERIAL_PATH)
	t.collision_mode = Terrain3DCollision.FULL_GAME
	t.collision_layer = WorldDefs.LAYER_WORLD
	t.collision_mask = 0
	t.data_directory = data_dir
	# Машина и ИИ узнают землю по мете "surface" у тела под лучом; само
	# покрытие в точке даёт surface_at().
	t.set_meta("surface", WorldDefs.Surface.GRASS)
	return t


## Вода: одна плоскость на весь мир на уровне WorldDefs.WATER_LEVEL (рельеф
## выше воды её закрывает).
static func make_water(rect: Rect2) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = rect.size
	plane.material = WorldMaterials.shared().water
	var water := MeshInstance3D.new()
	water.name = "Water"
	water.mesh = plane
	var c := rect.get_center()
	water.position = Vector3(c.x, WorldDefs.WATER_LEVEL, c.y)
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return water


## Покрытие рельефа в точке: по текстуре из карты покрытия (её рисует
## запекание под дорогами или кисть в редакторе).
static func surface_at(terrain: Terrain3D, pos: Vector3) -> int:
	var data := terrain.data
	if data.get_control_auto(pos):
		return WorldDefs.Surface.GRASS
	match data.get_control_base_id(pos):
		TEX_ASPHALT:
			return WorldDefs.Surface.ASPHALT
		TEX_DIRT:
			return WorldDefs.Surface.DIRT
	return WorldDefs.Surface.GRASS


## Высоты всех регионов из папки данных одной сеткой: 1 точка на метр, точка
## (0, 0) — в мировых (rect.position), размер — rect.size. Где региона нет — 0.
static func read_map(data_dir: String, map_type: int, rect: Rect2i) -> Image:
	var fmt := Image.FORMAT_RGBA8 if map_type == Terrain3DRegion.TYPE_COLOR else Image.FORMAT_RF
	var out := Image.create_empty(rect.size.x, rect.size.y, false, fmt)
	if map_type == Terrain3DRegion.TYPE_COLOR:
		out.fill(Color(1.0, 1.0, 1.0, 0.5)) # белый, шероховатость без поправки
	elif map_type == Terrain3DRegion.TYPE_CONTROL:
		out.fill(Color(Terrain3DUtil.as_float(Terrain3DUtil.enc_auto(true)), 0.0, 0.0))
	for file in DirAccess.get_files_at(data_dir):
		if not file.ends_with(".res"):
			continue
		var region := load(data_dir.path_join(file)) as Terrain3DRegion
		if region == null:
			continue
		var img := region.get_map(map_type)
		if img == null:
			continue
		if img.get_format() != fmt:
			img = img.duplicate()
			img.convert(fmt)
		var at := region.location * REGION_SIZE - rect.position
		out.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), at)
	return out
