extends SceneTree
## Проба Terrain3D: переносит рельеф карты из Blender (art/map/export/heights.f32,
## его пишет tools/export_map.sh) в Terrain3D и собирает тестовую сцену
## game/terrain_test/terrain_test.tscn. Дальше рельеф правится кистями
## прямо в редакторе Godot (выделить узел Terrain3D).
## Дороги — часть рельефа: под осью каждой дороги из game/world/world_index.tres
## (профиль высот уже посчитан запеканием карты) рельеф выровнен по полотну и
## плавно сведён к земле, а покрытие нарисовано текстурой рельефа (асфальт,
## грунт). Юбок и площадок перекрёстков нет; ленту асфальта шоссе вровень с
## рельефом кладёт сцена (terrain_test.gd).
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
const C_ASPHALT := Color(0.21, 0.21, 0.22)
const TEX_DIRT := 2
const TEX_ASPHALT := 3
const ROAD_SHOULDER_M := 1.5 ## ровная обочина за краем покрытия
const ROAD_BLEND_M := 14.0 ## дальше рельеф плавно возвращается к своей высоте
const DECK_SINK_M := 0.1 ## рельеф под лентой шоссе ниже неё, чтобы не просвечивал
const DECK_SINK_INSET_M := 1.0 ## у кромки рельеф вровень с лентой
const HIGHWAY_WEIGHT := 30.0 ## на стыке высоту задаёт шоссе, грунтовка подстраивается


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

	var control := _stamp_roads(img, Vector2(float(origin[0]), float(origin[1])))

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
	# Мягкие бугры поля, угловатые плиты скалы, мелкие кочки грунта.
	terrain.assets.set_texture_asset(0, _texture_asset("Поле", "field", C_FIELD,
		{"jitter": 0.05, "seed": 1, "freq": 0.03, "bump": 3.0, "depth": 0.6, "uv": 0.1, "rough": 0.95}))
	terrain.assets.set_texture_asset(1, _texture_asset("Скала", "rock", C_ROCK,
		{"jitter": 0.12, "seed": 2, "freq": 0.025, "bump": 10.0, "depth": 1.0, "uv": 0.06, "rough": 0.85, "cellular": true}))
	terrain.assets.set_texture_asset(2, _texture_asset("Грунт", "dirt", C_DIRT,
		{"jitter": 0.08, "seed": 3, "freq": 0.05, "bump": 6.0, "depth": 0.8, "uv": 0.1, "rough": 1.0}))
	terrain.assets.set_texture_asset(TEX_ASPHALT, _texture_asset("Асфальт", "asphalt", C_ASPHALT,
		{"jitter": 0.03, "seed": 4, "freq": 0.2, "bump": 1.5, "depth": 0.4, "uv": 0.2, "rough": 0.8, "even": true}))
	ResourceSaver.save(terrain.assets, ASSETS_PATH, ResourceSaver.FLAG_COMPRESS)
	terrain.assets = load(ASSETS_PATH)

	var mat := terrain.material
	# За краем карты — холмы из шума до горизонта (только картинка, без коллизии).
	mat.world_background = Terrain3DMaterial.NOISE
	mat.set_shader_param("ground_level", 0.0)
	mat.set_shader_param("world_noise_height", 40.0)
	mat.set_shader_param("world_noise_scale", 5.0)
	mat.set_shader_param("world_noise_max_octaves", 3) # дальний фон, детали не нужны
	# Скала сама ложится на склоны, остальное — поле. Грунт — для кисти.
	# В Terrain3D base — текстура склонов, overlay — ровных мест. Доля скалы
	# 1 - 2·auto_slope·(1 - cos угла): при 2.5 — наполовину на ~26°, целиком на ~37°.
	# Склоны карты не круче ~35°, 90% площади положе 25°: скала только на крутых.
	mat.auto_shader_enabled = true
	mat.set_shader_param("auto_slope", 2.5)
	mat.set_shader_param("auto_height_reduction", 0.0)
	mat.set_shader_param("auto_base_texture", 1)
	mat.set_shader_param("auto_overlay_texture", 0)
	mat.set_shader_param("blend_sharpness", 0.6)
	# Крупные пятна оттенка на сотни метров, чтобы поле не было однотонным.
	# Оба оттенка темнее белого на ~10%: приглушают зелень до палитры.
	mat.macro_variation_enabled = true
	mat.set_shader_param("noise_texture", _macro_noise())
	mat.set_shader_param("macro_variation1", Color(0.86, 0.9, 0.86))
	mat.set_shader_param("macro_variation2", Color(0.92, 0.88, 0.8))
	mat.set_shader_param("macro_variation_slope", 0.333)
	# Жёсткие грани, как у low-poly мира (docs/visual-style.md).
	terrain.material.set_shader_param("flat_terrain_normals", true)

	terrain.data.import_images([img, control, null],
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


## Вдавливает дороги в карту высот img (1 пиксель = 1 м, угол в origin) и
## возвращает карту покрытия Terrain3D: на грунтовке — грунт, под лентой шоссе —
## асфальт, у его кромки и на обочине — грунт, везде вне дорог — автошейдер (поле и скала по склону).
## Высота у дороги — среднее по всем дорогам рядом с весом, быстро падающим
## от края полотна (у шоссе вес больше): на самом полотне это его профиль,
## а на стыке грунтовка плавно подходит к асфальту, без ступеньки.
func _stamp_roads(img: Image, origin: Vector2) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var hgt := img.get_data().to_float32_array()
	var edge := PackedFloat32Array() # расстояние до края ближайшего полотна
	edge.resize(w * h)
	edge.fill(INF)
	var sum_w := PackedFloat32Array()
	sum_w.resize(w * h)
	var sum_wy := PackedFloat32Array()
	sum_wy.resize(w * h)
	var road_tex := PackedByteArray() # покрытие: 0 — нет, иначе номер текстуры
	road_tex.resize(w * h)
	var under_deck := PackedByteArray() # пиксель под лентой шоссе, не у кромки
	under_deck.resize(w * h)
	var deck_y := PackedFloat32Array() # под лентой шоссе высота строго её, без смешения
	deck_y.resize(w * h)
	deck_y.fill(INF)
	# Ближайшая точка текущей дороги для каждого задетого пикселя.
	var cur_e := PackedFloat32Array()
	cur_e.resize(w * h)
	cur_e.fill(INF)
	var cur_y := PackedFloat32Array()
	cur_y.resize(w * h)
	var index: Resource = load("res://game/world/world_index.tres")
	var road_points: Array = index.get("road_points")
	var road_types: PackedInt32Array = index.get("road_types")
	for r in road_points.size():
		var pts: PackedVector3Array = road_points[r]
		var highway := road_types[r] == WorldDefs.RoadType.HIGHWAY
		var hw: float = WorldDefs.ROAD_WIDTHS[road_types[r]] * 0.5
		var reach := hw + ROAD_SHOULDER_M + ROAD_BLEND_M
		var touched := PackedInt32Array()
		for k in pts.size() - 1:
			var a := pts[k]
			var b := pts[k + 1]
			var ax := a.x - origin.x
			var az := a.z - origin.y
			var sx := b.x - a.x
			var sz := b.z - a.z
			var len2 := maxf(sx * sx + sz * sz, 0.0001)
			var x0 := maxi(floori(minf(ax, ax + sx) - reach), 0)
			var x1 := mini(ceili(maxf(ax, ax + sx) + reach), w - 1)
			var z0 := maxi(floori(minf(az, az + sz) - reach), 0)
			var z1 := mini(ceili(maxf(az, az + sz) + reach), h - 1)
			for pz in range(z0, z1 + 1):
				for px in range(x0, x1 + 1):
					var t := clampf(((px - ax) * sx + (pz - az) * sz) / len2, 0.0, 1.0)
					var dx := px - (ax + sx * t)
					var dz := pz - (az + sz * t)
					var e := sqrt(dx * dx + dz * dz) - hw
					var i := pz * w + px
					if e < cur_e[i] and e < ROAD_SHOULDER_M + ROAD_BLEND_M:
						if cur_e[i] == INF:
							touched.append(i)
						cur_e[i] = e
						cur_y[i] = lerpf(a.y, b.y, t)
		for i in touched:
			var e := cur_e[i]
			var wt := (HIGHWAY_WEIGHT if highway else 1.0) / pow(maxf(e, 0.0) + 0.3, 3.0)
			sum_w[i] += wt
			sum_wy[i] += wt * cur_y[i]
			edge[i] = minf(edge[i], e)
			if highway:
				if e <= 0.5:
					deck_y[i] = cur_y[i]
				# Асфальт рельефа — только под лентой (если она вдали мерцает, под
				# ней тот же цвет), у кромки и на обочине — грунт.
				if e <= -DECK_SINK_INSET_M:
					road_tex[i] = TEX_ASPHALT
					under_deck[i] = 1
				elif e <= ROAD_SHOULDER_M and road_tex[i] == 0:
					road_tex[i] = TEX_DIRT
			elif e <= 0.0 and road_tex[i] != TEX_ASPHALT:
				road_tex[i] = TEX_DIRT
			cur_e[i] = INF

	var ctrl := PackedFloat32Array()
	ctrl.resize(w * h)
	ctrl.fill(Terrain3DUtil.as_float(Terrain3DUtil.enc_auto(true)))
	for i in w * h:
		if sum_w[i] <= 0.0:
			continue
		var y := deck_y[i] if deck_y[i] != INF else sum_wy[i] / sum_w[i]
		hgt[i] = lerpf(y, hgt[i],
			smoothstep(ROAD_SHOULDER_M, ROAD_SHOULDER_M + ROAD_BLEND_M, edge[i]))
		if under_deck[i] == 1:
			hgt[i] -= DECK_SINK_M
		if road_tex[i] != 0:
			ctrl[i] = Terrain3DUtil.as_float(Terrain3DUtil.enc_base(road_tex[i]))
	img.set_data(w, h, false, Image.FORMAT_RF, hgt.to_byte_array())
	return Image.create_from_data(w, h, false, Image.FORMAT_RF, ctrl.to_byte_array())


## Текстура поверхности без фототекстур (docs/visual-style.md): однотонный
## цвет с лёгким шумом и карта нормалей из того же шума — бугры видны светом,
## а не рисунком. В альфе альбедо — высота для смешивания текстур, в альфе
## нормали — шероховатость.
## opt: jitter (разброс яркости), seed, freq (частота шума на пиксель),
## bump (крутизна бугров), depth (сила нормалей в Terrain3D), uv (повторов на
## метр), rough, cellular (угловатые плиты вместо мягких бугров), even (ровная
## высота смешивания, выше соседей: край покрытия ровный, без рваных языков).
func _texture_asset(asset_name: String, file_key: String, base: Color, opt: Dictionary) -> Terrain3DTextureAsset:
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
func _macro_noise() -> Texture2D:
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
func _seamless_field(noise: FastNoiseLite) -> PackedFloat32Array:
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


func _h_at(h: PackedFloat32Array, x: int, y: int) -> float:
	return h[posmod(y, TEX_SIZE) * TEX_SIZE + posmod(x, TEX_SIZE)]


## Текстура отдельным файлом: Terrain3D просит не хранить их внутри сцены.
func _save_texture(img: Image, file_name: String) -> Texture2D:
	var path := TEX_DIR + file_name + ".res"
	ResourceSaver.save(ImageTexture.create_from_image(img), path, ResourceSaver.FLAG_COMPRESS)
	return load(path)
