# Генератор деревьев для игры. Запуск из корня проекта:
#   blender --background --python tools/blender/make_trees.py -- [--no-render]
# Результат:
#   game/world/trees/models/<имя>.glb       — модель (LOD0), исходник для Godot;
#   game/world/trees/models/<имя>_lod.glb   — упрощённая модель для дальних чанков;
#   tools/blender/previews/*.png            — превью (рендер Cycles) для проверки глазами.
# В каждой модели два материала: bark (кора) и leaves (листва). Цвета лежат в
# цветах вершин (COLOR_0), материалы в Godot ставит TreeLibrary.
# Чтобы изменить или добавить дерево, правь таблицу MODELS внизу и перезапусти скрипт.
# Blender: Z вверх, метры; при экспорте glTF оси переводятся в Y вверх.

import math
import os
import random
import sys

import bpy
import bmesh
from mathutils import Vector, noise

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "game", "world", "trees", "models")
PREVIEW_DIR = os.path.join(ROOT, "tools", "blender", "previews")

BARK = 0
LEAVES = 1
UNDERGROUND = 0.4  # ствол уходит под землю: деревья стоят на склонах
UP = Vector((0.0, 0.0, 1.0))


# --- Накопитель геометрии ---------------------------------------------------------


class TreeMesh:
    """Собирает вершины, грани, материалы и цвета одного дерева."""

    def __init__(self, lod):
        self.lod = lod  # 0 — полная детализация, 1 — упрощённая
        self.verts = []
        self.cols = []  # sRGB-цвет на вершину
        self.faces = []
        self.fmat = []
        self.fsmooth = []

    def vert(self, p, col):
        self.verts.append(Vector(p))
        self.cols.append(col)
        return len(self.verts) - 1

    def face(self, idx, inside, mat, smooth):
        """Добавляет грань, ориентируя нормаль наружу от точки inside."""
        pts = [self.verts[i] for i in idx]
        n = Vector((0.0, 0.0, 0.0))
        for k in range(len(pts)):
            a = pts[k]
            b = pts[(k + 1) % len(pts)]
            n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)))
        if n.length < 1e-9:
            return
        center = sum(pts, Vector((0.0, 0.0, 0.0))) / len(pts)
        if n.dot(center - Vector(inside)) < 0.0:
            idx = list(reversed(idx))
        self.faces.append(tuple(idx))
        self.fmat.append(mat)
        self.fsmooth.append(smooth)


def mul(col, k):
    return (min(col[0] * k, 1.0), min(col[1] * k, 1.0), min(col[2] * k, 1.0))


def mix(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


def hdir(angle):
    return Vector((math.cos(angle), math.sin(angle), 0.0))


# --- Примитивы --------------------------------------------------------------------


def tube(m, pts, radii, sides, cols, cap=True, speckle=None):
    """Трубка (ствол, ветвь) по точкам pts с радиусами radii; cols — цвет на кольцо.
    speckle = (доля, цвет, Random) — тёмные отметины (берёза)."""
    n = len(pts)
    if n < 2:
        return
    if m.lod > 0:
        sides = max(3, sides - 2)
        if n > 3:  # через одну точку, концы сохраняем
            keep = sorted(set(list(range(0, n, 2)) + [n - 1]))
            pts = [pts[i] for i in keep]
            radii = [radii[i] for i in keep]
            cols = [cols[i] for i in keep]
            n = len(pts)
    tangents = []
    for i in range(n):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, n - 1)]
        tangents.append((b - a).normalized())
    ref = Vector((1.0, 0.0, 0.0)) if abs(tangents[0].x) < 0.8 else Vector((0.0, 1.0, 0.0))
    normal = tangents[0].cross(ref).normalized()
    rings = []
    for i in range(n):
        t = tangents[i]
        normal = (normal - t * normal.dot(t)).normalized()  # перенос рамки вдоль оси без скручивания
        binormal = t.cross(normal)
        ring = []
        for j in range(sides):
            a = math.tau * j / sides
            col = cols[i]
            if speckle is not None and speckle[2].random() < speckle[0]:
                col = speckle[1]
            ring.append(m.vert(pts[i] + (normal * math.cos(a) + binormal * math.sin(a)) * radii[i], col))
        rings.append(ring)
    for i in range(n - 1):
        inside = (pts[i] + pts[i + 1]) * 0.5
        for j in range(sides):
            j1 = (j + 1) % sides
            m.face([rings[i][j], rings[i][j1], rings[i + 1][j1], rings[i + 1][j]], inside, BARK, True)
    if cap:
        tip = m.vert(pts[-1] + tangents[-1] * radii[-1] * 1.2, cols[-1])
        for j in range(sides):
            m.face([rings[-1][j], rings[-1][(j + 1) % sides], tip], pts[-1] - tangents[-1] * 0.05, BARK, True)


