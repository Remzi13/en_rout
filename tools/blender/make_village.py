# Генератор построек рыбацкой деревни. Запуск из корня проекта:
#   blender --background --python tools/blender/make_village.py
# Результат — game/world/models/village/<имя>.glb. Превью в игре:
#   godot --path . -s res://tools/preview_village.gd -- [файл.png] [угол°]
#
# Стиль (docs/visual-style.md): матовый low-poly, жёсткие грани, простые объёмы,
# без текстур. Цвет — в общих материалах по именам (таблица MATS): одинаковые
# имена во всех моделях, roughness 0,9, без металла.
#
# Масштаб (docs/scale.md): машины уменьшены до 60 %, постройки тоже — все размеры
# ниже это «реальные» × S = 0,6. Дверь 0,55 × 1,2 м, окно 0,5 × 0,55 м, этаж ~1,8 м,
# цоколь 0,3 м. Машина игрока для сравнения — 2,6 × 1,1 × 0,8 м.
#
# Оси: Blender, Z вверх, метры. Фасад (вход) смотрит в +Y Blender — как перед
# машины; в Godot это −Z. Начало координат — в основании модели по центру
# (X = 0, Y = 0, низ цоколя Z = 0). Исключения:
#   pier — начало у берегового конца по центру ширины, Z = 0 — уровень берега;
#          настил на +0,3, причал уходит в −Y на 20 м, низ свай на Z = −4.
#          Ставить без snap_to_ground, на высоту берега у воды.
#   boat — Z = 0 — ватерлиния (днище на −0,15). На воду ставить на высоту воды −4.
#
# Габариты (Ш по X × Г по Y × В по Z), метры:
#   house_a     5,0 × 4,0 × 3,9   дом, конёк вдоль фасада, красные стены, труба
#   house_b     4,2 × 6,0 × 4,3   дом, щипец к фасаду, синие стены, крыльцо с навесом
#   smokehouse  3,0 × 3,2 × 3,5   коптильня, тёмное дерево, каменная труба
#   net_shed    4,8 × 6,9 × 3,5   склад сетей / лодочный сарай, широкие ворота
#   shop        4,6 × 4,8 × 3,7   лавка, охристые стены, навес и вывеска
#   pier        2,3 × 20,0 × 4,8  причал на сваях (настил +0,3, сваи до −4)
#   boat        1,1 × 3,2 × 0,7   лодка с банками и вёслами
#   net_rack    3,0 × 0,4 × 1,6   вешала с сетью
# Все модели — до 600 треугольников.
# Точные габариты печатает скрипт (строки VILLAGE ...).
# Чтобы поменять модель, правь её функцию внизу и перезапусти скрипт.

import math
import os

import bpy
import bmesh
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "game", "world", "models", "village")

# Общие материалы: имя → цвет sRGB. Природные и деревянные тона приглушённые.
MATS = {
    "wood": (0.47, 0.43, 0.38),  # выцветшее серое дерево
    "wood_dark": (0.30, 0.25, 0.20),  # тёмное, просмолённое дерево
    "wall_red": (0.55, 0.25, 0.20),  # «фалунская» красная краска
    "wall_blue": (0.36, 0.47, 0.56),  # выцветшая синяя
    "wall_ochre": (0.74, 0.60, 0.36),  # охра
    "trim": (0.85, 0.82, 0.75),  # белёные наличники и углы
    "roof": (0.22, 0.22, 0.24),  # тёмная крыша
    "roof_brown": (0.30, 0.24, 0.20),  # тёмно-коричневая крыша
    "window": (0.12, 0.15, 0.18),  # тёмное стекло (матовое, как всё в мире)
    "stone": (0.45, 0.43, 0.40),  # цоколь и труба, «камень» из палитры
    "net": (0.30, 0.34, 0.30),  # сеть
    "float": (0.75, 0.45, 0.22),  # поплавки, приглушённый оранжевый
    "awning": (0.60, 0.30, 0.24),  # навес лавки
}

