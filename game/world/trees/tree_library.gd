@tool
class_name TreeLibrary
extends RefCounted
## Библиотека мешей деревьев. Берёт меш из glTF-модели (её импортирует Godot),
## ставит на него общие материалы игры и кеширует: одна модель с одним цветом
## листвы — один меш на все чанки.
##
## В модели две поверхности: кора (материал bark) и листва (leaves). Цвета
## лежат в цветах вершин; цвет экземпляра MultiMesh на них умножается.

const MODELS_DIR := "res://game/world/trees/models/"

static var _cache: Dictionary = {} ## "путь|цвет" -> Mesh
static var _missing: Dictionary = {} ## пути, которые не удалось загрузить
static var _bark: StandardMaterial3D
static var _leaf_mats: Dictionary = {} ## цвет (html) -> StandardMaterial3D


## Меш модели по пути к glb/gltf с листвой, умноженной на leaf_tint.
## null — модель не найдена или ещё не импортирована редактором.
static func mesh_for(path: String, leaf_tint: Color = Color.WHITE) -> Mesh:
	if path.is_empty() or _missing.has(path):
		return null
	var key := path + "|" + leaf_tint.to_html(false)
	if _cache.has(key):
		return _cache[key] as Mesh
	var source := _load_mesh(path)
	if source == null:
		_missing[path] = true
		push_warning("TreeLibrary: не удалось загрузить модель дерева %s" % path)
		return null
	# Свой меш: импортированный ресурс не трогаем. Цвета вершин в glTF линейные,
	# а материал ждёт sRGB (vertex_color_is_srgb) — так цвет совпадает с Blender
	# во всех рендерерах, включая Compatibility.
	var mesh := ArrayMesh.new()
	for i in source.get_surface_count():
		var arrays := source.surface_get_arrays(i)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		for k in colors.size():
			colors[k] = colors[k].linear_to_srgb()
		if not colors.is_empty():
			arrays[Mesh.ARRAY_COLOR] = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat_name := ""
		var src_mat := source.surface_get_material(i)
		if src_mat != null:
			mat_name = src_mat.resource_name.to_lower()
		# Листва — материал leaves; если имён нет, считаем листвой вторую поверхность.
		var is_leaf := mat_name.contains("lea") or (mat_name.is_empty() and i > 0)
		mesh.surface_set_material(i, leaf_material(leaf_tint) if is_leaf else bark_material())
	_cache[key] = mesh
	return mesh


## Общий материал коры и ветвей.
static func bark_material() -> StandardMaterial3D:
	if _bark == null:
		_bark = StandardMaterial3D.new()
		_bark.vertex_color_use_as_albedo = true
		_bark.vertex_color_is_srgb = true
		_bark.roughness = 0.95
	return _bark


## Материал листвы с заданным цветом-множителем. Двусторонний: листья — плоские ромбы.
static func leaf_material(tint: Color = Color.WHITE) -> StandardMaterial3D:
	var key := tint.to_html(false)
	if not _leaf_mats.has(key):
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.albedo_color = tint
		m.roughness = 0.85
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_leaf_mats[key] = m
	return _leaf_mats[key] as StandardMaterial3D


## Сбросить кеш (например, после пересборки моделей в Blender).
static func clear_cache() -> void:
	_cache.clear()
	_missing.clear()


## Достаёт первый меш из импортированной glTF-сцены.
static func _load_mesh(path: String) -> Mesh:
	if not ResourceLoader.exists(path):
		return null
	var res := load(path)
	if res is Mesh:
		return res as Mesh
	var scene := res as PackedScene
	if scene == null:
		return null
	var root := scene.instantiate()
	var found := _find_mesh(root)
	root.free()
	return found


static func _find_mesh(node: Node) -> Mesh:
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		return mi.mesh
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null
