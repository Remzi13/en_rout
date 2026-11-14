# Стартовая карта мира для правки в Blender. Запуск из корня проекта:
#   blender --background --python tools/blender/make_map.py
# Результат: art/map/map.blend. ВНИМАНИЕ: файл перезаписывается, ручные
# правки пропадут. Скрипт нужен один раз — дальше карта правится руками.
#
# Что в карте (имена важны для tools/blender/export_map.py):
#   Terrain      — рельеф (сетка 8 м), лепится кистями Sculpt. Группы вершин
#                  (Weight Paint): forest — густота леса, conifer — доля хвойных,
#                  rocks — камни и скальный цвет земли.
#   Roads        — коллекция дорог: кривые Безье, каждый сплайн — участок.
#                  Тип — свойство объекта road_type: "highway" или "dirt".
#                  Высота кривой не важна: дорогу кладёт на рельеф запекание.
#                  Концы дорог ближе 8 м сливаются в узел; конец рядом с
#                  серединой другой дороги — Т-перекрёсток.
#   PlayerStart  — пустышка: место старта, ось Y (зелёная) — направление.
#   Water_ref    — только для глаз: уровень воды (-4 м), не экспортируется.
#
# Оси: в Blender Z вверх; в Godot X тот же, Z_godot = -Y_blender.

import math
import os

import bpy
from mathutils import Vector, noise

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "art", "map", "map.blend")

HALF = 1024.0  # карта 2048 × 2048 м = 8 × 8 чанков по 256 м
STEP = 8.0  # шаг сетки рельефа в Blender
WATER_LEVEL = -4.0
LAKE = (-450.0, 380.0, 170.0)  # x, z (Godot), радиус
RIM_WIDTH = 180.0
RIM_HEIGHT = 55.0

# Дороги в координатах Godot (x, z). Кольцо — замкнутый сплайн.
ROADS = [
    ("Highway_Ring", "highway", True, [
        (-650, -620), (-200, -720), (250, -690), (660, -600), (740, -150), (700, 320),
        (620, 660), (150, 720), (-300, 700), (-660, 620), (-740, 150), (-720, -250),
    ]),
    ("Highway_Cross", "highway", False, [
        (-740, 150), (-400, 120), (-50, 40), (300, -60), (740, -150),
    ]),
    ("Dirt_Lake", "dirt", False, [(-50, 40), (-120, 250), (-250, 320)]),
    ("Dirt_South", "dirt", False, [(300, -60), (230, -330), (100, -520), (-200, -720)]),
    ("Dirt_Forest", "dirt", False, [(620, 660), (420, 480), (300, 300)]),
    ("Dirt_West", "dirt", False, [(-650, -620), (-450, -400), (-300, -200)]),
]
START = (-220.0, 85.0)  # рядом с поперечным шоссе, едем на восток


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def fbm(x, z, scale, octaves, seed):
    s = 0.0
    amp = 1.0
    freq = 1.0
    norm = 0.0
    for o in range(octaves):
        p = Vector((x * freq / scale + seed * 31.7 + o * 7.1, z * freq / scale - seed * 13.3, seed * 5.3 + o))
        s += amp * noise.noise(p, noise_basis="PERLIN_ORIGINAL")
        norm += amp
        amp *= 0.5
        freq *= 2.0
    return s / norm


def hills_weight(x, z):
    return smoothstep(0.02, 0.25, fbm(x, z, 1300.0, 2, 4))


def height(x, z):
    c = fbm(x, z, 1800.0, 3, 1)
    hw = hills_weight(x, z)
    h = 5.0 + c * 20.0 + fbm(x, z, 380.0, 4, 2) * (6.0 + 35.0 * hw) + fbm(x, z, 45.0, 2, 3) * 1.0
    d = HALF - max(abs(x), abs(z))
    k = 1.0 - smoothstep(0.0, RIM_WIDTH, d)
    h = h + (max(h, 0.0) + RIM_HEIGHT - h) * k * k
    lx, lz, lr = LAKE
    t = 1.0 - smoothstep(lr * 0.4, lr, math.hypot(x - lx, z - lz))
    return h + (-11.0 - h) * t


def masks(x, z, h):
    bio = fbm(x, z, 1300.0, 2, 4)
    hw = hills_weight(x, z)
    forest = smoothstep(-0.25, -0.05, bio) * (1.0 - smoothstep(0.15, 0.35, bio))
    forest = max(forest, 0.6 * smoothstep(0.05, 0.25, fbm(x, z, 260.0, 2, 6)))
    if h < WATER_LEVEL + 1.0:
        forest = 0.0
    conifer = 0.6 * smoothstep(8.0, 35.0, h) + 0.5 * hw + 0.3 * fbm(x, z, 300.0, 2, 7)
    rocks = 0.8 * hw + 0.5 * smoothstep(40.0, 70.0, h)
    clamp = lambda v: min(max(v, 0.0), 1.0)
    return clamp(forest), clamp(conifer), clamp(rocks)


