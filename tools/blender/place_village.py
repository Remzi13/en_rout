# Расстановка рыбацкой деревни, мест, точек доставок, старта и грунтовок к ним.
# Запуск из корня проекта (файл карты сохраняется):
#   blender --background art/map/map.blend --python tools/blender/place_village.py
# затем tools/export_map.sh.
#
# Скрипт идемпотентный: при каждом запуске пересоздаёт только своё —
#   Props/<VILLAGE_COLLS> — подколлекции с пустышками построек (Props.all_objects
#                           читает экспорт, так что подколлекции ему не мешают);
#   Roads/<NEW_ROADS>     — грунтовки к местам и точкам (кривые с этими именами
#                           удаляются и строятся заново, чужие дороги не трогает);
#   Places, Spots         — пустышки с id из PLACES и SPOTS (чужие не трогает);
#   PlayerStart           — положение и направление.
# Рельеф (вершины Terrain), старые дороги и маски растительности не меняются: прогалины
# вокруг построек и точек делает запекание (docs/map-pipeline.md, «Лес и прогалины»).
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

# Места: имя пустышки, id, title, x, z, radius.
PLACES = [
    ("Place_HillView", "hill_view", "Холм над озером", -302.0, 530.0, 40.0),  # вершина: Dirt_Hill и бровка Dirt_Cape
    ("Place_ForestTrack", "forest_track", "Лесная грунтовка", None, None, 30.0),  # точка на Dirt_South
    ("Place_LakeCape", "lake_cape", "Мыс", -556.0, 474.0, 30.0),  # Dirt_Cape проходит через радиус
]
FOREST_TRACK_NEAR = (205.0, -380.0)  # ближайшая точка Dirt_South — самый глухой лес на гребне

# Грунтовки к местам и точкам (Godot x, z). Начало и конец, где дорога примыкает к
# другой, вычисляются в build_roads: конец у середины чужой дороги — Т-перекрёсток,
# два конца в одной точке шоссе — перекрёсток (docs/map-pipeline.md, make_map.py).
# Профиль запекания ограничен уклоном 14 %, поэтому дороги идут по пологим склонам:
# точки подобраны по рельефу так, чтобы сглаженный уклон был не больше ~10 %.
NEW_ROADS = ("Dirt_Hill", "Dirt_Farm", "Dirt_Cape", "Dirt_Pier")
# Dirt_Hill: с площади деревни на юг по террасе вдоль восточного берега, на холм над
# озером (~18 м), вниз к кольцевому шоссе. Начало — на Dirt_Lake за HILL_FROM_END_M до её
# конца: конец Dirt_Lake (площадь) должен быть дальше 8 м от Dirt_Hill, иначе запекание
# пристегнёт его к ней Т-перекрёстком.
HILL_ROAD = [(-247.0, 343.0), (-248.0, 400.0), (-258.0, 470.0), (-286.0, 528.0),
             (-301.0, 590.0), (-294.0, 645.0)]
HILL_FROM_END_M = 20.0
HILL_RING_NEAR = (-292.0, 701.0)
# Dirt_Farm: от того же места на шоссе на юг, на пригорок у подножия краевых холмов.
FARM_ROAD = [(-296.0, 750.0), (-310.0, 792.0)]
# Dirt_Cape: с вершины холма к северной бровке (вид вниз на озеро), на запад по гребню,
# вниз на узкий берег у самой воды, через мыс на перешеек к пруду (рыбацкий лагерь).
CAPE_FROM_NEAR = (-292.0, 540.0)
CAPE_ROAD = [(-315.0, 506.0), (-350.0, 510.0), (-395.0, 532.0), (-435.0, 532.0),
             (-480.0, 508.0), (-530.0, 500.0), (-560.0, 490.0), (-588.0, 505.0)]
# Dirt_Pier: от поперечного шоссе на юг через лес, серпантином (разворот у бровки) вниз
# по берегу к самой воде у второго причала. Берег у причала ~25 %, поэтому спуск идёт
# наискосок, вдоль берега. Причал ставится на высоту конца дороги (см. place_east_pier).
PIER_CROSS_NEAR = (-480.0, 131.0)
# Разворот — севернее z = 256 (граница чанков): на границе дорога должна быть почти прямой
# (tests: test_world_map, «дорога гладко переходит через границу чанка»).
PIER_ROAD = [(-508.0, 185.0), (-540.0, 218.0), (-552.0, 240.0), (-535.0, 252.0),
             (-505.0, 264.0), (-472.0, 269.0)]


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


