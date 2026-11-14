# Генератор машин для игры. Запуск из корня проекта:
#   blender --background --python tools/blender/make_cars.py
# Результат — game/cars/models/:
#   car_<стиль>.glb — кузов без колёс (sport, sedan, van, racer);
#   wheel.glb       — колесо (шина, диск), ось вращения X, внешняя сторона +X.
# Стиль (docs/visual-style.md): машины гладкие и упрощённые — простые объёмы,
# сглаженные нормали, лак; жёсткие рёбра только по линиям кузова.
# Материалы по именам: paint, glass, trim, head, tail (кузов), tire, rim, trim (колесо).
# Цвета и параметры материалов ставит CarModel в Godot, здесь только имена.
#
# Кузов — «лофт»: вдоль машины стоят сечения, каждое задано несколькими числами
# (полуширина, низ, линия плеча, верх, ширина крыши). Сечения сшиваются в
# поверхность, стекло и стойки определяются по форме. Чтобы поменять машину,
# правь таблицу STYLES внизу и перезапусти скрипт.
# Blender: Z вверх, перед машины +Y; при экспорте glTF это становится -Z в Godot.

import math
import os

import bpy
import bmesh

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "game", "cars", "models")

# Должно совпадать с CarModel.gd (базовый размер, до CarStats.SCALE).
WHEEL_R = 0.36  # CarModel.WHEEL_RADIUS
WHEEL_W = 0.28
WHEEL_INSET_X = 0.12  # колесо от боковой грани кузова (wheel_positions)
AXLE_FROM_END = 0.75  # ось от торца кузова (wheel_positions)

ARCH_HALF_LEN = 0.52  # полудлина колёсной арки
ARCH_TOP = 2.0 * WHEEL_R + 0.07  # верх арки над землёй
STATIONS = 60  # сечений вдоль кузова

MATS = ["paint", "glass", "trim", "head", "tail", "tire", "rim"]
PREVIEW_COLORS = {
    "paint": (0.9, 0.35, 0.06), "glass": (0.03, 0.04, 0.05), "trim": (0.03, 0.03, 0.035),
    "head": (1.0, 0.95, 0.8), "tail": (0.6, 0.02, 0.02), "tire": (0.02, 0.02, 0.02), "rim": (0.7, 0.7, 0.72),
}


class Mesh:
    """Вершины и грани с индексом материала."""

    def __init__(self):
        self.verts = []
        self.faces = []
        self.fmat = []

    def vert(self, p):
        self.verts.append(tuple(p))
        return len(self.verts) - 1

    def face(self, idx, mat):
        self.faces.append(tuple(idx))
        self.fmat.append(MATS.index(mat))


# --- Примитивы --------------------------------------------------------------------


def box(m, center, size, mat, bevel=0.0):
    """Коробка; bevel > 0 — скошенные рёбра (для фар и мелочи)."""
    cx, cy, cz = center
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    if bevel <= 0.0:
        idx = [m.vert((cx + sx * hx, cy + sy * hy, cz + sz * hz))
               for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        for f in ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)):
            m.face([idx[i] for i in f], mat)
        return
    # Восьмиугольная призма вдоль Y: скруглённый прямоугольник в плоскости XZ.
    b = min(bevel, hx * 0.9, hz * 0.9)
    ring = [(hx, hz - b), (hx - b, hz), (-hx + b, hz), (-hx, hz - b),
            (-hx, -hz + b), (-hx + b, -hz), (hx - b, -hz), (hx, -hz + b)]
    back = [m.vert((cx + x, cy - hy, cz + z)) for x, z in ring]
    front = [m.vert((cx + x, cy + hy, cz + z)) for x, z in ring]
    n = len(ring)
    for i in range(n):
        j = (i + 1) % n
        m.face([back[i], back[j], front[j], front[i]], mat)
    m.face(list(reversed(back)), mat)
    m.face(front, mat)


def lathe(m, profile, segments, mat, x0=0.0):
    """Тело вращения вокруг оси X. profile — замкнутый контур [(радиус, x)]."""
    rings = []
    for s in range(segments):
        a = 2.0 * math.pi * s / segments
        ca, sa = math.cos(a), math.sin(a)
        rings.append([m.vert((x0 + x, r * ca, r * sa)) for r, x in profile])
    n = len(profile)
    for s in range(segments):
        r0 = rings[s]
        r1 = rings[(s + 1) % segments]
        for k in range(n):
            k1 = (k + 1) % n
            m.face([r0[k], r1[k], r1[k1], r0[k1]], mat)


def catmull(p0, p1, p2, p3, u):
    u2 = u * u
    return 0.5 * (2 * p1 + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2 + (3 * p1 - p0 - 3 * p2 + p3) * u2 * u)