_ICO_CACHE = {}


def ico(subdiv):
    """Единичная икосфера: (вершины, грани)."""
    if subdiv == 0 and 0 not in _ICO_CACHE:
        # Октаэдр — самое грубое ядро для дальних моделей.
        ov = [Vector(c) for c in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1))]
        of = [[0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4], [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5]]
        _ICO_CACHE[0] = (ov, of)
    if subdiv not in _ICO_CACHE:
        bm = bmesh.new()
        bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
        bm.verts.ensure_lookup_table()
        verts = [v.co.copy() for v in bm.verts]
        faces = [[v.index for v in f.verts] for f in bm.faces]
        bm.free()
        _ICO_CACHE[subdiv] = (verts, faces)
    return _ICO_CACHE[subdiv]


def blob(m, center, radii, col, rough=0.22, freq=1.6, mat=LEAVES, subdiv=None):
    """Объём листвы: икосфера, смятая шумом, с плоскими гранями.
    Низ темнее (тень внутри кроны), верх светлее. radii — полуоси (x, y, z)."""
    if subdiv is None:
        subdiv = 2 if m.lod == 0 else 1
    verts, faces = ico(subdiv)
    center = Vector(center)
    seed_off = Vector((center.x * 3.1 + 11.0, center.y * 2.7 - 5.0, center.z * 1.9 + 3.0))
    base = len(m.verts)
    for v in verts:
        k = 1.0 + rough * noise.noise(v * freq + seed_off) * 1.8
        z = v.z if v.z > 0.0 else v.z * 0.8  # низ чуть приплюснут
        p = center + Vector((v.x * radii[0] * k, v.y * radii[1] * k, z * radii[2] * (0.6 + 0.4 * k)))
        shade = 0.6 + 0.58 * (v.z * 0.5 + 0.5) + 0.1 * noise.noise(v * 3.0 + seed_off)
        m.vert(p, mul(col, shade))
    for f in faces:
        m.face([base + i for i in f], center, mat, False)


