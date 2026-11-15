# Расстановка рыбацкой деревни, мест, точек доставок и старта на карте.
# Запуск из корня проекта (файл карты сохраняется):
#   blender --background art/map/map.blend --python tools/blender/place_village.py
# затем tools/export_map.sh.
#
# Скрипт идемпотентный: при каждом запуске пересоздаёт только своё —
#   Props/<VILLAGE_COLLS> — подколлекции с пустышками построек (Props.all_objects
#                           читает экспорт, так что подколлекции ему не мешают);
#   Places, Spots         — пустышки с id из PLACES и SPOTS (чужие не трогает);
#   PlayerStart           — положение и направление;
#   прогалины в лесу      — группа вершин forest у Terrain = forest_orig × множитель
#                           прогалин (CLEARINGS). Исходная маска один раз копируется
#                           в группу forest_orig и дальше не меняется; убрать прогалину
#                           из CLEARINGS и перезапустить — лес вернётся.
# Рельеф (вершины Terrain), дороги и маски conifer/rocks не меняются.
#
# Координаты ниже — Godot (x, z): x тот же, z = −y Blender. Соглашения о пустышках —
# docs/map-pipeline.md (Props, Places/Spots, «Модели деревни»). Модель смотрит фасадом в
# +Y Blender (−Z Godot); направление фасада задаём вектором в координатах Godot.

import math
import os

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import interpolate_bezier

WATER = -4.0
M = "res://game/world/models/village/"
VILLAGE_COLLS = ("Village", "EastPier", "FishingCamp", "FarFarm")

# Прогалины (Godot x, z): круг (x, z, r) или полоса ((x1, z1), (x2, z2), r).
# Внутри r лес убран, дальше FALLOFF_M метров плавно возвращается.
FALLOFF_M = 14.0
CLEARINGS = [
    ((-135.0, 268.0), (-252.0, 321.0), 30.0),  # улица деревни вдоль Dirt_Lake
    (-272.0, 334.0, 30.0),  # площадь в конце дороги
    ((-280.0, 340.0), (-360.0, 352.0), 26.0),  # спуск к причалу, вид на озеро
    ((-296.0, 524.0), (-385.0, 458.0), 28.0),  # луг на холме над озером (hill_view)
    ((-466.0, 140.0), (-462.0, 268.0), 12.0),  # просека от шоссе к причалу на том берегу
    (-462.0, 245.0, 20.0),  # берег у второго причала
    (-560.0, 470.0, 14.0),  # мыс между озером и прудом (lake_cape)
    (-640.0, 605.0, 26.0),  # рыбацкий лагерь у пруда
    (655.0, -100.0, 30.0),  # хутор
]

# Места: имя пустышки, id, title, x, z, radius.
PLACES = [
    ("Place_HillView", "hill_view", "Холм над озером", -322.0, 505.0, 40.0),
    ("Place_ForestTrack", "forest_track", "Лесная грунтовка", None, None, 30.0),  # точка на Dirt_South
    ("Place_LakeCape", "lake_cape", "Мыс", -556.0, 474.0, 30.0),
]
FOREST_TRACK_NEAR = (205.0, -380.0)  # ближайшая точка Dirt_South — самый глухой лес на гребне


def g2b(x, z, y=0.0):
    return Vector((x, -z, y))


def yaw_facing(fx, fz):
    """Поворот вокруг Z Blender, при котором фасад (+Y модели) смотрит в (fx, fz) Godot."""
    return math.atan2(-fx, -fz)


def norm(x, z):
    l = math.hypot(x, z)
    return (x / l, z / l)


# --- Рельеф и дороги --------------------------------------------------------------

class Ground:
    def __init__(self):
        terr = bpy.data.objects["Terrain"]
        dg = bpy.context.evaluated_depsgraph_get()
        ev = terr.evaluated_get(dg)
        me = ev.to_mesh()
        mw = terr.matrix_world
        verts = [mw @ v.co for v in me.vertices]
        me.calc_loop_triangles()
        self.bvh = BVHTree.FromPolygons(verts, [tuple(t.vertices) for t in me.loop_triangles])
        ev.to_mesh_clear()

    def h(self, x, z):
        hit = self.bvh.ray_cast(g2b(x, z, 500.0), Vector((0, 0, -1)))
        return hit[0].z if hit[0] is not None else 0.0


def road_polyline(name):
    obj = bpy.data.objects[name]
    sp = obj.data.splines[0]
    mw = obj.matrix_world
    bps = list(sp.bezier_points)
    pts = []
    for a, b in zip(bps, bps[1:]):
        seg = interpolate_bezier(mw @ a.co, mw @ a.handle_right, mw @ b.handle_left, mw @ b.co, 33)
        pts.extend(seg[:-1])
    pts.append(mw @ bps[-1].co)
    return [(p.x, -p.y) for p in pts]