def place_east_pier(pl):
    """Второй причал — на северном берегу, напротив деревни через озеро, у конца Dirt_Pier.
    Запекание кладёт конец дороги на среднюю высоту рельефа в круге 6 м (не ниже −2,4) и
    выравнивает землю вокруг на ~9 м: береговой конец причала стоит в этой полосе, поэтому
    его высота — та же, чуть ниже полотна, а не рельеф до запекания (иначе причал засыпет)."""
    ex, ez = PIER_ROAD[-1]
    end_y = sum(pl.g.h(ex + dx, ez + dz) for dx, dz in ((0, 0), (6, 0), (-6, 0), (0, 6), (0, -6))) / 5.0
    px, pz = -462.0, 271.0
    out = norm(0.05, 1.0)
    pl.prop("Pier_East", "pier", px, pz, (-out[0], -out[1]), snap=False, collision="none",
            y=max(end_y, WATER + 1.6) - 0.1)
    pl.boat_at_pier("Boat_East", px, pz, out, 12.0, 2.2, -3.0)
    pl.prop("NetRack_East", "net_rack", -450.0, 259.0, norm(-1.0, 0.3), collision="none")


def place_fishing_camp(pl):
    """Рыбацкий лагерь на низком песчаном перешейке между озером и прудом, в конце
    Dirt_Cape: лодки на песке у пруда, вешала, хижина."""
    pl.prop("Camp_Hut", "smokehouse", -578.0, 524.0, norm(-10.0, -16.0))
    pl.prop("Camp_NetRack_1", "net_rack", -598.0, 527.0, norm(1.0, 0.3), collision="none")
    pl.prop("Camp_NetRack_2", "net_rack", -593.0, 538.0, norm(1.0, -0.2), collision="none")
    pl.prop("Camp_Boat_Shore1", "boat", -609.0, 514.0, norm(-1.0, 0.25), collision="none")
    pl.prop("Camp_Boat_Shore2", "boat", -605.0, 524.0, norm(-1.0, -0.1), collision="none")
    pl.prop("Camp_Boat_Water", "boat", -628.0, 512.0, norm(0.3, 1.0), snap=False, collision="none", y=WATER)


def place_far_farm(pl):
    """Хутор на пригорке за кольцевым шоссе, у подножия краевых холмов, в конце Dirt_Farm:
    дом, второй дом и сарай вокруг двора, фасадами во двор."""
    yard = (-310.0, 797.0)

    def face(x, z):
        return norm(yard[0] - x, yard[1] - z)

    pl.prop("Farm_House_A", "house_a", -327.0, 804.0, face(-327.0, 804.0))
    pl.prop("Farm_House_B", "house_b", -293.0, 806.0, face(-293.0, 806.0))
    pl.prop("Farm_Barn", "net_shed", -311.0, 824.0, face(-311.0, 824.0))


def spots(lake):
    """Точки доставок: имя, id, title, x, z, radius."""
    out = []
    p, d = along_from_end(lake, 63.0)
    out.append(("Spot_Smokehouse", "smokehouse", "Коптильня", p[0] + d[1] * 4.0, p[1] - d[0] * 4.0, 8.0))
    p, d = along_from_end(lake, 0.0)
    out.append(("Spot_Shop", "shop", "Лавка", p[0] + d[0] * 7.0 - d[1] * 4.0, p[1] + d[1] * 7.0 + d[0] * 4.0, 8.0))
    out.append(("Spot_NetShed", "net_shed", "Склад сетей", -259.0, 340.0, 7.0))  # между складом и Dirt_Hill
    out.append(("Spot_FarFarm", "far_farm", "Хутор на холмах", -310.0, 797.0, 9.0))  # двор, конец Dirt_Farm
    out.append(("Spot_EastPier", "east_pier", "Причал на том берегу", -469.0, 266.0, 8.0))  # конец Dirt_Pier у причала
    out.append(("Spot_FishingCamp", "fishing_camp", "Рыбацкий лагерь", -591.0, 512.0, 8.0))  # конец Dirt_Cape
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


# --- Грунтовки ------------------------------------------------------------------