def tuft(m, center, radii, col, leaves=26, droop=0.0, rough=0.22):
    """Пучок листвы: тёмное ядро-объём и торчащие из него листья-ромбы.
    Листья дают рваный «лиственный» силуэт (ядро одно выглядит валуном).
    droop > 0 — листья свисают вниз (берёза), < 0 — тянутся вверх (сосна)."""
    center = Vector(center)
    rx, ry, rz = radii
    core = 0.8 if m.lod == 0 else 1.05
    blob(m, center, (rx * core, ry * core, rz * core), mul(col, 0.95), rough, subdiv=1 if m.lod == 0 else 0)
    # Свой генератор: число листьев зависит от LOD и не должно сбивать общий rng.
    lr = random.Random(int(center.x * 131.0) * 7919 + int(center.y * 137.0) * 104729 + int(center.z * 139.0))
    if m.lod > 0:
        leaves = max(5, leaves // 5)
    size_k = 1.0 if m.lod == 0 else 1.4
    r_mean = (rx + ry + rz) / 3.0
    for k in range(leaves):
        # Равномерные направления по сфере (спираль Фибоначчи), самый низ пропускаем.
        z = 1.0 - 1.55 * (k + 0.5) / leaves
        rad = math.sqrt(max(0.0, 1.0 - z * z))
        a = k * 2.399963 + lr.uniform(-0.25, 0.25)
        d = Vector((math.cos(a) * rad, math.sin(a) * rad, z))
        s = center + Vector((d.x * rx, d.y * ry, d.z * rz)) * 0.72
        jitter = Vector((lr.uniform(-1, 1), lr.uniform(-1, 1), lr.uniform(-1, 1))) * 0.45
        ldir = (d + jitter - UP * droop).normalized()
        length = r_mean * lr.uniform(0.5, 0.78) * size_k
        side = ldir.cross(Vector((lr.uniform(-1, 1), lr.uniform(-1, 1), lr.uniform(-1, 1))))
        if side.length < 1e-4:
            side = ldir.cross(UP)
        side = side.normalized() * length * 0.34
        tone = lr.uniform(0.85, 1.15) * (0.82 + 0.3 * (d.z * 0.5 + 0.5))
        v0 = m.vert(s, mul(col, tone * 0.72))
        v1 = m.vert(s + ldir * length * 0.45 + side, mul(col, tone))
        v2 = m.vert(s + ldir * length, mul(col, tone * 1.22))
        v3 = m.vert(s + ldir * length * 0.45 - side, mul(col, tone))
        m.face([v0, v1, v2], center, LEAVES, False)
        m.face([v0, v2, v3], center, LEAVES, False)


def skirt(m, axis_pt, z_bottom, z_apex, r, k_pts, droop, col, rng):
    """Ярус ели: «юбка» от оси вниз к зубчатому свисающему краю, снизу закрыта.
    axis_pt — точка оси на уровне яруса (x, y), k_pts — число лап."""
    rot = rng.random() * math.tau
    jit = [(rng.uniform(0.86, 1.12), rng.uniform(0.7, 1.25)) for _ in range(12)]
    if m.lod > 0:
        k_pts = max(5, k_pts - 3)
    count = k_pts * 2
    cx, cy = axis_pt.x, axis_pt.y
    apex = m.vert((cx, cy, z_apex), mul(col, 1.05))
    under = m.vert((cx, cy, z_bottom + (z_apex - z_bottom) * 0.22), mul(col, 0.42))
    mid = []
    rim = []
    for j in range(count):
        a = rot + math.tau * j / count
        tip = j % 2 == 0
        jr, jd = jit[(j // 2) % len(jit)]
        rr = r * jr if tip else r * 0.66
        zz = z_bottom - droop * jd if tip else z_bottom + droop * 0.55
        rim.append(m.vert((cx + math.cos(a) * rr, cy + math.sin(a) * rr, zz), mul(col, 1.22 if tip else 0.78)))
        if m.lod == 0:
            # Промежуточное кольцо: лапы выгибаются наружу, а не идут прямым конусом.
            mr = rr * 0.5
            mz = z_bottom + (z_apex - z_bottom) * 0.42 + (droop * 0.25 if tip else 0.0)
            mid.append(m.vert((cx + math.cos(a) * mr, cy + math.sin(a) * mr, mz), mul(col, 0.95 if tip else 0.7)))
    inside = Vector((cx, cy, z_bottom + (z_apex - z_bottom) * 0.3))
    for j in range(count):
        j1 = (j + 1) % count
        if m.lod == 0:
            m.face([apex, mid[j], mid[j1]], inside, LEAVES, False)
            m.face([mid[j], rim[j], mid[j1]], inside, LEAVES, False)
            m.face([mid[j1], rim[j], rim[j1]], inside, LEAVES, False)
        else:
            m.face([apex, rim[j], rim[j1]], inside, LEAVES, False)
        m.face([under, rim[j], rim[j1]], inside, LEAVES, False)


def limb_path(rng, start, direction, length, segs, wobble, up_pull):
    """Ломаная ветви: на каждом шаге направление слегка гуляет и тянется вверх."""
    pts = [Vector(start)]
    d = Vector(direction).normalized()
    step = length / segs
    for _ in range(segs):
        jitter = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))) * wobble
        d = (d + jitter + UP * up_pull).normalized()
        pts.append(pts[-1] + d * step)
    return pts


def lerp_list(a, b, n):
    return [a + (b - a) * i / (n - 1) for i in range(n)]


def trunk(m, rng, top_z, r, top_frac, lean, bend, segs, sides, col_low, col_high, flare=1.5, speckle=None):
    """Ствол с расширением у корней. Возвращает (точки, радиусы) без подземного кольца."""
    lean_v = hdir(rng.random() * math.tau) * lean
    bend_v = hdir(rng.random() * math.tau) * bend
    pts = [Vector((0.0, 0.0, -UNDERGROUND)), Vector((0.0, 0.0, 0.0))]
    radii = [r * flare * 1.15, r * flare]
    cols = [mul(col_low, 0.7), mul(col_low, 0.8)]
    for i in range(1, segs + 1):
        t = i / segs
        z = max(t * top_z, min(0.45, top_z * 0.1)) if i == 1 else t * top_z
        tt = z / top_z
        pts.append(Vector((0.0, 0.0, z)) + lean_v * tt + bend_v * math.sin(tt * math.pi * 0.9))
        radii.append(r * (1.0 + (top_frac - 1.0) * tt ** 0.8))
        cols.append(mix(col_low, col_high, tt))
    tube(m, pts, radii, sides, cols, speckle=speckle)
    return pts[1:], radii[1:]