def sample_keys(keys, t):
    """Значения сечения в точке t (0 — зад, 1 — перед), сплайн Catmull-Rom."""
    k = 0
    while k < len(keys) - 2 and t > keys[k + 1][0]:
        k += 1
    a, b = keys[k], keys[k + 1]
    u = 0.0 if b[0] == a[0] else min(max((t - a[0]) / (b[0] - a[0]), 0.0), 1.0)
    p0 = keys[max(k - 1, 0)]
    p3 = keys[min(k + 2, len(keys) - 1)]
    return [catmull(p0[i], a[i], b[i], p3[i], u) for i in range(1, len(a))]


# --- Кузов ------------------------------------------------------------------------


def arch_height(y, axles, zb):
    """Высота нижней кромки кузова над колесом (эллиптическая арка)."""
    za = zb
    for ay in axles:
        d = abs(y - ay) / ARCH_HALF_LEN
        if d < 1.0:
            za = max(za, zb + (ARCH_TOP - zb) * math.sqrt(1.0 - d * d))
    return za


def section(spec, t):
    """Полупрофиль сечения: точки (x, z) от центра низа к центру крыши."""
    w, h, l = spec["size"]
    hw_f, zb, zbelt, ztop, htop_f = sample_keys(spec["keys"], t)
    hw = hw_f * w / 2
    htop = htop_f * w / 2
    y = -l / 2 + t * l
    axles = (-l / 2 + AXLE_FROM_END, l / 2 - AXLE_FROM_END)
    za = arch_height(y, axles, zb)
    xo = hw * 0.96
    xi = min(w / 2 - WHEEL_INSET_X - WHEEL_W / 2 - 0.05, xo - 0.04)
    za = max(za, zb + 0.02)
    zl = max(zb + 0.2, za + 0.03)
    zbelt = max(zbelt, zl + 0.03)
    z7 = max(ztop - 0.25 * (ztop - zbelt), ztop - 0.05) if ztop > zbelt else ztop
    pts = [
        (0.0, zb),  # 0 низ, центр
        (xi, zb),  # 1 низ у арки
        (xi, za),  # 2 внутренняя стенка арки
        (xo, za),  # 3 нижняя кромка борта
        (hw, zl),  # 4 самая широкая точка
        (hw * 0.985, zbelt),  # 5 линия плеча
        (hw * 0.97 + (htop - hw * 0.97) * 0.45, zbelt + (ztop - zbelt) * 0.6),  # 6 середина стекла
        (htop, z7),  # 7 край крыши / капота
        (0.0, ztop),  # 8 крыша, центр
    ]
    return y, pts, (ztop - zbelt) > 0.14


def build_body(spec):
    m = Mesh()
    n = STATIONS
    ts = [i / (n - 1) for i in range(n)]
    rings = []
    info = []
    for t in ts:
        y, half, glassy = section(spec, t)
        # Кольцо: центр низа, правая сторона снизу вверх, центр крыши, левая сверху вниз.
        right = [(x, y, z) for x, z in half[1:8]]
        left = [(-x, y, z) for x, z in reversed(half[1:8])]
        ring = [(0.0, y, half[0][1])] + right + [(0.0, y, half[8][1])] + left
        rings.append([m.vert(p) for p in ring])
        info.append((y, half[8][1], glassy))
    ring_len = len(rings[0])  # 16
    seg_kind = ["trim", "trim", "trim", "paint", "paint", "side", "side", "top"]  # по полупрофилю
    pillars = spec.get("pillars", [])
    for i in range(n - 1):
        y0, top0, g0 = info[i]
        y1, top1, g1 = info[i + 1]
        slope = abs(top1 - top0) / max(y1 - y0, 1e-6)
        t0, t1 = ts[i], ts[i + 1]
        pillar = any(t0 <= p < t1 for p in pillars)
        for j in range(ring_len):
            j1 = (j + 1) % ring_len
            s = j if j < 8 else ring_len - 1 - j  # сегмент полупрофиля (зеркально)
            kind = seg_kind[s]
            if kind == "side":
                mat = ("trim" if pillar else "glass") if (g0 and g1) else "paint"
            elif kind == "top":
                mat = "glass" if (slope > 0.45 and (g0 or g1)) else "paint"
            else:
                mat = kind
            m.face([rings[i][j], rings[i + 1][j], rings[i + 1][j1], rings[i][j1]], mat)
    # Торцы: веер от центра.
    for ring in (rings[0], rings[-1]):
        cy = m.verts[ring[0]][1]
        cz = sum(m.verts[v][2] for v in ring) / len(ring)
        c = m.vert((0.0, cy, cz))
        for j in range(ring_len):
            m.face([c, ring[j], ring[(j + 1) % ring_len]], "paint")
    add_details(m, spec)
    return m


