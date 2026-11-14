extends SceneTree
## Проба Terrain3D: переносит рельеф карты из Blender (art/map/export/heights.f32,
## его пишет tools/export_map.sh) в Terrain3D и собирает тестовую сцену
## game/terrain_test/terrain_test.tscn. Дальше рельеф правится кистями
## прямо в редакторе Godot (выделить узел Terrain3D).
##   godot --path . -s res://tools/make_terrain_test.gd
## Запускать с окном: в headless текстуры сохранятся пустыми.
## Перезаписывает данные рельефа в game/terrain_test/data/.

const EXPORT_DIR := "res://art/map/export/"
const OUT_DIR := "res://game/terrain_test/"
const DATA_DIR := OUT_DIR + "data"
const SCENE_PATH := OUT_DIR + "terrain_test.tscn"
const ASSETS_PATH := OUT_DIR + "terrain_assets.res"
const SCRIPT_PATH := OUT_DIR + "terrain_test.gd"
const TEX_DIR := OUT_DIR + "textures/"
const TEX_SIZE := 256

# Палитра лета, как у рельефа в tools/bake_world.gd.
const C_FIELD := Color(0.45, 0.56, 0.24)
const C_ROCK := Color(0.45, 0.43, 0.40)
const C_DIRT := Color(0.40, 0.33, 0.24)


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame # в _initialize дерево ещё не готово: Terrain3D не создаст data и assets
	if DisplayServer.get_name() == "headless":
		push_warning("Запуск в headless: текстуры рельефа сохранятся пустыми. Запускайте с окном.")
	var map: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EXPORT_DIR + "map.json"))
	if map == null or map.is_empty():
		push_error("Нет art/map/export/map.json: сначала tools/export_map.sh")
		quit(1)
		return
	var grid: Array = map["grid"]
	var gw := int(grid[0])
	var gh := int(grid[1])
	var step := float(map["grid_step"])
	var origin: Array = map["origin"]
	var hgt := FileAccess.get_file_as_bytes(EXPORT_DIR + "heights.f32").to_float32_array()
	if hgt.size() != gw * gh:
		push_error("Размер heights.f32 не совпадает с сеткой")
		quit(1)
		return

	# Сетка Blender — 4 м между точками, в Terrain3D берём 1 м: растягиваем картинку.
	var img := Image.create_from_data(gw, gh, false, Image.FORMAT_RF, hgt.to_byte_array())
	var size_m := int(round((gw - 1) * step))
	img.resize(size_m, size_m, Image.INTERPOLATE_CUBIC)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA_DIR))
	for f in DirAccess.get_files_at(DATA_DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DATA_DIR + "/" + f))

	var root := Node3D.new()
	root.name = "TerrainTest"
	get_root().add_child(root)

	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
	root.add_child(terrain)
	terrain.owner = root
	terrain.data_directory = DATA_DIR

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEX_DIR))
	terrain.assets.set_texture_asset(0, _texture_asset("Поле", "field", C_FIELD, 0.05, 1))
	terrain.assets.set_texture_asset(1, _texture_asset("Скала", "rock", C_ROCK, 0.09, 2))
	terrain.assets.set_texture_asset(2, _texture_asset("Грунт", "dirt", C_DIRT, 0.07, 3))
	ResourceSaver.save(terrain.assets, ASSETS_PATH, ResourceSaver.FLAG_COMPRESS)
	terrain.assets = load(ASSETS_PATH)

	# Скала сама ложится на крутые склоны, остальное — поле. Грунт — для кисти.
	terrain.material.world_background = Terrain3DMaterial.NONE
	terrain.material.auto_shader_enabled = true
	# В Terrain3D base — текстура склонов, overlay — ровных мест. auto_slope 2:
	# скала проступает с ~30° и полностью закрывает склоны круче ~45°.
	terrain.material.set_shader_param("auto_slope", 2.0)
	terrain.material.set_shader_param("auto_height_reduction", 0.0)
	terrain.material.set_shader_param("auto_base_texture", 1)
	terrain.material.set_shader_param("auto_overlay_texture", 0)
	terrain.material.set_shader_param("blend_sharpness", 0.9)
	# Жёсткие грани, как у low-poly мира (docs/visual-style.md).
	terrain.material.set_shader_param("flat_terrain_normals", true)

	terrain.data.import_images([img, null, null],
		Vector3(float(origin[0]), 0.0, float(origin[1])), 0.0, 1.0)
	terrain.data.save_directory(DATA_DIR)

	# Скрипт сцены ставим перед сохранением, чтобы он не запустился здесь.
	root.set_script(load(SCRIPT_PATH))
	var scene := PackedScene.new()
	var err := scene.pack(root)
	if err == OK:
		err = ResourceSaver.save(scene, SCENE_PATH)
	if err != OK:
		push_error("Не удалось сохранить сцену: %s" % error_string(err))
		quit(1)
		return
	print("Terrain3D: %d×%d м, регионов %d -> %s" % [size_m, size_m,
		terrain.data.get_region_count(), SCENE_PATH])
	quit(0)


## Однотонная текстура с лёгким шумом (по стилю: без фототекстур).
## В альфе альбедо — высота для смешивания, в альфе нормали — шероховатость.
func _texture_asset(asset_name: String, file_key: String, base: Color, jitter: float, seed_value: int) -> Terrain3DTextureAsset:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.02
	var alb := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var nrm := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			# Бесшовный шум: среднее по четырём сдвинутым копиям.
			var n := _seamless(noise, x, y)
			var v := n * jitter
			alb.set_pixel(x, y, Color(base.r + v, base.g + v, base.b + v * 0.5, 0.5 + n * 0.5))
			nrm.set_pixel(x, y, Color(0.5, 0.5, 1.0, 0.95))
	alb.generate_mipmaps()
	nrm.generate_mipmaps()
	var ta := Terrain3DTextureAsset.new()
	ta.name = asset_name
	ta.albedo_texture = _save_texture(alb, file_key + "_albedo")
	ta.normal_texture = _save_texture(nrm, file_key + "_normal")
	ta.uv_scale = 0.1
	return ta


func _seamless(noise: FastNoiseLite, x: int, y: int) -> float:
	var s := float(TEX_SIZE)
	var fx := x / s
	var fy := y / s
	var a := noise.get_noise_2d(x, y)
	var b := noise.get_noise_2d(x - s, y)
	var c := noise.get_noise_2d(x, y - s)
	var d := noise.get_noise_2d(x - s, y - s)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)


## Текстура отдельным файлом: Terrain3D просит не хранить их внутри сцены.
func _save_texture(img: Image, file_name: String) -> Texture2D:
	var path := TEX_DIR + file_name + ".res"
	ResourceSaver.save(ImageTexture.create_from_image(img), path, ResourceSaver.FLAG_COMPRESS)
	return load(path)