S = 0.6  # масштаб относительно реальных размеров (как CarStats.SCALE)
PLINTH_H = 0.3  # цоколь
DOOR_W = 0.55
DOOR_H = 1.2
WIN_W = 0.5
WIN_H = 0.55
WIN_Z = PLINTH_H + 0.85  # центр окна над землёй


class Mesh:
    """Вершины и грани с материалом; грани ориентируются наружу от точки inside."""

    def __init__(self):
        self.verts = []
        self.faces = []
        self.fmat = []

    def vert(self, p):
        self.verts.append(Vector(p))
        return len(self.verts) - 1

    def face(self, idx, inside, mat, toward=False):
        pts = [self.verts[i] for i in idx]
        n = Vector((0.0, 0.0, 0.0))
        for k in range(len(pts)):
            a = pts[k]
            b = pts[(k + 1) % len(pts)]
            n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)))
        if n.length < 1e-9:
            return
        c = sum(pts, Vector((0.0, 0.0, 0.0))) / len(pts)
        outward = n.dot(c - Vector(inside)) >= 0.0
        if outward == toward:
            idx = list(reversed(idx))
        self.faces.append(tuple(idx))
        self.fmat.append(mat)


# --- Примитивы (все выпуклые) -------------------------------------------------------


def box(m, x0, x1, y0, y1, z0, z1, mat):
    """Коробка по границам."""
    xs, ys, zs = sorted((x0, x1)), sorted((y0, y1)), sorted((z0, z1))
    v = [m.vert((x, y, z)) for x in xs for y in ys for z in zs]
    c = ((xs[0] + xs[1]) / 2, (ys[0] + ys[1]) / 2, (zs[0] + zs[1]) / 2)
    for f in ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)):
        m.face([v[i] for i in f], c, mat)


def cbox(m, cx, cy, cz, sx, sy, sz, mat):
    """Коробка по центру низа (cz — низ) и размеру."""
    box(m, cx - sx / 2, cx + sx / 2, cy - sy / 2, cy + sy / 2, cz, cz + sz, mat)


def prism(m, poly, a0, a1, axis, mat):
    """Выпуклый многоугольник, вытянутый вдоль оси.
    axis 'x': poly — точки (y, z); axis 'y': poly — точки (x, z)."""

    def p3(p, a):
        return (a, p[0], p[1]) if axis == "x" else (p[0], a, p[1])

    r0 = [m.vert(p3(p, a0)) for p in poly]
    r1 = [m.vert(p3(p, a1)) for p in poly]
    cu = sum(p[0] for p in poly) / len(poly)
    cv = sum(p[1] for p in poly) / len(poly)
    c = p3((cu, cv), (a0 + a1) / 2)
    n = len(poly)
    for i in range(n):
        j = (i + 1) % n
        m.face([r0[i], r0[j], r1[j], r1[i]], c, mat)
    m.face(r0, c, mat)
    m.face(r1, c, mat)


def post(m, x, y, z0, z1, size, mat):
    cbox(m, x, y, z0, size, size, z1 - z0, mat)


# --- Детали фасада ------------------------------------------------------------------
# side: '+y' (фасад), '-y', '+x', '-x'; u — координата вдоль стены (X для ±y, Y для ±x);
# wall — координата плоскости стены (y или x).


def on_wall(m, side, wall, u, w, z0, z1, depth, mat):
    """Плашка на стене: от плоскости стены наружу на depth."""
    s = 1.0 if side[0] == "+" else -1.0
    a0, a1 = wall - s * 0.01, wall + s * depth
    if side[1] == "y":
        box(m, u - w / 2, u + w / 2, a0, a1, z0, z1, mat)
    else:
        box(m, a0, a1, u - w / 2, u + w / 2, z0, z1, mat)


