extends RefCounted
## Строит исходные материалы дорог и воды и меши-заглушки мира для tools/bake_world.gd
## (текстуры и материал рельефа — tools/terrain_assets.gd).
## Результат сохраняется в game/world/assets/ и дальше правится в редакторе
## (например, можно подставить CC0-модели вместо примитивов).

var highway: StandardMaterial3D
var asphalt_plain: StandardMaterial3D
var dirt_road: StandardMaterial3D
var water: StandardMaterial3D

var rock_mesh: Mesh
var bush_mesh: Mesh



func _init() -> void:
	highway = _road_material(_asphalt_image(true))
	asphalt_plain = _road_material(_asphalt_image(false))
	asphalt_plain.uv1_triplanar = true
	asphalt_plain.uv1_scale = Vector3(0.1, 0.1, 0.1)
	dirt_road = _road_material(_dirt_image())
	dirt_road.roughness = 1.0

	water = StandardMaterial3D.new()
	water.albedo_color = Color(0.12, 0.26, 0.32, 0.82)
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.metallic = 0.3
	water.roughness = 0.08
	water.metallic_specular = 0.9

	_build_vegetation_meshes()


func _road_material(img: Image) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	img.generate_mipmaps()
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.roughness = 0.9
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _asphalt_image(markings: bool) -> Image:
	const W := 128
	const H := 256
	var img := Image.create(W, H, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.15
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for y in H:
		for x in W:
			var g := 0.2 + noise.get_noise_2d(x, y) * 0.03 + rng.randf() * 0.05
			var c := Color(g, g, g * 1.04)
			if markings:
				var u := float(x) / W
				var v := float(y) / H
				if (u > 0.035 and u < 0.06) or (u > 0.94 and u < 0.965):
					c = Color(0.82, 0.82, 0.8)
				elif absf(u - 0.5) < 0.012 and v < 0.4:
					c = Color(0.85, 0.72, 0.25)
			img.set_pixel(x, y, c)
	return img


func _dirt_image() -> Image:
	const W := 128
	const H := 256
	var img := Image.create(W, H, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.08
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for y in H:
		for x in W:
			var u := float(x) / W
			var g := 0.5 + noise.get_noise_2d(x, y) * 0.15 + rng.randf() * 0.08
			var track := 1.0 - 0.18 * (exp(-pow((u - 0.3) / 0.06, 2.0)) + exp(-pow((u - 0.7) / 0.06, 2.0)))
			var edge := smoothstep(0.0, 0.12, u) * smoothstep(1.0, 0.88, u)
			var dirt := Color(0.47, 0.38, 0.27) * g * track * 1.6
			var grass := Color(0.32, 0.38, 0.2) * g * 1.5
			img.set_pixel(x, y, grass.lerp(dirt, edge))
	return img


func _mat(color: Color, roughness: float = 0.9, instance_tint: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.vertex_color_use_as_albedo = instance_tint
	return m


## Камни и кусты. Деревья строятся процедурно (game/world/trees/), мешей-файлов у них нет.
func _build_vegetation_meshes() -> void:
	var rock := SphereMesh.new()
	rock.radius = 1.0
	rock.height = 1.6
	rock.radial_segments = 7
	rock.rings = 4
	rock.material = _mat(Color(0.47, 0.45, 0.42), 0.95, true)
	rock_mesh = rock

	var bush := SphereMesh.new()
	bush.radius = 0.9
	bush.height = 1.1
	bush.radial_segments = 8
	bush.rings = 4
	bush.material = _mat(Color(0.25, 0.40, 0.16), 0.9, true)
	bush_mesh = bush