def point_on(pts, t):
    """Точка ломаной по параметру t = 0..1 (по номерам точек)."""
    f = t * (len(pts) - 1)
    i = min(int(f), len(pts) - 2)
    return pts[i].lerp(pts[i + 1], f - i)


def value_on(vals, t):
    f = t * (len(vals) - 1)
    i = min(int(f), len(vals) - 2)
    return vals[i] + (vals[i + 1] - vals[i]) * (f - i)


def leaf_col(rng, col):
    k = rng.uniform(0.9, 1.1)
    return (col[0] * k * rng.uniform(0.92, 1.08), col[1] * k, col[2] * k * rng.uniform(0.9, 1.05))


# --- Виды -------------------------------------------------------------------------


def spruce(m, rng, P):
    """Ель: тонкий ствол и ярусы свисающих лап, сужающиеся к острой макушке."""
    h, r = P["h"], P["r"]
    bark = P["bark"]
    pts, _ = trunk(m, rng, h * 0.97, r, 0.08, h * 0.012, h * 0.008, 5, 7, bark, mul(bark, 0.9), flare=1.35)
    tiers = P["tiers"]
    z0 = h * P["crown_start"]
    width = h * P["width"]
    for i in range(tiers):
        t = i / (tiers - 1)
        zb = z0 + (h - z0) * (i / tiers) ** 0.95
        z_next = z0 + (h - z0) * ((i + 1) / tiers) ** 0.95
        tier_h = z_next - zb
        za = h if i == tiers - 1 else min(h, zb + tier_h * 2.1)
        rr = width * ((1.0 - t) ** 0.9 * 0.93 + 0.07) * rng.uniform(0.93, 1.07)
        axis = point_on(pts, min(zb / (h * 0.97), 1.0))
        col = mul(leaf_col(rng, P["leaf"]), 0.86 + 0.24 * t)
        skirt(m, axis, zb, za, rr, 9 if i < tiers - 2 else 7, tier_h * 0.55 + rr * 0.1, col, rng)


def pine(m, rng, P):
    """Сосна: высокий голый рыжеватый ствол, наверху ветви с плоскими шапками хвои."""
    h, r = P["h"], P["r"]
    bark = P["bark"]
    warm = (0.62, 0.36, 0.2)
    top_z = h * 0.86
    pts, radii = trunk(m, rng, top_z, r, 0.38, h * P["lean"], h * 0.035, 7, 7, bark, warm, flare=1.3)
    # Сухие сучки на голой части ствола.
    for _ in range(3):
        t = rng.uniform(0.3, 0.55)
        p = point_on(pts, t)
        d = hdir(rng.random() * math.tau) + UP * 0.4
        path = limb_path(rng, p, d, h * 0.07, 2, 0.1, 0.0)
        tube(m, path, lerp_list(value_on(radii, t) * 0.3, 0.02, 3), 4, [mul(bark, 0.7)] * 3)
    n = P["branches"]
    a0 = rng.random() * math.tau
    pad_r = h * 0.15 * P["width"]
    for i in range(n):
        t = 0.56 + 0.4 * i / (n - 1)
        p = point_on(pts, t)
        a = a0 + i * 2.4 + rng.uniform(-0.3, 0.3)
        length = h * 0.24 * P["width"] * (1.0 - 0.45 * (i / (n - 1))) * rng.uniform(0.85, 1.15)
        path = limb_path(rng, p, hdir(a) + UP * 0.25, length, 3, 0.08, 0.1)
        r0 = value_on(radii, t) * 0.5
        tube(m, path, lerp_list(r0, r0 * 0.3, 4), 5, [mul(warm, 0.75)] * 4)
        pr = pad_r * rng.uniform(0.85, 1.15) * (1.0 - 0.25 * (i / (n - 1)))
        tip = path[-1]
        tuft(m, tip + UP * pr * 0.15, (pr, pr * rng.uniform(0.8, 1.0), pr * 0.42), leaf_col(rng, P["leaf"]), 22, -0.5)
        # Вторая шапка ближе к стволу — крона не выглядит набором отдельных шаров.
        q = path[2]
        tuft(m, q + UP * pr * 0.3, (pr * 0.7, pr * 0.7, pr * 0.34), leaf_col(rng, P["leaf"]), 22, -0.5)
    top = pts[-1]
    pr = pad_r * 1.05
    tuft(m, Vector((top.x, top.y, h - pr * 0.5)), (pr, pr, pr * 0.5), leaf_col(rng, P["leaf"]), 22, -0.5)