def window(m, side, wall, u, zc=WIN_Z, w=WIN_W, h=WIN_H, frame="trim", shutters=None):
    on_wall(m, side, wall, u, w + 0.1, zc - h / 2 - 0.06, zc + h / 2 + 0.05, 0.03, frame)
    on_wall(m, side, wall, u, w, zc - h / 2, zc + h / 2, 0.045, "window")
    on_wall(m, side, wall, u, w + 0.16, zc - h / 2 - 0.1, zc - h / 2 - 0.04, 0.07, frame)  # отлив
    if shutters:
        for k in (-1, 1):
            on_wall(m, side, wall, u + k * (w / 2 + 0.17), w * 0.5, zc - h / 2, zc + h / 2, 0.04, shutters)


def door(m, side, wall, u, w=DOOR_W, h=DOOR_H, mat="wood_dark", frame="trim"):
    z0 = PLINTH_H
    on_wall(m, side, wall, u, w + 0.12, z0, z0 + h + 0.07, 0.03, frame)
    on_wall(m, side, wall, u, w, z0, z0 + h, 0.05, mat)
    # ступенька
    s = 1.0 if side[0] == "+" else -1.0
    if side[1] == "y":
        box(m, u - w / 2 - 0.1, u + w / 2 + 0.1, wall, wall + s * 0.35, 0.0, z0 - 0.12, "stone")
    else:
        box(m, wall, wall + s * 0.35, u - w / 2 - 0.1, u + w / 2 + 0.1, 0.0, z0 - 0.12, "stone")


# --- Корпус дома --------------------------------------------------------------------


def shell(m, w, d, wall_h, roof_h, ridge, wall_mat, roof_mat, oh=0.25, gable_oh=0.2, corners="trim"):
    """Цоколь, стены с фронтонами и двускатная крыша.
    ridge 'x' — конёк вдоль фасада, 'y' — щипец (фронтон) к фасаду.
    Возвращает функцию высоты низа крыши на стене (для труб и т. п.)."""
    hw, hd = w / 2, d / 2
    box(m, -hw - 0.04, hw + 0.04, -hd - 0.04, hd + 0.04, 0.0, PLINTH_H, "stone")
    zr = wall_h + roof_h
    if ridge == "x":
        span, length = hd, hw
        wall_poly = [(-hd, PLINTH_H - 0.02), (hd, PLINTH_H - 0.02), (hd, wall_h), (0.0, zr), (-hd, wall_h)]
        prism(m, wall_poly, -hw, hw, "x", wall_mat)
    else:
        span, length = hw, hd
        wall_poly = [(-hw, PLINTH_H - 0.02), (hw, PLINTH_H - 0.02), (hw, wall_h), (0.0, zr), (-hw, wall_h)]
        prism(m, wall_poly, -hd, hd, "y", wall_mat)
    k = roof_h / span
    t = 0.12  # толщина ската
    e = span + oh
    ze = wall_h - k * oh
    for sgn in (-1, 1):
        poly = [(sgn * e, ze), (0.0, zr), (0.0, zr + t * 1.4), (sgn * e, ze + t)]
        if sgn < 0:
            poly = list(reversed(poly))
        prism(m, poly, -length - gable_oh, length + gable_oh, ridge, roof_mat)
    # белёные углы
    if corners:
        for sx in (-1, 1):
            for sy in (-1, 1):
                cbox(m, sx * (hw - 0.03), sy * (hd - 0.03), PLINTH_H, 0.1, 0.1, wall_h - PLINTH_H - 0.02, corners)

    def roof_z(off):
        """Высота нижней поверхности ската на расстоянии off от конька (поперёк)."""
        return zr - k * abs(off)

    return roof_z


def chimney(m, roof_z, x, y, ridge, top, size=0.32, mat="stone"):
    off = y if ridge == "x" else x
    z0 = roof_z(abs(off) + size / 2) - 0.05
    cbox(m, x, y, z0, size, size, top - z0, mat)
    cbox(m, x, y, top, size + 0.08, size + 0.08, 0.06, mat)


# --- Модели -------------------------------------------------------------------------


