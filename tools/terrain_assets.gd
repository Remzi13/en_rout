extends RefCounted
## Текстуры и материал рельефа Terrain3D (game/world/terrain/). Создаются один
## раз, если файлов нет (их зовут tools/bake_world.gd и tools/import_terrain.gd);
## дальше правятся в редакторе. Чтобы пересоздать — удалить terrain_assets.res
## и terrain_material.res.
##
## Текстуры без фототекстур (docs/visual-style.md): однотонный цвет с лёгким
## шумом и карта нормалей из того же шума — бугры видны светом, а не рисунком.
## Запускать с окном: в headless текстуры сохранятся пустыми.

const TEX_DIR := WorldTerrain.DIR + "textures/"
const TEX_SIZE := 256

# Палитра лета (docs/visual-style.md).
const C_FIELD := Color(0.45, 0.56, 0.24)
const C_ROCK := Color(0.45, 0.43, 0.40)
const C_DIRT := Color(0.40, 0.33, 0.24)
const C_ASPHALT := Color(0.21, 0.21, 0.22)
const C_SAND := Color(0.70, 0.64, 0.48)


## Создаёт недостающие файлы. Возвращает false, если сохранить не удалось.
static func ensure() -> bool:
	if ResourceLoader.exists(WorldTerrain.ASSETS_PATH) and ResourceLoader.exists(WorldTerrain.MATERIAL_PATH):
		return true
	if DisplayServer.get_name() == "headless":
		push_error("Текстуры рельефа создаются только с окном (без --headless)")
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEX_DIR))
	var assets := Terrain3DAssets.new()
	# Мягкие бугры поля, угловатые плиты скалы, мелкие кочки грунта.
	assets.set_texture_asset(WorldTerrain.TEX_FIELD, _texture_asset("Поле", "field", C_FIELD,
		{"jitter": 0.05, "seed": 1, "freq": 0.03, "bump": 3.0, "depth": 0.6, "uv": 0.1, "rough": 0.95}))
	assets.set_texture_asset(WorldTerrain.TEX_ROCK, _texture_asset("Скала", "rock", C_ROCK,
		{"jitter": 0.12, "seed": 2, "freq": 0.025, "bump": 10.0, "depth": 1.0, "uv": 0.06, "rough": 0.85, "cellular": true}))
	assets.set_texture_asset(WorldTerrain.TEX_DIRT, _texture_asset("Грунт", "dirt", C_DIRT,
		{"jitter": 0.08, "seed": 3, "freq": 0.05, "bump": 6.0, "depth": 0.8, "uv": 0.1, "rough": 1.0}))
	assets.set_texture_asset(WorldTerrain.TEX_ASPHALT, _texture_asset("Асфальт", "asphalt", C_ASPHALT,
		{"jitter": 0.03, "seed": 4, "freq": 0.2, "bump": 1.5, "depth": 0.4, "uv": 0.2, "rough": 0.8, "even": true}))
	assets.set_texture_asset(WorldTerrain.TEX_SAND, _texture_asset("Песок", "sand", C_SAND,
		{"jitter": 0.04, "seed": 5, "freq": 0.08, "bump": 2.0, "depth": 0.5, "uv": 0.1, "rough": 1.0}))
	if ResourceSaver.save(assets, WorldTerrain.ASSETS_PATH, ResourceSaver.FLAG_COMPRESS) != OK:
		push_error("Не удалось сохранить %s" % WorldTerrain.ASSETS_PATH)
		return false

	# Параметры шейдера материал принимает только у рельефа в дереве сцены.
	var host := Terrain3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(host)
	var mat := host.material
	# За краем карты — холмы из шума до горизонта (только картинка, без коллизии).
	mat.world_background = Terrain3DMaterial.NOISE
	mat.set_shader_param("ground_level", 0.0)
	mat.set_shader_param("world_noise_height", 40.0)
	mat.set_shader_param("world_noise_scale", 5.0)
	mat.set_shader_param("world_noise_max_octaves", 3) # дальний фон, детали не нужны
	# Скала сама ложится на склоны, остальное — поле. В Terrain3D base — текстура
	# склонов, overlay — ровных мест. Доля скалы 1 - 2·auto_slope·(1 - cos угла):
	# при 2.5 — наполовину на ~26°, целиком на ~37°. Склоны карты не круче ~35°.
	mat.auto_shader_enabled = true
	mat.set_shader_param("auto_slope", 2.5) # то же число — AUTO_SLOPE в tools/bake_world.gd
	mat.set_shader_param("auto_height_reduction", 0.0)
	mat.set_shader_param("auto_base_texture", WorldTerrain.TEX_ROCK)
	mat.set_shader_param("auto_overlay_texture", WorldTerrain.TEX_FIELD)
	mat.set_shader_param("blend_sharpness", 0.6)
	# Крупные пятна оттенка на сотни метров, чтобы поле не было однотонным.
	# Оба оттенка темнее белого на ~10%: приглушают зелень до палитры.
	mat.macro_variation_enabled = true
	mat.set_shader_param("noise_texture", _macro_noise())
	mat.set_shader_param("macro_variation1", Color(0.86, 0.9, 0.86))
	mat.set_shader_param("macro_variation2", Color(0.92, 0.88, 0.8))
	mat.set_shader_param("macro_variation_slope", 0.333)
	# Жёсткие грани, как у low-poly мира.
	mat.set_shader_param("flat_terrain_normals", true)
	var err := ResourceSaver.save(mat, WorldTerrain.MATERIAL_PATH, ResourceSaver.FLAG_COMPRESS)
	host.free()
	if err != OK:
		push_error("Не удалось сохранить %s" % WorldTerrain.MATERIAL_PATH)
		return false
	return true