def birch(m, rng, P):
    """Берёза: тонкий белый ствол с тёмными отметинами, лёгкая овальная крона."""
    h, r = P["h"], P["r"]
    bark = P["bark"]
    speck = (0.2, (0.1, 0.09, 0.08), random.Random(P["seed"] * 7 + 1))
    top_z = h * 0.93
    pts, radii = trunk(m, rng, top_z, r, 0.2, h * 0.025, h * P["bend"], 8, 7, mul(bark, 0.8), bark,
        flare=1.3, speckle=speck)
    dark = (0.22, 0.19, 0.16)
    n = P["branches"]
    a0 = rng.random() * math.tau
    lr = h * 0.085 * P["width"]
    for i in range(n):
        f = i / (n - 1)
        t = P["crown_start"] / 0.93 + (0.95 - P["crown_start"] / 0.93) * f
        p = point_on(pts, t)
        a = a0 + i * 2.4 + rng.uniform(-0.3, 0.3)
        length = h * 0.2 * P["width"] * (1.0 - 0.55 * f) * rng.uniform(0.85, 1.15)
        path = limb_path(rng, p, hdir(a) * 0.8 + UP * 0.75, length, 3, 0.1, 0.05)
        r0 = max(value_on(radii, t) * 0.42, 0.025)
        tube(m, path, lerp_list(r0, 0.015, 4), 4, [dark] * 4)
        rr = lr * rng.uniform(0.85, 1.2) * (1.0 - 0.2 * f)
        tip = path[-1]
        # Вытянутые вниз объёмы — плакучие ветви.
        tuft(m, tip - UP * rr * 0.45, (rr, rr, rr * 1.55), leaf_col(rng, P["leaf"]), 22, 0.9)
        if i % 2 == 0:
            q = path[2] + hdir(a + rng.uniform(-1.0, 1.0)) * rr * 0.5
            tuft(m, q - UP * rr * 0.2, (rr * 0.75, rr * 0.75, rr * 1.2), leaf_col(rng, P["leaf"]), 22, 0.9)
    top = pts[-1]
    rr = lr * 1.0
    tuft(m, Vector((top.x, top.y, h - rr * 1.4)), (rr, rr, rr * 1.4), leaf_col(rng, P["leaf"]), 22, 0.9)


def oak(m, rng, P):
    """Дуб: толстый ствол, расходящиеся сучья, широкая крона из многих объёмов."""
    h, r = P["h"], P["r"]
    bark = P["bark"]
    fork = h * P["crown_start"]
    pts, radii = trunk(m, rng, fork, r, 0.72, h * 0.02, h * 0.012, 4, 8, mul(bark, 0.85), bark, flare=1.6)
    base = pts[-1]
    lr = h * 0.17 * P["width"]
    n = P["branches"]
    a0 = rng.random() * math.tau
    for i in range(n):
        a = a0 + math.tau * i / n + rng.uniform(-0.35, 0.35)
        tilt = math.radians(rng.uniform(38.0, 58.0))
        d = hdir(a) * math.sin(tilt) + UP * math.cos(tilt)
        length = h * 0.34 * P["width"] * rng.uniform(0.85, 1.12)
        path = limb_path(rng, base - UP * rng.uniform(0.0, fork * 0.18), d, length, 4, 0.12, 0.1)
        r0 = radii[-1] * rng.uniform(0.5, 0.62)
        tube(m, path, lerp_list(r0, r0 * 0.3, 5), 5, [mul(bark, 0.92)] * 5)
        rr = lr * rng.uniform(0.9, 1.2)
        tuft(m, path[-1] + UP * rr * 0.25, (rr, rr * rng.uniform(0.85, 1.1), rr * 0.8), leaf_col(rng, P["leaf"]), 32, 0.15)
        # Боковая ветка от середины сука со своим объёмом.
        side = 1.0 if rng.random() < 0.5 else -1.0
        d2 = hdir(a + side * rng.uniform(0.7, 1.2)) * 0.8 + UP * 0.55
        sub = limb_path(rng, path[2], d2, length * 0.6, 3, 0.12, 0.08)
        tube(m, sub, lerp_list(r0 * 0.5, r0 * 0.15, 4), 4, [mul(bark, 0.88)] * 4)
        r2 = lr * rng.uniform(0.75, 0.95)
        tuft(m, sub[-1] + UP * r2 * 0.2, (r2, r2, r2 * 0.8), leaf_col(rng, P["leaf"]), 32, 0.15)
    # Центральный побег и макушка.
    lead = limb_path(rng, base, UP, h * 0.3, 3, 0.1, 0.1)
    tube(m, lead, lerp_list(radii[-1] * 0.6, radii[-1] * 0.2, 4), 5, [mul(bark, 0.92)] * 4)
    rt = lr * 1.25
    tuft(m, Vector((lead[-1].x, lead[-1].y, h - rt * 0.8)), (rt, rt, rt * 0.8), leaf_col(rng, P["leaf"]), 32, 0.15)
    # Заполнение середины кроны.
    for i in range(P["fill"]):
        a = rng.random() * math.tau
        rr = lr * rng.uniform(0.85, 1.05)
        c = Vector((base.x, base.y, rng.uniform(fork + h * 0.22, h - rt * 1.3))) + hdir(a) * h * rng.uniform(0.08, 0.2)
        tuft(m, c, (rr, rr, rr * 0.8), leaf_col(rng, P["leaf"]), 32, 0.15)