def add_details(m, spec):
    w, h, l = spec["size"]
    _, front, _ = section(spec, 1.0)
    _, rear, _ = section(spec, 0.0)
    fz_belt, fz_bot = front[5][1], front[0][1]
    rz_belt = rear[5][1]
    yf = l / 2
    yr = -l / 2
    # Фары и стопы — скруглённые плашки чуть впереди торца.
    for sx in (-1, 1):
        box(m, (sx * w * 0.31, yf + 0.004, fz_belt - 0.07), (w * 0.2, 0.05, 0.085), "head", bevel=0.03)
        box(m, (sx * w * 0.32, yr - 0.004, rz_belt - 0.06), (w * 0.22, 0.05, 0.075), "tail", bevel=0.025)
    # Решётка и задняя тёмная вставка.
    box(m, (0.0, yf + 0.002, fz_bot + 0.11), (w * 0.46, 0.04, 0.1), "trim", bevel=0.03)
    box(m, (0.0, yr - 0.002, rear[0][1] + 0.08), (w * 0.6, 0.04, 0.06), "trim", bevel=0.02)
    # Зеркала у основания лобового стекла.
    mt = spec["mirror_t"]
    my, mhalf, _ = section(spec, mt)
    for sx in (-1, 1):
        box(m, (sx * (mhalf[5][0] + 0.04), my, mhalf[5][1] + 0.09), (0.12, 0.08, 0.08), "paint", bevel=0.025)
    if spec.get("rear_window"):
        top = rear[8][1]
        box(m, (0.0, yr - 0.003, (rz_belt + top) / 2 + 0.05), (w * 0.72, 0.03, (top - rz_belt) * 0.6), "glass", bevel=0.05)
    if spec.get("spoiler"):
        st = 0.06
        sy, shalf, _ = section(spec, st)
        deck = shalf[8][1]
        box(m, (0.0, sy, deck + 0.2), (w * 0.92, 0.26, 0.04), "trim", bevel=0.015)
        for sx in (-1, 1):
            box(m, (sx * w * 0.3, sy, deck + 0.09), (0.05, 0.1, 0.2), "trim")


# --- Колесо -----------------------------------------------------------------------


def build_wheel():
    m = Mesh()
    r, hw = WHEEL_R, WHEEL_W / 2
    tire = [(0.25, -hw), (0.32, -hw), (r, -hw * 0.6), (r, hw * 0.6), (0.32, hw), (0.25, hw)]
    lathe(m, tire, 22, "tire")
    # Диск: тёмная чаша и светлые спицы со ступицей — видно вращение.
    dish = [(0.06, hw - 0.06), (0.235, hw - 0.04), (0.235, hw - 0.01), (0.06, hw - 0.03)]
    lathe(m, dish, 16, "trim")
    lip = [(0.215, hw - 0.012), (0.25, hw - 0.012), (0.25, hw + 0.004), (0.215, hw + 0.004)]
    lathe(m, lip, 22, "rim")
    hub = [(0.0001, hw - 0.04), (0.07, hw - 0.04), (0.07, hw + 0.002), (0.0001, hw + 0.002)]
    lathe(m, hub, 10, "rim")
    for k in range(5):
        a = 2.0 * math.pi * k / 5
        verts_before = len(m.verts)
        box(m, (0.0, 0.0, 0.0), (0.026, 0.05, 0.16), "rim")
        # Повернуть спицу: вдоль радиуса, на внешней стороне диска.
        ca, sa = math.cos(a), math.sin(a)
        for vi in range(verts_before, len(m.verts)):
            x, y, z = m.verts[vi]
            z += 0.14
            m.verts[vi] = (x + hw - 0.018, y * ca - z * sa, y * sa + z * ca)
    return m


# --- Blender ----------------------------------------------------------------------


def make_material(name):
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        mat.diffuse_color = PREVIEW_COLORS[name] + (1.0,)
    return mat


def to_object(name, m, z_shift=0.0):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(x, y, z + z_shift) for x, y, z in m.verts], [], m.faces)
    for mat in MATS:
        mesh.materials.append(make_material(mat))
    mesh.polygons.foreach_set("material_index", m.fmat)
    mesh.update()
    mesh.validate()
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.dissolve_degenerate(bm, dist=1e-5, edges=bm.edges)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    mesh.shade_smooth()
    mesh.set_sharp_from_angle(angle=math.radians(40.0))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    tris = sum(len(p.vertices) - 2 for p in mesh.polygons)
    xs = [v.co.x for v in mesh.vertices]
    ys = [v.co.y for v in mesh.vertices]
    zs = [v.co.z for v in mesh.vertices]
    print("CAR %-10s tris=%5d size=%.2f x %.2f x %.2f" % (name, tris, max(xs) - min(xs), max(zs) - min(zs), max(ys) - min(ys)))
    return obj