## opt: jitter (разброс яркости), seed, freq (частота шума на пиксель),
## bump (крутизна бугров), depth (сила нормалей в Terrain3D), uv (повторов на
## метр), rough, cellular (угловатые плиты вместо мягких бугров), even (ровная
## высота смешивания, выше соседей: край покрытия ровный, без рваных языков).
## В альфе альбедо — высота для смешивания текстур, в альфе нормали — шероховатость.
static func _texture_asset(asset_name: String, file_key: String, base: Color, opt: Dictionary) -> Terrain3DTextureAsset:
	var noise := FastNoiseLite.new()
	noise.seed = opt["seed"]
	noise.frequency = opt["freq"]
	noise.fractal_octaves = 4
	if opt.get("cellular", false):
		noise.noise_type = FastNoiseLite.TYPE_CELLULAR
		noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
		noise.fractal_octaves = 2
	var h := _seamless_field(noise)
	var jitter: float = opt["jitter"]
	var bump: float = opt["bump"]
	var even_h: float = 0.9 if opt.get("even", false) else -1.0
	var alb := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var nrm := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var n := h[y * TEX_SIZE + x]
			var v := n * jitter
			alb.set_pixel(x, y, Color(base.r + v, base.g + v, base.b + v * 0.5, even_h if even_h >= 0.0 else 0.5 + n * 0.5))
			# Наклон по соседям (с переходом через край — текстура бесшовная).
			var dx := (_h_at(h, x + 1, y) - _h_at(h, x - 1, y)) * 0.5 * bump
			var dy := (_h_at(h, x, y + 1) - _h_at(h, x, y - 1)) * 0.5 * bump
			var nv := Vector3(-dx, dy, 1.0).normalized() # OpenGL: зелёный — вверх
			nrm.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5, opt["rough"]))
	alb.generate_mipmaps()
	nrm.generate_mipmaps()
	var ta := Terrain3DTextureAsset.new()
	ta.name = asset_name
	ta.albedo_texture = _save_texture(alb, file_key + "_albedo")
	ta.normal_texture = _save_texture(nrm, file_key + "_normal")
	ta.uv_scale = opt["uv"]
	ta.normal_depth = opt["depth"]
	return ta


## Шум для крупных пятен оттенка (macro variation): мягкие пятна 0..1.
static func _macro_noise() -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.012
	noise.fractal_octaves = 3
	var h := _seamless_field(noise)
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_L8)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var v := clampf(h[y * TEX_SIZE + x] * 0.9 + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(v, v, v))
	img.generate_mipmaps()
	return _save_texture(img, "macro_noise")


## Шум на квадрат TEX_SIZE, бесшовный: смесь четырёх сдвинутых копий.
static func _seamless_field(noise: FastNoiseLite) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(TEX_SIZE * TEX_SIZE)
	var s := float(TEX_SIZE)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var fx := x / s
			var fy := y / s
			var a := noise.get_noise_2d(x, y)
			var b := noise.get_noise_2d(x - s, y)
			var c := noise.get_noise_2d(x, y - s)
			var d := noise.get_noise_2d(x - s, y - s)
			out[y * TEX_SIZE + x] = lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)
	return out


static func _h_at(h: PackedFloat32Array, x: int, y: int) -> float:
	return h[posmod(y, TEX_SIZE) * TEX_SIZE + posmod(x, TEX_SIZE)]


## Текстура отдельным файлом: Terrain3D просит не хранить их внутри сцены.
static func _save_texture(img: Image, file_name: String) -> Texture2D:
	var path := TEX_DIR + file_name + ".res"
	ResourceSaver.save(ImageTexture.create_from_image(img), path, ResourceSaver.FLAG_COMPRESS)
	return load(path)