def poplar(m, rng, P):
    """Тополь: прямой ствол и узкая вытянутая крона-веретено почти от земли."""
    h, r = P["h"], P["r"]
    bark = P["bark"]
    pts, _ = trunk(m, rng, h * 0.9, r, 0.15, h * 0.01, h * 0.006, 5, 7, mul(bark, 0.85), bark, flare=1.3)
    n = P["tiers"]
    z0 = h * P["crown_start"]
    step = (h - z0) / (n + 0.25)
    rz = step * 0.78
    r_max = h * 0.105 * P["width"]
    a0 = rng.random() * math.tau
    for i in range(n):
        u = (i + 0.5) / n
        cz = z0 + (i + 0.5) * step + step * 0.12
        rr = r_max * math.sin(math.pi * (0.14 + 0.78 * u)) ** 0.6 * rng.uniform(0.93, 1.07)
        axis = point_on(pts, min(cz / (h * 0.9), 1.0))
        off = hdir(a0 + i * 2.4) * rr * 0.18
        col = mul(leaf_col(rng, P["leaf"]), 0.9 + 0.16 * u)
        tuft(m, Vector((axis.x, axis.y, cz)) + off, (rr, rr, rz), col, 26, -0.8)
        if i < n - 1:
            # Боковые пряди — силуэт не идеально гладкий.
            a = a0 + i * 2.4 + 2.0
            sr = rr * 0.55
            tuft(m, Vector((axis.x, axis.y, cz + step * 0.4)) + hdir(a) * rr * 0.7, (sr, sr, sr * 2.0),
                mul(leaf_col(rng, P["leaf"]), 0.9 + 0.16 * u), 14, -0.8)


def dead(m, rng, P):
    """Сухое дерево: ствол с обломанной вершиной и голые ветвящиеся сучья."""
    h, r = P["h"], P["r"]
    bark = P["bark"]
    top_z = h * 0.8
    pts, radii = trunk(m, rng, top_z, r, 0.4, h * 0.04, h * 0.04, 6, 7, mul(bark, 0.8), mul(bark, 1.08), flare=1.5)
    n = P["branches"]
    a0 = rng.random() * math.tau
    for i in range(n):
        f = i / (n - 1)
        t = 0.38 + 0.6 * f
        p = point_on(pts, t)
        a = a0 + i * 2.4 + rng.uniform(-0.4, 0.4)
        length = h * 0.3 * P["width"] * (1.0 - 0.4 * f) * rng.uniform(0.75, 1.2)
        up = rng.uniform(0.35, 0.9) if i < n - 1 else 2.5
        path = limb_path(rng, p, hdir(a) + UP * up, length, 4, 0.16, 0.06)
        r0 = value_on(radii, t) * 0.5
        col = mul(bark, rng.uniform(0.85, 1.05))
        tube(m, path, lerp_list(r0, r0 * 0.25, 5), 5, [col] * 5)
        for k in range(2):
            side = 1.0 if k == 0 else -1.0
            q = path[1 + k]
            d2 = hdir(a + side * rng.uniform(0.6, 1.2)) + UP * rng.uniform(0.3, 0.9)
            sub = limb_path(rng, q, d2, length * rng.uniform(0.4, 0.6), 3, 0.18, 0.05)
            tube(m, sub, lerp_list(r0 * 0.45, r0 * 0.12, 4), 4, [col] * 4)
            if m.lod == 0:
                tw = limb_path(rng, sub[2], d2 + hdir(a + side * 2.0), length * 0.2, 2, 0.15, 0.05)
                tube(m, tw, lerp_list(r0 * 0.2, r0 * 0.08, 3), 3, [col] * 3)
            else:
                limb_path(rng, sub[2], d2 + hdir(a + side * 2.0), length * 0.2, 2, 0.15, 0.05)


