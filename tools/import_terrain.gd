extends SceneTree
## Разовый перенос рельефа карты из Blender в Terrain3D: читает высоты из
## art/map/export/heights.f32 (их пишет tools/blender/export_map.py) и создаёт
## базовый рельеф game/world/terrain/base и сцену правки terrain_edit.tscn.
##   godot --path . -s res://tools/import_terrain.gd -- --force
## ВНИМАНИЕ: затирает базовый рельеф вместе с правками кистями, поэтому без
## --force поверх существующего не пишет. После переноса рельеф правится в
## Godot, а высоты в map.blend игра больше не читает (docs/map-pipeline.md).
## Запускать с окном: текстуры рельефа в headless не создаются.

const TerrainAssets := preload("res://tools/terrain_assets.gd")
const RoadsPreview := preload("res://game/world/terrain/roads_preview.gd")
const EXPORT_DIR := "res://art/map/export/"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame # в _initialize дерево ещё не готово: Terrain3D не создаст data
	var base_abs := ProjectSettings.globalize_path(WorldTerrain.BASE_DIR)
	if DirAccess.dir_exists_absolute(base_abs) and not DirAccess.get_files_at(WorldTerrain.BASE_DIR).is_empty() \
			and not "--force" in OS.get_cmdline_user_args():
		push_error("Базовый рельеф уже есть (%s). Перезаписать: -- --force" % WorldTerrain.BASE_DIR)
		quit(1)
		return
	var map: Variant = JSON.parse_string(FileAccess.get_file_as_string(EXPORT_DIR + "map.json"))
	if not map is Dictionary:
		push_error("Нет art/map/export/map.json: сначала экспорт из Blender (tools/export_map.sh)")
		quit(1)
		return
	var gw := int(map["grid"][0])
	var gh := int(map["grid"][1])
	var step := float(map["grid_step"])
	var x0 := float(map["origin"][0])
	var z0 := float(map["origin"][1])
	var src := FileAccess.get_file_as_bytes(EXPORT_DIR + "heights.f32").to_float32_array()
	if src.size() != gw * gh:
		push_error("Размер heights.f32 не совпадает с сеткой")
		quit(1)
		return
	if not TerrainAssets.ensure():
		quit(1)
		return

	# Сетка Blender — узел на step метров, в Terrain3D — на метр: билинейно,
	# рельеф получается тем же, что был у мешей чанков.
	var w := int(round((gw - 1) * step))
	var h := int(round((gh - 1) * step))
	var dst := PackedFloat32Array()
	dst.resize(w * h)
	for pz in h:
		var fz := pz / step
		var iz := mini(floori(fz), gh - 2)
		var tz := fz - iz
		for px in w:
			var fx := px / step
			var ix := mini(floori(fx), gw - 2)
			var tx := fx - ix
			var a := lerpf(src[iz * gw + ix], src[iz * gw + ix + 1], tx)
			var b := lerpf(src[(iz + 1) * gw + ix], src[(iz + 1) * gw + ix + 1], tx)
			dst[pz * w + px] = lerpf(a, b, tz)
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RF, dst.to_byte_array())

	DirAccess.make_dir_recursive_absolute(base_abs)
	for f in DirAccess.get_files_at(WorldTerrain.BASE_DIR):
		DirAccess.remove_absolute(base_abs.path_join(f))

	var root := Node3D.new()
	root.name = "TerrainEdit"
	get_root().add_child(root)
	var terrain := WorldTerrain.create(WorldTerrain.BASE_DIR)
	root.add_child(terrain)
	terrain.owner = root
	terrain.data.import_images([img, null, null], Vector3(x0, 0.0, z0), 0.0, 1.0)
	terrain.data.save_directory(WorldTerrain.BASE_DIR)

	# Для ориентира в сцене правки: вода, солнце и оси дорог из прошлого запекания.
	var water := MeshInstance3D.new()
	water.name = "Water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(w, h)
	plane.material = load(WorldMaterials.DIR + "water.tres")
	water.mesh = plane
	water.position = Vector3(x0 + w * 0.5, WorldDefs.WATER_LEVEL, z0 + h * 0.5)
	root.add_child(water)
	water.owner = root
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	root.add_child(sun)
	sun.owner = root
	var roads := MeshInstance3D.new()
	roads.name = "RoadsPreview"
	roads.set_script(RoadsPreview)
	root.add_child(roads)
	roads.owner = root

	var scene := PackedScene.new()
	var err := scene.pack(root)
	if err == OK:
		err = ResourceSaver.save(scene, WorldTerrain.EDIT_SCENE)
	if err != OK:
		push_error("Не удалось сохранить сцену правки: %s" % error_string(err))
		quit(1)
		return
	print("Базовый рельеф: %d×%d м, регионов %d -> %s, сцена правки %s" % [w, h,
		terrain.data.get_region_count(), WorldTerrain.BASE_DIR, WorldTerrain.EDIT_SCENE])
	quit(0)