def house_a(m):
    """Дом с коньком вдоль фасада: красные стены, белые наличники, труба."""
    w, d, wall_h, roof_h = 4.6, 3.4, 1.95, 1.35
    roof_z = shell(m, w, d, wall_h, roof_h, "x", "wall_red", "roof")
    hd, hw = d / 2, w / 2
    door(m, "+y", hd, -0.55)
    window(m, "+y", hd, 0.55)
    window(m, "+y", hd, 1.5)
    window(m, "+y", hd, -1.5)
    window(m, "-y", -hd, -1.0)
    window(m, "-y", -hd, 1.0)
    window(m, "+x", hw, 0.0)
    window(m, "-x", -hw, 0.0)
    window(m, "+x", hw, 0.0, zc=wall_h + 0.45, w=0.36, h=0.38)  # чердак
    chimney(m, roof_z, 1.1, -0.35, "x", wall_h + roof_h + 0.55)


def house_b(m):
    """Дом щипцом к фасаду: синие стены, крыльцо с навесом, ставни."""
    w, d, wall_h, roof_h = 3.8, 4.6, 2.0, 1.75
    roof_z = shell(m, w, d, wall_h, roof_h, "y", "wall_blue", "roof_brown", oh=0.22, gable_oh=0.28)
    hd, hw = d / 2, w / 2
    door(m, "+y", hd, 0.75)
    window(m, "+y", hd, -0.75, shutters="wall_red")
    window(m, "+y", hd, 0.0, zc=wall_h + 0.5, w=0.42, h=0.48)  # окно во фронтоне
    for y in (-1.2, 1.0):
        window(m, "+x", hw, y, shutters="wall_red")
        window(m, "-x", -hw, y, shutters="wall_red")
    window(m, "-y", -hd, 0.6)
    # крыльцо: настил, два столба, навес
    px0, px1, py1 = 0.2, 1.45, hd + 1.0
    box(m, px0, px1, hd, py1, 0.0, PLINTH_H - 0.05, "wood")
    for x in (px0 + 0.06, px1 - 0.06):
        post(m, x, py1 - 0.06, PLINTH_H - 0.05, 1.78, 0.09, "trim")
    poly = [(hd, 1.95), (hd, 2.05), (py1 + 0.15, 1.83), (py1 + 0.15, 1.73)]
    prism(m, poly, px0 - 0.1, px1 + 0.1, "x", "roof_brown")
    chimney(m, roof_z, -0.5, -1.1, "y", wall_h + roof_h + 0.45)


def smokehouse(m):
    """Коптильня: тёмный сруб, низкая дверь, каменная труба сбоку."""
    w, d, wall_h, roof_h = 2.3, 2.3, 1.6, 0.75
    shell(m, w, d, wall_h, roof_h, "x", "wood_dark", "roof", oh=0.2, gable_oh=0.18, corners="wood")
    hd, hw = d / 2, w / 2
    door(m, "+y", hd, -0.3, w=0.5, h=1.05, mat="wood", frame="wood")
    window(m, "+y", hd, 0.6, zc=1.2, w=0.3, h=0.22, frame="wood")  # продух
    # труба-печь у задней стены: широкое основание и узкая труба
    box(m, -0.45, 0.45, -hd - 0.55, -hd + 0.02, 0.0, 1.1, "stone")
    box(m, -0.2, 0.2, -hd - 0.45, -hd - 0.05, 1.1, wall_h + roof_h + 1.1, "stone")
    box(m, -0.25, 0.25, -hd - 0.5, -hd, wall_h + roof_h + 1.1, wall_h + roof_h + 1.17, "stone")
    # поленница у стены
    box(m, hw + 0.02, hw + 0.42, -0.8, 0.8, 0.0, 0.7, "wood")
    prism(m, [(-0.9, 0.7), (0.9, 0.7), (0.9, 0.8), (-0.9, 0.85)], hw, hw + 0.5, "x", "roof")