def g2b(x, z, y=0.0):
    return Vector((x, -z, y))


def make_material(name, color):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    bsdf = mat.node_tree.nodes.get("Principled BSDF") if mat.node_tree else None
    if bsdf:
        bsdf.inputs["Base Color"].default_value = color
        bsdf.inputs["Roughness"].default_value = 0.9
    return mat


def make_terrain():
    n = int(HALF * 2 / STEP) + 1
    verts = []
    weights = []
    for j in range(n):
        z = -HALF + j * STEP
        for i in range(n):
            x = -HALF + i * STEP
            h = height(x, z)
            verts.append(g2b(x, z, h))
            weights.append(masks(x, z, h))
    faces = []
    for j in range(n - 1):
        for i in range(n - 1):
            a = j * n + i
            # Обход против часовой при взгляде сверху (Y Blender = -Z Godot).
            faces.append((a, a + n, a + n + 1, a + 1))
    me = bpy.data.meshes.new("Terrain")
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    for p in me.polygons:
        p.use_smooth = True
    obj = bpy.data.objects.new("Terrain", me)
    bpy.context.scene.collection.objects.link(obj)
    me.materials.append(make_material("Terrain", (0.32, 0.45, 0.2, 1.0)))
    for k, name in enumerate(("forest", "conifer", "rocks")):
        vg = obj.vertex_groups.new(name=name)
        by_w = {}
        for idx, w in enumerate(weights):
            q = round(w[k], 3)
            if q > 0.0:
                by_w.setdefault(q, []).append(idx)
        for q, ids in by_w.items():
            vg.add(ids, q, "REPLACE")
    return obj


def make_roads(terrain):
    coll = bpy.data.collections.new("Roads")
    bpy.context.scene.collection.children.link(coll)
    mats = {
        "highway": make_material("Road_highway", (0.15, 0.15, 0.16, 1.0)),
        "dirt": make_material("Road_dirt", (0.45, 0.33, 0.2, 1.0)),
    }
    for name, kind, cyclic, pts in ROADS:
        cu = bpy.data.curves.new(name, "CURVE")
        cu.dimensions = "3D"
        cu.bevel_depth = 3.0 if kind == "highway" else 2.0
        cu.bevel_resolution = 0
        sp = cu.splines.new("BEZIER")
        sp.bezier_points.add(len(pts) - 1)
        for bp, (x, z) in zip(sp.bezier_points, pts):
            bp.co = g2b(x, z, height(x, z) + 1.0)
            bp.handle_left_type = "AUTO"
            bp.handle_right_type = "AUTO"
        sp.use_cyclic_u = cyclic
        obj = bpy.data.objects.new(name, cu)
        obj["road_type"] = kind
        obj.data.materials.append(mats[kind])
        # Только для вида: кривая ложится на рельеф. На экспорт не влияет.
        sw = obj.modifiers.new("НаРельеф", "SHRINKWRAP")
        sw.target = terrain
        sw.wrap_method = "PROJECT"
        sw.use_project_z = True
        sw.use_negative_direction = True
        sw.use_positive_direction = True
        sw.offset = 0.5
        coll.objects.link(obj)


def make_start():
    x, z = START
    obj = bpy.data.objects.new("PlayerStart", None)
    obj.empty_display_type = "ARROWS"
    obj.empty_display_size = 12.0
    obj.location = g2b(x, z, height(x, z) + 2.0)
    obj.rotation_euler = (0.0, 0.0, -math.pi / 2)  # локальная Y -> +X (восток)
    bpy.context.scene.collection.objects.link(obj)


def make_water():
    s = HALF
    me = bpy.data.meshes.new("Water_ref")
    me.from_pydata([(-s, -s, WATER_LEVEL), (s, -s, WATER_LEVEL), (s, s, WATER_LEVEL), (-s, s, WATER_LEVEL)], [], [(0, 1, 2, 3)])
    obj = bpy.data.objects.new("Water_ref", me)
    mat = make_material("Water_ref", (0.1, 0.3, 0.55, 1.0))
    mat.diffuse_color = (0.1, 0.3, 0.55, 0.5)
    me.materials.append(mat)
    obj.display_type = "SOLID"
    obj.hide_select = True
    obj["note"] = "Уровень воды в игре (WorldDefs.WATER_LEVEL). Не экспортируется."
    bpy.context.scene.collection.objects.link(obj)


def setup_view():
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type != "VIEW_3D":
                continue
            for space in area.spaces:
                if space.type == "VIEW_3D":
                    space.clip_end = 10000.0
                    space.clip_start = 0.5
                    space.shading.color_type = "MATERIAL"


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    terrain = make_terrain()
    make_roads(terrain)
    make_start()
    make_water()
    setup_view()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=OUT, compress=True)
    print("Карта сохранена: %s" % OUT)


main()