def make_road(name, pts, ground, coll, like):
    """Грунтовка через точки pts (Godot x, z). Ручки — по Катмулл-Рому (кривая проходит
    через точки без петель), остальное — как у дороги like (материал, ширина, Shrinkwrap)."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = like.data.bevel_depth
    cu.bevel_resolution = like.data.bevel_resolution
    cu.resolution_u = like.data.resolution_u
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(pts) - 1)
    n = len(pts)
    for i, (bp, (x, z)) in enumerate(zip(sp.bezier_points, pts)):
        if i == 0:
            tx, tz = (pts[1][0] - x) / 3.0, (pts[1][1] - z) / 3.0
        elif i == n - 1:
            tx, tz = (x - pts[i - 1][0]) / 3.0, (z - pts[i - 1][1]) / 3.0
        else:
            tx, tz = (pts[i + 1][0] - pts[i - 1][0]) / 6.0, (pts[i + 1][1] - pts[i - 1][1]) / 6.0
        y = ground.h(x, z) + 1.0
        bp.handle_left_type = "FREE"
        bp.handle_right_type = "FREE"
        bp.co = g2b(x, z, y)
        bp.handle_left = g2b(x - tx, z - tz, y)
        bp.handle_right = g2b(x + tx, z + tz, y)
    obj = bpy.data.objects.new(name, cu)
    obj["road_type"] = "dirt"
    for m in like.data.materials:
        cu.materials.append(m)
    for m in like.modifiers:
        if m.type == "SHRINKWRAP":
            sw = obj.modifiers.new(m.name, "SHRINKWRAP")
            for attr in ("target", "wrap_method", "use_project_z", "use_negative_direction",
                         "use_positive_direction", "offset"):
                setattr(sw, attr, getattr(m, attr))
    coll.objects.link(obj)
    return obj


def build_roads(ground, lake, cross, ring):
    """Пересоздаёт NEW_ROADS. Возвращает их ломаные (Godot x, z) по имени."""
    coll = bpy.data.collections["Roads"]
    like = bpy.data.objects["Dirt_Lake"]
    for name in NEW_ROADS:
        old = bpy.data.objects.get(name)
        if old is not None:
            data = old.data
            bpy.data.objects.remove(old, do_unlink=True)
            if data is not None and data.users == 0:
                bpy.data.curves.remove(data)
    hill_start, _ = along_from_end(lake, HILL_FROM_END_M)
    at_ring = nearest_on(ring, *HILL_RING_NEAR)
    make_road("Dirt_Hill", [hill_start] + HILL_ROAD + [at_ring], ground, coll, like)
    hill = road_polyline("Dirt_Hill")
    make_road("Dirt_Farm", [at_ring] + FARM_ROAD, ground, coll, like)
    make_road("Dirt_Cape", [nearest_on(hill, *CAPE_FROM_NEAR)] + CAPE_ROAD, ground, coll, like)
    make_road("Dirt_Pier", [nearest_on(cross, *PIER_CROSS_NEAR)] + PIER_ROAD, ground, coll, like)
    return {name: road_polyline(name) for name in NEW_ROADS}


# --- Главное --------------------------------------------------------------------

def main():
    scene_root = bpy.context.scene.collection
    ground = Ground()
    lake = road_polyline("Dirt_Lake")
    cross = road_polyline("Highway_Cross")
    ring = road_polyline("Highway_Ring")
    south = road_polyline("Dirt_South")
    new_roads = build_roads(ground, lake, cross, ring)

    props = get_coll("Props", scene_root)
    for name in VILLAGE_COLLS:
        old = bpy.data.collections.get(name)
        if old is not None:
            remove_objects(old.objects)
            bpy.data.collections.remove(old)
    colls = {name: get_coll(name, props) for name in VILLAGE_COLLS}
    place_village(Placer(ground, colls["Village"]), lake)
    place_east_pier(Placer(ground, colls["EastPier"]))
    place_fishing_camp(Placer(ground, colls["FishingCamp"]))
    place_far_farm(Placer(ground, colls["FarFarm"]))

    places = get_coll("Places", scene_root)
    spots_coll = get_coll("Spots", scene_root)
    plist = []
    for name, pid, title, x, z, r in PLACES:
        if x is None:
            x, z = nearest_on(south, *FOREST_TRACK_NEAR)
        plist.append((name, pid, title, x, z, r))
    slist = spots(lake)
    for coll, items in ((places, plist), (spots_coll, slist)):
        ids = {i[1] for i in items}
        remove_objects([o for o in coll.objects if o.get("id") in ids or o.name in {i[0] for i in items}])
        for name, pid, title, x, z, r in items:
            obj = make_empty(name, coll, x, z, ground.h(x, z) + 2.0, kind="SPHERE", size=r)
            obj["id"] = pid
            obj["title"] = title
            obj["radius"] = r

    sp = player_start(ground, lake)
    bpy.ops.wm.save_mainfile(compress=True)
    n_props = sum(len(c.objects) for c in colls.values())
    print("Деревня: объектов %d, мест %d, точек %d, старт (%.1f, %.1f)" % (
        n_props, len(plist), len(slist), sp[0], sp[1]))
    for name, poly in new_roads.items():
        length = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(poly, poly[1:]))
        print("  %-10s %4.0f м" % (name, length))
    for name, pid, title, x, z, r in plist + slist:
        print("  %-14s (%.1f, %.1f) r=%g" % (pid, x, z, r))


main()