def along_from_end(poly, s):
    """Точка дороги на расстоянии s от её конца и направление движения к концу."""
    rev = poly[::-1]
    for a, b in zip(rev, rev[1:]):
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        if s <= seg:
            t = s / seg
            d = norm(a[0] - b[0], a[1] - b[1])
            return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t), d
        s -= seg
    a, b = rev[-2], rev[-1]
    return b, norm(a[0] - b[0], a[1] - b[1])


def nearest_on(poly, x, z):
    best = (1e18, None)
    for a, b in zip(poly, poly[1:]):
        dx, dz = b[0] - a[0], b[1] - a[1]
        l2 = dx * dx + dz * dz
        u = max(0.0, min(1.0, ((x - a[0]) * dx + (z - a[1]) * dz) / l2))
        p = (a[0] + dx * u, a[1] + dz * u)
        dd = (p[0] - x) ** 2 + (p[1] - z) ** 2
        if dd < best[0]:
            best = (dd, p)
    return best[1]


# --- Пустышки --------------------------------------------------------------------

def make_empty(name, coll, x, z, y, yaw=0.0, kind="PLAIN_AXES", size=2.0):
    obj = bpy.data.objects.new(name, None)
    obj.empty_display_type = kind
    obj.empty_display_size = size
    obj.location = g2b(x, z, y)
    obj.rotation_euler = (0.0, 0.0, yaw)
    coll.objects.link(obj)
    return obj


def remove_objects(objs):
    for o in list(objs):
        bpy.data.objects.remove(o, do_unlink=True)


def get_coll(name, parent):
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
        parent.children.link(coll)
    return coll


class Placer:
    def __init__(self, ground, coll):
        self.g = ground
        self.coll = coll

    def prop(self, name, model, x, z, face, snap=True, collision="box", y=None):
        """face — направление фасада (fx, fz) в Godot."""
        if y is None:
            y = self.g.h(x, z) + (0.5 if snap else 0.0)
        obj = make_empty(name, self.coll, x, z, y, yaw_facing(*face), "ARROWS", 2.5)
        obj["model"] = M + model + ".glb"
        obj["snap_to_ground"] = snap
        obj["collision"] = collision
        return obj

    def facing_road(self, name, model, x, z, poly, turn_deg=0.0, **kw):
        """Постройка фасадом к ближайшей точке дороги, с небольшим разворотом turn_deg."""
        p = nearest_on(poly, x, z)
        fx, fz = norm(p[0] - x, p[1] - z)
        a = math.radians(turn_deg)
        fx, fz = fx * math.cos(a) - fz * math.sin(a), fx * math.sin(a) + fz * math.cos(a)
        return self.prop(name, model, x, z, (fx, fz), **kw)

    def street(self, name, model, poly, s, side, off, turn_deg=0.0, **kw):
        """Постройка у дороги: s м от конца, side +1 — север (слева по ходу к концу), off — отступ от оси."""
        p, d = along_from_end(poly, s)
        n = (-d[1] * side, d[0] * side)
        return self.facing_road(name, model, p[0] + n[0] * off, p[1] + n[1] * off, poly, turn_deg, **kw)

    def pier(self, name, x, z, out):
        """Причал: (x, z) — береговой конец, out — куда он уходит в воду. Высота — берег у воды."""
        y = max(self.g.h(x, z), WATER + 0.3)
        return self.prop(name, "pier", x, z, (-out[0], -out[1]), snap=False, collision="none", y=y)

    def boat_at_pier(self, name, px, pz, out, along_m, side_m, turn_deg=0.0):
        """Лодка на воде у причала: along_m от берегового конца, side_m — вбок (+ вправо от хода в воду)."""
        o = norm(*out)
        r = (-o[1], o[0])
        x = px + o[0] * along_m + r[0] * side_m
        z = pz + o[1] * along_m + r[1] * side_m
        a = math.radians(turn_deg)
        f = (o[0] * math.cos(a) - o[1] * math.sin(a), o[0] * math.sin(a) + o[1] * math.cos(a))
        return self.prop(name, "boat", x, z, f, snap=False, collision="none", y=WATER)


# --- Расстановка ------------------------------------------------------------------