# --- Таблица моделей ----------------------------------------------------------------
# h — высота, r — радиус ствола на уровне земли (без корневого расширения), м.
# width — множитель ширины кроны, crown_start — доля высоты, где начинается крона.

BARK_BROWN = (0.36, 0.26, 0.18)
MODELS = [
    {"name": "spruce_a", "fn": spruce, "seed": 11, "h": 9.0, "r": 0.2, "tiers": 8, "width": 0.24,
        "crown_start": 0.16, "leaf": (0.13, 0.31, 0.18), "bark": (0.3, 0.22, 0.15)},
    {"name": "spruce_b", "fn": spruce, "seed": 12, "h": 10.5, "r": 0.21, "tiers": 9, "width": 0.19,
        "crown_start": 0.2, "leaf": (0.11, 0.27, 0.17), "bark": (0.3, 0.22, 0.15)},
    {"name": "pine_a", "fn": pine, "seed": 21, "h": 10.0, "r": 0.21, "branches": 5, "width": 1.0,
        "lean": 0.03, "leaf": (0.2, 0.37, 0.19), "bark": (0.42, 0.28, 0.18)},
    {"name": "pine_b", "fn": pine, "seed": 22, "h": 8.5, "r": 0.23, "branches": 6, "width": 1.2,
        "lean": 0.07, "leaf": (0.22, 0.39, 0.18), "bark": (0.42, 0.28, 0.18)},
    {"name": "birch_a", "fn": birch, "seed": 31, "h": 8.0, "r": 0.13, "branches": 8, "width": 1.0,
        "bend": 0.03, "crown_start": 0.36, "leaf": (0.42, 0.6, 0.2), "bark": (0.9, 0.89, 0.84)},
    {"name": "birch_b", "fn": birch, "seed": 32, "h": 9.0, "r": 0.14, "branches": 9, "width": 0.85,
        "bend": 0.05, "crown_start": 0.42, "leaf": (0.46, 0.62, 0.22), "bark": (0.9, 0.89, 0.84)},
    {"name": "oak_a", "fn": oak, "seed": 41, "h": 8.0, "r": 0.36, "branches": 4, "width": 1.0, "fill": 3,
        "crown_start": 0.34, "leaf": (0.24, 0.44, 0.15), "bark": (0.33, 0.25, 0.18)},
    {"name": "oak_b", "fn": oak, "seed": 42, "h": 7.0, "r": 0.4, "branches": 5, "width": 1.15, "fill": 2,
        "crown_start": 0.3, "leaf": (0.28, 0.46, 0.14), "bark": (0.33, 0.25, 0.18)},
    {"name": "poplar_a", "fn": poplar, "seed": 51, "h": 11.0, "r": 0.2, "tiers": 6, "width": 1.0,
        "crown_start": 0.15, "leaf": (0.3, 0.5, 0.2), "bark": (0.42, 0.38, 0.3)},
    {"name": "dead_a", "fn": dead, "seed": 61, "h": 6.5, "r": 0.22, "branches": 6, "width": 1.0,
        "leaf": (0.3, 0.3, 0.3), "bark": (0.46, 0.42, 0.37)},
]


# --- Blender: меш, материалы, экспорт, рендер ---------------------------------------


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def make_material(name):
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes.get("Principled BSDF")
    attr = nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    mat.node_tree.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.9
    return mat