def export_glb(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=os.path.join(OUT_DIR, obj.name + ".glb"),
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_apply=False,
        export_materials="EXPORT",
        export_normals=True,
        export_texcoords=False,
        export_animations=False,
        export_skins=False,
        export_morph=False,
    )


# --- Таблица машин ----------------------------------------------------------------
# size — базовый размер кузова (Ш, В, Д), как CarStats.body_size для этого стиля.
# keys — сечения: (t, полуширина, низ, плечо, верх, ширина крыши).
#   t: 0 — зад, 1 — перед; полуширины — доли от w/2; высоты — метры от земли.
#   Где верх выше плеча больше чем на 0,14 м — стекло (окна); резкий подъём
#   верха — лобовое или заднее стекло.
# pillars — где поставить тёмную стойку в боковом стекле (t).
# mirror_t — где зеркала (основание лобового стекла).

SPORT_KEYS = [
    (0.00, 0.84, 0.34, 0.70, 0.74, 0.60),
    (0.04, 0.95, 0.26, 0.80, 0.84, 0.70),
    (0.14, 1.00, 0.22, 0.84, 0.88, 0.72),
    (0.26, 1.00, 0.22, 0.84, 0.92, 0.72),
    (0.42, 0.99, 0.22, 0.82, 1.24, 0.64),
    (0.56, 0.99, 0.22, 0.81, 1.30, 0.64),
    (0.68, 1.00, 0.22, 0.80, 0.92, 0.70),
    (0.82, 1.00, 0.22, 0.82, 0.80, 0.72),
    (0.96, 0.95, 0.26, 0.72, 0.72, 0.68),
    (1.00, 0.84, 0.32, 0.60, 0.62, 0.60),
]

STYLES = [
    {
        "name": "car_sport",
        "size": (1.9, 1.3, 4.3),
        "keys": SPORT_KEYS,
        "mirror_t": 0.67,
    },
    {
        "name": "car_racer",
        "size": (1.9, 1.3, 4.3),
        "keys": [(t, hw, zb - 0.04, belt, top - (0.04 if top > 1.0 else 0.0), ht) for t, hw, zb, belt, top, ht in SPORT_KEYS],
        "mirror_t": 0.67,
        "spoiler": True,
    },
    {
        "name": "car_sedan",
        "size": (1.9, 1.5, 4.5),
        "keys": [
            (0.00, 0.86, 0.34, 0.80, 0.84, 0.62),
            (0.04, 0.96, 0.26, 0.92, 0.96, 0.72),
            (0.14, 1.00, 0.22, 0.96, 1.00, 0.74),
            (0.24, 1.00, 0.22, 0.96, 1.02, 0.74),
            (0.34, 0.99, 0.22, 0.95, 1.44, 0.66),
            (0.58, 0.99, 0.22, 0.94, 1.50, 0.66),
            (0.70, 1.00, 0.22, 0.93, 1.00, 0.72),
            (0.84, 1.00, 0.22, 0.92, 0.92, 0.74),
            (0.96, 0.96, 0.26, 0.84, 0.84, 0.70),
            (1.00, 0.86, 0.32, 0.72, 0.74, 0.62),
        ],
        "pillars": [0.47],
        "mirror_t": 0.69,
    },
    {
        "name": "car_van",
        "size": (2.0, 2.0, 4.8),
        "keys": [
            (0.00, 0.92, 0.36, 0.95, 1.90, 0.80),
            (0.03, 0.99, 0.26, 1.00, 1.97, 0.86),
            (0.15, 1.00, 0.24, 1.02, 2.00, 0.88),
            (0.62, 1.00, 0.24, 1.02, 2.00, 0.88),
            (0.72, 1.00, 0.24, 1.00, 1.82, 0.86),
            (0.80, 1.00, 0.24, 0.98, 1.10, 0.80),
            (0.90, 1.00, 0.24, 0.96, 1.02, 0.78),
            (0.97, 0.96, 0.28, 0.90, 0.94, 0.74),
            (1.00, 0.86, 0.34, 0.80, 0.84, 0.66),
        ],
        "pillars": [0.30, 0.55],
        "rear_window": True,
        "mirror_t": 0.79,
    },
]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    objs = []
    for spec in STYLES:
        objs.append(to_object(spec["name"], build_body(spec), -spec["size"][1] / 2))
    objs.append(to_object("wheel", build_wheel()))
    for obj in objs:
        export_glb(obj)


main()