def place_village(pl, lake):
    """Деревня на ровной террасе (~14 м) восточного берега, вдоль последних 120 м Dirt_Lake.
    Улица ведёт к площади в конце дороги, с площади — спуск к причалу."""
    st = pl.street
    # Улица: дома вразнобой по обе стороны, фасадами к дороге.
    st("House_B_Square", "house_b", lake, 33.0, -1, 13.0, 8.0)
    st("House_A_Street1", "house_a", lake, 22.0, 1, 11.0, -6.0)
    st("Smokehouse", "smokehouse", lake, 63.0, -1, 9.0, 4.0)
    st("House_B_Street2", "house_b", lake, 60.0, 1, 13.0, 5.0)
    st("House_A_Street3", "house_a", lake, 84.0, -1, 12.0, -7.0)
    st("House_A_Street4", "house_a", lake, 94.0, 1, 10.5, 9.0)
    st("House_B_Street5", "house_b", lake, 101.0, -1, 13.0, -4.0)
    # Площадь: лавка в торце дороги, склад сетей у края террасы, к озеру.
    (ex, ez), d = along_from_end(lake, 0.0)
    # Лавка — сбоку от торца дороги: за торцом машине нужно место для разворота.
    pl.prop("Shop", "shop", ex + d[0] * 9.0 - d[1] * 12.5, ez + d[1] * 9.0 + d[0] * 12.5,
            norm(d[1] - d[0] * 0.35, -d[0] - d[1] * 0.35))
    pl.prop("NetShed", "net_shed", -279.0, 349.0, norm(1.0, -0.7))
    # Вешала на краю террасы у склада.
    pl.prop("NetRack_1", "net_rack", -288.0, 360.0, norm(-1.0, 0.25), collision="none")
    pl.prop("NetRack_2", "net_rack", -284.5, 366.5, norm(-1.0, 0.1), collision="none")
    pl.prop("NetRack_3", "net_rack", -270.0, 364.0, norm(0.2, -1.0), collision="none")
    # Причал под террасой, в сторону центра озера; две лодки у причала, одна поодаль.
    px, pz = -350.5, 349.0
    out = norm(-450.0 - px, 380.0 - pz)
    pl.pier("Pier_Village", px, pz, out)
    pl.boat_at_pier("Boat_1", px, pz, out, 9.0, 2.2, 3.0)
    pl.boat_at_pier("Boat_2", px, pz, out, 15.0, -2.25, -4.0)
    pl.boat_at_pier("Boat_3", px, pz, out, 6.0, -9.0, 35.0)


def place_east_pier(pl, cross):
    """Второй причал — на северном берегу, напротив деревни через озеро; к нему от
    Highway_Cross спускается просека."""
    px, pz = -461.0, 270.5
    out = (0.05, 1.0)
    pl.pier("Pier_East", px, pz, norm(*out))
    pl.boat_at_pier("Boat_East", px, pz, norm(*out), 12.0, 2.2, -3.0)
    pl.prop("NetRack_East", "net_rack", -470.0, 258.0, norm(1.0, 0.4), collision="none")


def place_fishing_camp(pl, ring):
    """Рыбацкий лагерь на низком берегу пруда у кольцевого шоссе (юго-запад от озера)."""
    pl.prop("Camp_Boat_Shore1", "boat", -644.0, 592.0, norm(-0.4, -1.0), collision="none")
    pl.prop("Camp_Boat_Shore2", "boat", -637.5, 594.0, norm(-0.1, -1.0), collision="none")
    pl.prop("Camp_NetRack_1", "net_rack", -656.0, 606.0, norm(0.6, -1.0), collision="none")
    pl.prop("Camp_NetRack_2", "net_rack", -633.0, 608.0, norm(-0.5, -1.0), collision="none")
    pl.prop("Camp_Hut", "smokehouse", -625.0, 611.0, norm(-0.8, 0.6))
    pl.prop("Camp_Boat_Water", "boat", -650.0, 566.0, norm(1.0, -0.3), snap=False, collision="none", y=WATER)


def place_far_farm(pl, cross):
    """Хутор у восточного конца Highway_Cross, на пологом гребне у края леса, фасадами к шоссе."""
    pl.facing_road("Farm_House_A", "house_a", 641.0, -104.0, cross, 6.0)
    pl.facing_road("Farm_House_B", "house_b", 668.0, -112.0, cross, -10.0)
    pl.facing_road("Farm_Barn", "net_shed", 656.0, -86.0, cross, 15.0)


def spots(lake, cross):
    """Точки доставок: имя, id, title, x, z, radius."""
    out = []
    p, d = along_from_end(lake, 63.0)
    out.append(("Spot_Smokehouse", "smokehouse", "Коптильня", p[0] + d[1] * 4.0, p[1] - d[0] * 4.0, 8.0))
    p, d = along_from_end(lake, 0.0)
    out.append(("Spot_Shop", "shop", "Лавка", p[0] + d[0] * 7.0 - d[1] * 4.0, p[1] + d[1] * 7.0 + d[0] * 4.0, 8.0))
    out.append(("Spot_NetShed", "net_shed", "Склад сетей", -271.0, 343.0, 7.0))
    out.append(("Spot_FarFarm", "far_farm", "Хутор на холмах", 654.0, -116.0, 9.0))
    out.append(("Spot_EastPier", "east_pier", "Причал на том берегу", -462.0, 218.0, 8.0))
    out.append(("Spot_FishingCamp", "fishing_camp", "Рыбацкий лагерь", -638.0, 624.0, 8.0))
    return out