def net_shed(m):
    """Склад сетей / лодочный сарай: щипец к воде, широкие ворота, без окон в фасаде."""
    w, d, wall_h, roof_h = 4.4, 6.0, 2.2, 1.1
    shell(m, w, d, wall_h, roof_h, "y", "wood", "roof", oh=0.2, gable_oh=0.3, corners="wood_dark")
    hd, hw = d / 2, w / 2
    gw, gh = 2.3, 1.8
    on_wall(m, "+y", hd, 0.0, gw + 0.16, PLINTH_H - 0.05, PLINTH_H + gh + 0.08, 0.03, "wood_dark")
    for k in (-1, 1):
        on_wall(m, "+y", hd, k * gw / 4, gw / 2 - 0.04, PLINTH_H - 0.05, PLINTH_H + gh, 0.06, "wood")
    on_wall(m, "+y", hd, 0.0, gw * 0.9, PLINTH_H + gh * 0.45, PLINTH_H + gh * 0.55, 0.08, "wood_dark")  # засов
    # пандус к воротам
    prism(m, [(hd, 0.0), (hd, PLINTH_H), (hd + 0.6, 0.0)], -gw / 2, gw / 2, "x", "wood")
    window(m, "+y", hd, 0.0, zc=wall_h + 0.4, w=0.4, h=0.3, frame="wood_dark")
    for y in (-1.5, 1.0):
        window(m, "+x", hw, y, frame="wood_dark")
    window(m, "-x", -hw, -0.3, frame="wood_dark")
    # сеть на стене
    prism(m, [(-1.6, 0.7), (1.2, 0.7), (1.0, 1.8), (-1.4, 1.85)], -hw - 0.06, -hw - 0.02, "x", "net")


def shop(m):
    """Лавка: охристые стены, витрина, навес над входом, вывеска."""
    w, d, wall_h, roof_h = 4.2, 3.6, 2.1, 1.1
    roof_z = shell(m, w, d, wall_h, roof_h, "x", "wall_ochre", "roof")
    hd, hw = d / 2, w / 2
    door(m, "+y", hd, -1.1, mat="wall_blue")
    window(m, "+y", hd, 0.55, zc=0.98, w=1.6, h=0.7)  # витрина
    window(m, "-y", -hd, 0.0)
    window(m, "+x", hw, -0.4)
    window(m, "-x", -hw, -0.4)
    # навес на кронштейнах и вывеска над ним (под свесом крыши)
    ya, yb = hd, hd + 1.0
    poly = [(ya, 1.64), (ya, 1.71), (yb, 1.44), (yb, 1.37)]
    prism(m, poly, -hw + 0.15, hw - 0.15, "x", "awning")
    box(m, -hw + 0.15, hw - 0.15, yb - 0.04, yb, 1.22, 1.44, "awning")  # фартук
    for x in (-hw + 0.3, 0.0, hw - 0.3):
        box(m, x - 0.03, x + 0.03, ya, yb - 0.1, 1.5, 1.56, "wood_dark")
    on_wall(m, "+y", hd, 0.0, 2.0, 1.72, 1.95, 0.05, "wood_dark")
    on_wall(m, "+y", hd, 0.0, 1.85, 1.75, 1.92, 0.07, "trim")
    # ящики у входа
    box(m, 0.9, 1.4, hd + 0.1, hd + 0.55, 0.0, 0.4, "wood")
    box(m, 1.45, 1.85, hd + 0.15, hd + 0.5, 0.0, 0.32, "wood_dark")
    chimney(m, roof_z, -1.2, -0.45, "x", wall_h + roof_h + 0.45, size=0.28)