def build_object(spec, lod):
    m = TreeMesh(lod)
    spec["fn"](m, random.Random(spec["seed"]), spec)
    name = spec["name"] + ("_lod" if lod else "")
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(v) for v in m.verts], [], m.faces)
    mesh.materials.append(make_material("bark"))
    mesh.materials.append(make_material("leaves"))
    mesh.polygons.foreach_set("material_index", m.fmat)
    mesh.polygons.foreach_set("use_smooth", m.fsmooth)
    attr = mesh.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    for loop in mesh.loops:
        c = m.cols[loop.vertex_index]
        attr.data[loop.index].color = (srgb_to_linear(c[0]), srgb_to_linear(c[1]), srgb_to_linear(c[2]), 1.0)
    mesh.color_attributes.active_color = attr
    mesh.color_attributes.render_color_index = 0
    mesh.update()
    mesh.validate()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    tris = sum(len(p.vertices) - 2 for p in mesh.polygons)
    zs = [v.z for v in m.verts]
    xs = [max(abs(v.x), abs(v.y)) for v in m.verts]
    print("TREE %-14s tris=%5d height=%.2f half_width=%.2f" % (name, tris, max(zs), max(xs)))
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
        export_vertex_color="MATERIAL",
        export_all_vertex_colors=False,
        export_normals=True,
        export_texcoords=False,
        export_animations=False,
        export_skins=False,
        export_morph=False,
    )


def setup_render(width, height):
    scene = bpy.context.scene
    try:
        scene.render.engine = "CYCLES"
        scene.cycles.samples = 24
        scene.cycles.device = "CPU"
    except Exception as e:  # нет Cycles — рендерим тем, что есть
        print("Cycles недоступен:", e)
    scene.render.resolution_x = width
    scene.render.resolution_y = height
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("Sky")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.5, 0.68, 0.9, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.9
    scene.world = world
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 3.2
    sun_obj = bpy.data.objects.new("Sun", sun)
    sun_obj.rotation_euler = (math.radians(52.0), 0.0, math.radians(35.0))
    scene.collection.objects.link(sun_obj)
    # Земля.
    bpy.ops.mesh.primitive_plane_add(size=8000.0)
    ground = bpy.context.active_object
    gm = bpy.data.materials.new("ground")
    gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.1, 0.16, 0.05, 1.0)
    ground.data.materials.append(gm)
    cam = bpy.data.cameras.new("Cam")
    cam_obj = bpy.data.objects.new("Cam", cam)
    scene.collection.objects.link(cam_obj)
    scene.camera = cam_obj
    return cam_obj


def aim(cam_obj, pos, target, lens):
    cam_obj.location = pos
    d = Vector(target) - Vector(pos)
    cam_obj.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    cam_obj.data.lens = lens


def car_box(x, y):
    """Коробка размером с машину игрока (для масштаба)."""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(x, y, 0.55))
    box = bpy.context.active_object
    box.scale = (3.3, 1.45, 1.0)
    cm = bpy.data.materials.new("car")
    cm.use_nodes = True
    cm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.8, 0.1, 0.08, 1.0)
    box.data.materials.append(cm)


def render(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    do_render = "--no-render" not in argv
    only = [a for a in argv if not a.startswith("--")]  # имена моделей для крупных планов
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    full = []
    low = []
    for spec in MODELS:
        full.append(build_object(spec, 0))
        low.append(build_object(spec, 1))
    for obj in full + low:
        export_glb(obj)
    if not do_render:
        return
    cam = setup_render(2400, 900)
    spacing = 10.5
    x0 = -spacing * (len(full) - 1) * 0.5
    for i in range(len(full)):
        full[i].location = (x0 + i * spacing, 0.0, 0.0)
        low[i].location = (x0 + i * spacing, 3000.0, 0.0)
    car_box(x0 - 7.0, -1.0)
    car_box(x0 - 7.0, 2999.0)
    width = spacing * (len(full) + 1)
    # Общий ряд: все модели и «машина» слева.
    aim(cam, (-3.0, -width * 0.95, 9.0), (-3.0, 0.0, 4.5), 35.0)
    render(os.path.join(PREVIEW_DIR, "all_lod0.png"))
    # Ряд упрощённых моделей.
    aim(cam, (-3.0, 3000.0 - width * 0.95, 9.0), (-3.0, 3000.0, 4.5), 35.0)
    render(os.path.join(PREVIEW_DIR, "all_lod1.png"))
    # Крупные планы по одной модели (вид с уровня дороги).
    bpy.context.scene.render.resolution_x = 700
    bpy.context.scene.render.resolution_y = 900
    for i in range(len(full)):
        if only and MODELS[i]["name"] not in only:
            continue
        x = full[i].location.x
        hgt = MODELS[i]["h"]
        aim(cam, (x + hgt * 0.5, -hgt * 1.75, 1.8), (x, 0.0, hgt * 0.5), 32.0)
        render(os.path.join(PREVIEW_DIR, MODELS[i]["name"] + ".png"))


main()