def player_start(ground, lake):
    """Старт на улице деревни, лицом к выезду: коптильня справа впереди, дальше улица
    уходит в лес. По бокам от старта ~15 м без построек: автопилот тестов
    (tests/headless/test_open_world.gd) едет по ребру к тупику и разворачивается здесь."""
    p, d = along_from_end(lake, 40.0)
    obj = bpy.data.objects.get("PlayerStart")
    if obj is None:
        obj = make_empty("PlayerStart", bpy.context.scene.collection, 0, 0, 0, kind="ARROWS", size=12.0)
    obj.location = g2b(p[0], p[1], ground.h(p[0], p[1]) + 2.0)
    obj.rotation_euler = (0.0, 0.0, yaw_facing(-d[0], -d[1]))
    return p


# --- Прогалины ------------------------------------------------------------------

def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def clearing_factor(x, z):
    f = 1.0
    for c in CLEARINGS:
        if len(c) == 3 and isinstance(c[0], tuple):
            (ax, az), (bx, bz), r = c
            dx, dz = bx - ax, bz - az
            u = max(0.0, min(1.0, ((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz)))
            dist = math.hypot(x - ax - dx * u, z - az - dz * u)
        else:
            cx, cz, r = c
            dist = math.hypot(x - cx, z - cz)
        f = min(f, smoothstep(r, r + FALLOFF_M, dist))
    return f


def apply_clearings():
    terr = bpy.data.objects["Terrain"]
    me = terr.data
    vg = terr.vertex_groups["forest"]
    orig = terr.vertex_groups.get("forest_orig")
    if orig is None:
        orig = terr.vertex_groups.new(name="forest_orig")
        for v in me.vertices:
            for g in v.groups:
                if g.group == vg.index and g.weight > 0.0:
                    orig.add([v.index], g.weight, "REPLACE")
    mw = terr.matrix_world
    changed = 0
    for v in me.vertices:
        w0 = 0.0
        w = 0.0
        for g in v.groups:
            if g.group == orig.index:
                w0 = g.weight
            elif g.group == vg.index:
                w = g.weight
        if w0 == 0.0 and w == 0.0:
            continue
        p = mw @ v.co
        target = round(w0 * clearing_factor(p.x, -p.y), 3)
        if abs(target - w) > 1e-4:
            vg.add([v.index], target, "REPLACE")
            changed += 1
    return changed


# --- Главное --------------------------------------------------------------------

def main():
    scene_root = bpy.context.scene.collection
    ground = Ground()
    lake = road_polyline("Dirt_Lake")
    cross = road_polyline("Highway_Cross")
    ring = road_polyline("Highway_Ring")
    south = road_polyline("Dirt_South")

    props = get_coll("Props", scene_root)
    for name in VILLAGE_COLLS:
        old = bpy.data.collections.get(name)
        if old is not None:
            remove_objects(old.objects)
            bpy.data.collections.remove(old)
    colls = {name: get_coll(name, props) for name in VILLAGE_COLLS}
    place_village(Placer(ground, colls["Village"]), lake)
    place_east_pier(Placer(ground, colls["EastPier"]), cross)
    place_fishing_camp(Placer(ground, colls["FishingCamp"]), ring)
    place_far_farm(Placer(ground, colls["FarFarm"]), cross)

    places = get_coll("Places", scene_root)
    spots_coll = get_coll("Spots", scene_root)
    plist = []
    for name, pid, title, x, z, r in PLACES:
        if x is None:
            x, z = nearest_on(south, *FOREST_TRACK_NEAR)
        plist.append((name, pid, title, x, z, r))
    slist = spots(lake, cross)
    for coll, items in ((places, plist), (spots_coll, slist)):
        ids = {i[1] for i in items}
        remove_objects([o for o in coll.objects if o.get("id") in ids or o.name in {i[0] for i in items}])
        for name, pid, title, x, z, r in items:
            obj = make_empty(name, coll, x, z, ground.h(x, z) + 2.0, kind="SPHERE", size=r)
            obj["id"] = pid
            obj["title"] = title
            obj["radius"] = r

    sp = player_start(ground, lake)
    changed = apply_clearings()
    bpy.ops.wm.save_mainfile(compress=True)
    n_props = sum(len(c.objects) for c in colls.values())
    print("Деревня: объектов %d, мест %d, точек %d, старт (%.1f, %.1f), вершин леса изменено %d" % (
        n_props, len(plist), len(slist), sp[0], sp[1], changed))
    for name, pid, title, x, z, r in plist + slist:
        print("  %-14s (%.1f, %.1f) r=%g" % (pid, x, z, r))


main()