def pier(m):
    """Причал на сваях: 20 м в −Y от берега, настил на +0,3, сваи до −4."""
    length, width = 20.0, 2.0
    deck_z = 0.3
    hw = width / 2
    # настил из досок поперёк с зазорами — по 1 м
    n = 20
    for i in range(n):
        y1 = -i * length / n
        y0 = y1 - length / n + 0.06
        box(m, -hw, hw, y0, y1, deck_z - 0.1, deck_z, "wood")
    # продольные балки
    for x in (-hw + 0.2, hw - 0.2):
        box(m, x - 0.08, x + 0.08, -length, 0.0, deck_z - 0.28, deck_z - 0.1, "wood_dark")
    # сваи: пара каждые 4 м, на краях — выше настила (тумбы для швартовки)
    for k in range(6):
        y = -0.3 - k * (length - 0.6) / 5
        for x in (-hw - 0.05, hw + 0.05):
            top = deck_z + (0.45 if k % 2 == 1 or k == 5 else -0.12)
            post(m, x, y, -4.0, top, 0.2, "wood_dark")
    # поперечины между сваями
    for k in range(6):
        y = -0.3 - k * (length - 0.6) / 5
        box(m, -hw - 0.1, hw + 0.1, y - 0.06, y + 0.06, deck_z - 0.5, deck_z - 0.3, "wood_dark")
    # лесенка к воде у дальнего конца
    for x in (-0.35, 0.35):
        box(m, hw + 0.05, hw + 0.11, -length + 1.0 + x - 0.03, -length + 1.0 + x + 0.03, -1.0, deck_z, "wood_dark")
    for z in (-0.7, -0.35, 0.0):
        box(m, hw + 0.05, hw + 0.13, -length + 0.65, -length + 1.35, z - 0.03, z + 0.03, "wood_dark")


def boat_sections():
    # (y, полуширина по борту, полуширина днища, z днища, z борта); y: −Y корма, +Y нос
    return [
        (-1.6, 0.42, 0.26, -0.10, 0.36),
        (-1.0, 0.54, 0.34, -0.15, 0.36),
        (0.0, 0.56, 0.32, -0.15, 0.38),
        (0.9, 0.44, 0.18, -0.12, 0.44),
        (1.45, 0.20, 0.04, -0.04, 0.52),
        (1.6, 0.02, 0.01, 0.10, 0.56),
    ]


def hull_ring(sec, inset=0.0, lift=0.0):
    y, hwt, hwb, zb, zt = sec
    hwt = max(hwt - inset, 0.005)
    hwb = max(hwb - inset, 0.003)
    zb = zb + lift
    return [(-hwt, y, zt), (-hwb, y, zb + 0.05), (0.0, y, zb), (hwb, y, zb + 0.05), (hwt, y, zt)]


def boat(m):
    """Лодка-плоскодонка: корпус из сечений, открытый сверху, две банки."""
    secs = boat_sections()
    outer = [[m.vert(p) for p in hull_ring(s)] for s in secs]
    inner = [[m.vert(p) for p in hull_ring(s, 0.05, 0.07)] for s in secs[:-1]]
    for i in range(len(secs) - 1):
        a, b = outer[i], outer[i + 1]
        axis = (0.0, (secs[i][0] + secs[i + 1][0]) / 2, 0.6)
        for k in range(4):
            m.face([a[k], a[k + 1], b[k + 1], b[k]], axis, "wood", toward=False)
    for i in range(len(inner) - 1):
        a, b = inner[i], inner[i + 1]
        axis = (0.0, (secs[i][0] + secs[i + 1][0]) / 2, 0.6)
        for k in range(4):
            m.face([a[k], a[k + 1], b[k + 1], b[k]], axis, "wood_dark", toward=True)
    # кромка борта: от внешнего к внутреннему верху (стороны), нос закрыт
    for i in range(len(inner) - 1):
        for k in (0, 4):
            m.face([outer[i][k], outer[i + 1][k], inner[i + 1][k], inner[i][k]], (0.0, secs[i][0], -1.0), "trim")
    last = len(inner) - 1
    nose_c = (0.0, secs[last][0], 0.2)
    m.face([outer[last][0], outer[last + 1][0], inner[last][0]], nose_c, "trim")
    m.face([outer[last][4], outer[last + 1][4], inner[last][4]], nose_c, "trim")
    m.face([inner[last][4], outer[last + 1][4], outer[last + 1][0], inner[last][0]], (0.0, 0.0, 0.0), "wood_dark")
    # транец: кольцо между внешним и внутренним сечением кормы
    o, n = outer[0], inner[0]
    for k in range(4):
        m.face([o[k], o[k + 1], n[k + 1], n[k]], (0.0, 0.5, 0.1), "wood")
    m.face(list(n), (0.0, 0.5, 0.1), "wood")
    # банки (сиденья)
    for y, hw in ((-1.1, 0.44), (0.1, 0.46)):
        box(m, -hw, hw, y - 0.14, y + 0.14, 0.18, 0.23, "wood")
    # вёсла вдоль борта
    for x in (-0.25, 0.25):
        box(m, x - 0.03, x + 0.03, -1.3, 1.0, 0.0, 0.04, "wood_dark")


def net_rack(m):
    """Вешала: три столба, перекладина, сеть с провисом по пролётам, поплавки."""
    xs = (-1.4, 0.0, 1.4)
    top = 1.65
    for x in xs:
        post(m, x, 0.0, 0.0, top, 0.09, "wood")
        # подпорки
        prism(m, [(-0.22, 0.0), (-0.16, 0.0), (0.0, 0.7), (0.0, 0.78)], x - 0.03, x + 0.03, "x", "wood")
        prism(m, [(0.22, 0.0), (0.16, 0.0), (0.0, 0.7), (0.0, 0.78)], x - 0.03, x + 0.03, "x", "wood")
    box(m, xs[0] - 0.12, xs[-1] + 0.12, -0.04, 0.04, top - 0.1, top - 0.02, "wood")
    for a, b in zip(xs, xs[1:]):
        x0, x1 = a + 0.05, b - 0.05
        poly = [(x0, top - 0.1), (x1, top - 0.1), (x1, 0.55), ((x0 + x1) / 2, 0.38), (x0, 0.55)]
        prism(m, poly, 0.04, 0.06, "y", "net")
        for u in (0.25, 0.5, 0.75):
            fx = x0 + (x1 - x0) * u
            box(m, fx - 0.05, fx + 0.05, 0.03, 0.09, top - 0.16, top - 0.08, "float")


MODELS = [
    ("house_a", house_a),
    ("house_b", house_b),
    ("smokehouse", smokehouse),
    ("net_shed", net_shed),
    ("shop", shop),
    ("pier", pier),
    ("boat", boat),
    ("net_rack", net_rack),
]


# --- Blender: меш, материалы, экспорт -------------------------------------------------


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def make_material(name):
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    r, g, b = (srgb_to_linear(c) for c in MATS[name])
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.9
    bsdf.inputs["Metallic"].default_value = 0.0
    mat.diffuse_color = (r, g, b, 1.0)
    return mat


def to_object(name, m):
    used = sorted(set(m.fmat), key=list(MATS).index)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(v) for v in m.verts], [], m.faces)
    for mat in used:
        mesh.materials.append(make_material(mat))
    mesh.polygons.foreach_set("material_index", [used.index(f) for f in m.fmat])
    mesh.update()
    mesh.validate()
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bm.to_mesh(mesh)
    bm.free()
    mesh.shade_flat()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    tris = sum(len(p.vertices) - 2 for p in mesh.polygons)
    xs = [v.co.x for v in mesh.vertices]
    ys = [v.co.y for v in mesh.vertices]
    zs = [v.co.z for v in mesh.vertices]
    print("VILLAGE %-11s tris=%5d  X %.2f..%.2f  Y %.2f..%.2f  Z %.2f..%.2f  (%.1f x %.1f x %.1f)" % (
        name, tris, min(xs), max(xs), min(ys), max(ys), min(zs), max(zs),
        max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)))
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


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for name, fn in MODELS:
        m = Mesh()
        fn(m)
        export_glb(to_object(name, m))


main()
