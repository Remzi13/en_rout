# Экспорт карты мира из Blender в данные для Godot. Запуск из корня проекта
# (обычно через tools/export_map.sh, который затем запекает чанки):
#   blender --background art/map/map.blend --python tools/blender/export_map.py
# Результат — art/map/export/:
#   map.json     — размеры мира и сетки, дороги (линии в XZ Godot), старт,
#                  объекты из коллекции Props, места (Places) и точки
#                  доставок (Spots) — см. docs/map-pipeline.md;
#   heights.f32  — высоты рельефа на сетке 4 м (float32, строки по Z, little-endian);
#   forest.u8, conifer.u8, rocks.u8 — маски из групп вершин Terrain (0..255).
# Что читается из карты — см. tools/blender/make_map.py (Terrain, Roads,
# PlayerStart) и docs/map-pipeline.md (Props, Places, Spots). Мир — целые чанки по 256 м, покрытые рельефом Terrain.
# Оси: Godot (x, y, z) = Blender (x, z, -y).

import json
import math
import os
import struct
import sys

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import interpolate_bezier

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "art", "map", "export")

CHUNK_SIZE = 256.0
GRID_STEP = 4.0
MASKS = ("forest", "conifer", "rocks")
BEZIER_STEPS = 16  # точек на сегмент кривой Безье
MISS_HEIGHT = -12.0  # где под точкой нет рельефа


def fail(msg):
    print("ОШИБКА: " + msg)
    sys.exit(1)


def bary(p, a, b, c):
    """Барицентрические координаты точки p в треугольнике abc (в плоскости XY)."""
    v0x, v0y = b.x - a.x, b.y - a.y
    v1x, v1y = c.x - a.x, c.y - a.y
    v2x, v2y = p.x - a.x, p.y - a.y
    d00 = v0x * v0x + v0y * v0y
    d01 = v0x * v1x + v0y * v1y
    d11 = v1x * v1x + v1y * v1y
    d20 = v2x * v0x + v2y * v0y
    d21 = v2x * v1x + v2y * v1y
    den = d00 * d11 - d01 * d01
    if abs(den) < 1e-12:
        return 1.0, 0.0, 0.0
    v = (d11 * d20 - d01 * d21) / den
    w = (d00 * d21 - d01 * d20) / den
    return 1.0 - v - w, v, w


def export_terrain(depsgraph):
    terr = bpy.data.objects.get("Terrain")
    if terr is None or terr.type != "MESH":
        fail("нет объекта-сетки Terrain")
    ev = terr.evaluated_get(depsgraph)
    me = ev.to_mesh()
    mw = terr.matrix_world
    verts = [mw @ v.co for v in me.vertices]
    me.calc_loop_triangles()
    tris = [tuple(t.vertices) for t in me.loop_triangles]
    bvh = BVHTree.FromPolygons(verts, tris)

    weights = {}
    for name in MASKS:
        arr = [0.0] * len(verts)
        vg = terr.vertex_groups.get(name)
        if vg is None:
            print("Внимание: у Terrain нет группы вершин %s — маска пустая" % name)
        else:
            for v in me.vertices:
                for g in v.groups:
                    if g.group == vg.index:
                        arr[v.index] = g.weight
        weights[name] = arr

    # Границы мира в координатах Godot, округлённые до целых чанков.
    min_x = min(v.x for v in verts)
    max_x = max(v.x for v in verts)
    min_z = min(-v.y for v in verts)
    max_z = max(-v.y for v in verts)
    cx0 = math.floor(min_x / CHUNK_SIZE + 0.01)
    cx1 = math.ceil(max_x / CHUNK_SIZE - 0.01)
    cz0 = math.floor(min_z / CHUNK_SIZE + 0.01)
    cz1 = math.ceil(max_z / CHUNK_SIZE - 0.01)
    nx, nz = cx1 - cx0, cz1 - cz0
    per_chunk = int(CHUNK_SIZE / GRID_STEP)
    gw, gh = nx * per_chunk + 1, nz * per_chunk + 1
    x0, z0 = cx0 * CHUNK_SIZE, cz0 * CHUNK_SIZE
    top = max(v.z for v in verts) + 100.0
    down = Vector((0.0, 0.0, -1.0))

    heights = []
    mask_bytes = {name: bytearray() for name in MASKS}
    misses = 0
    for gz in range(gh):
        z = z0 + gz * GRID_STEP
        for gx in range(gw):
            x = x0 + gx * GRID_STEP
            # Точки ровно на краю рельефа луч может не задеть — сдвигаем внутрь.
            sx = min(max(x, min_x + 0.001), max_x - 0.001)
            sz = min(max(z, min_z + 0.001), max_z - 0.001)
            loc, _nrm, idx, _d = bvh.ray_cast(Vector((sx, -sz, top)), down)
            if loc is None:
                misses += 1
                heights.append(MISS_HEIGHT)
                for name in MASKS:
                    mask_bytes[name].append(0)
                continue
            heights.append(loc.z)
            t = tris[idx]
            u, v, w = bary(loc, verts[t[0]], verts[t[1]], verts[t[2]])
            for name in MASKS:
                arr = weights[name]
                val = arr[t[0]] * u + arr[t[1]] * v + arr[t[2]] * w
                mask_bytes[name].append(max(0, min(255, int(round(val * 255.0)))))
    ev.to_mesh_clear()
    if misses:
        print("Внимание: %d точек сетки без рельефа под ними (высота %.0f м)" % (misses, MISS_HEIGHT))

    with open(os.path.join(OUT_DIR, "heights.f32"), "wb") as f:
        f.write(struct.pack("<%df" % len(heights), *heights))
    for name in MASKS:
        with open(os.path.join(OUT_DIR, name + ".u8"), "wb") as f:
            f.write(bytes(mask_bytes[name]))
    return {
        "chunk_min": [cx0, cz0],
        "chunks": [nx, nz],
        "grid": [gw, gh],
        "origin": [x0, z0],
    }


def spline_points(spline, mw):
    """Точки сплайна в мире Blender (без повтора первой у замкнутого)."""
    pts = []
    if spline.type == "BEZIER":
        bps = list(spline.bezier_points)
        segs = list(zip(bps, bps[1:]))
        if spline.use_cyclic_u and len(bps) > 1:
            segs.append((bps[-1], bps[0]))
        for a, b in segs:
            seg = interpolate_bezier(mw @ a.co, mw @ a.handle_right, mw @ b.handle_left, mw @ b.co, BEZIER_STEPS + 1)
            pts.extend(seg[:-1])
        if not spline.use_cyclic_u and bps:
            pts.append(mw @ bps[-1].co)
    else:
        if spline.type == "NURBS":
            print("Внимание: NURBS-кривая берётся по контрольным точкам; лучше Безье")
        pts = [mw @ p.co.xyz for p in spline.points]
    return pts


def export_roads():
    coll = bpy.data.collections.get("Roads")
    if coll is None:
        fail("нет коллекции Roads")
    roads = []
    for obj in coll.all_objects:
        if obj.type != "CURVE":
            continue
        kind = str(obj.get("road_type", "dirt" if "dirt" in obj.name.lower() else "highway"))
        if kind not in ("highway", "dirt"):
            print("Внимание: %s: road_type=%s, считаю highway" % (obj.name, kind))
            kind = "highway"
        for k, sp in enumerate(obj.data.splines):
            pts = spline_points(sp, obj.matrix_world)
            if len(pts) < 2:
                continue
            roads.append({
                "name": "%s/%d" % (obj.name, k),
                "type": kind,
                "cyclic": bool(sp.use_cyclic_u),
                "points": [[round(p.x, 3), round(-p.y, 3)] for p in pts],
            })
    if not roads:
        fail("в коллекции Roads нет кривых")
    return roads


def export_start():
    obj = bpy.data.objects.get("PlayerStart")
    if obj is None:
        print("Внимание: нет PlayerStart — старт будет на первой дороге")
        return None
    p = obj.matrix_world.translation
    fwd = obj.matrix_world.col[1].xyz
    return {"pos": [p.x, p.z, -p.y], "forward": [fwd.x, -fwd.y]}


def export_props():
    """Пустышки коллекции Props -> объекты для узла Props чанков.
    Нет коллекции — пустой список. Модель проверяет запекание (Godot)."""
    coll = bpy.data.collections.get("Props")
    if coll is None:
        return []
    props = []
    for obj in sorted(coll.all_objects, key=lambda o: o.name):
        if obj.type != "EMPTY":
            continue
        model = str(obj.get("model", "")).strip()
        if not model:
            print("Внимание: Props/%s: нет свойства model — пропускаю" % obj.name)
            continue
        mw = obj.matrix_world
        p = mw.translation
        x_axis = mw.col[0].xyz
        if abs(x_axis.normalized().z) > 0.02 or abs(mw.col[1].xyz.normalized().z) > 0.02:
            print("Внимание: Props/%s: наклон не переносится, берётся только поворот вокруг Z" % obj.name)
        sx, sy, sz = mw.to_scale()
        collision = str(obj.get("collision", "box"))
        if collision not in ("box", "none"):
            print("Внимание: Props/%s: collision=%s, считаю box" % (obj.name, collision))
            collision = "box"
        item = {
            "name": obj.name,
            "model": model,
            # Оси: Godot (x, y, z) = Blender (x, z, -y); поворот вокруг Z
            # Blender = поворот вокруг Y Godot на тот же угол.
            "pos": [round(p.x, 3), round(p.z, 3), round(-p.y, 3)],
            "yaw": round(math.atan2(x_axis.y, x_axis.x), 5),
            "scale": [round(sx, 4), round(sz, 4), round(sy, 4)],
            "snap_to_ground": bool(obj.get("snap_to_ground", False)),
            "collision": collision,
        }
        # Прогалина вокруг объекта (м); нет свойства — отступ по умолчанию при запекании.
        if "clear_radius" in obj.keys():
            try:
                clear = float(obj["clear_radius"])
            except (TypeError, ValueError):
                clear = -1.0
            if clear < 0.0:
                print("Внимание: Props/%s: плохой clear_radius, беру по умолчанию" % obj.name)
            else:
                item["clear_radius"] = round(clear, 3)
        props.append(item)
    return props


def export_points(coll_name, default_radius):
    """Пустышки коллекции Places или Spots -> [{id, title, radius, pos}].
    Нет коллекции — пустой список. Пустой или повторный id — пропуск.
    Высоту по рельефу ставит запекание (Godot)."""
    coll = bpy.data.collections.get(coll_name)
    if coll is None:
        return []
    out = []
    seen = set()
    for obj in sorted(coll.all_objects, key=lambda o: o.name):
        if obj.type != "EMPTY":
            continue
        pid = str(obj.get("id", "")).strip()
        if not pid:
            print("Внимание: %s/%s: нет свойства id — пропускаю" % (coll_name, obj.name))
            continue
        if pid in seen:
            print("Внимание: %s/%s: id «%s» уже занят — пропускаю" % (coll_name, obj.name, pid))
            continue
        seen.add(pid)
        try:
            radius = float(obj.get("radius", default_radius))
        except (TypeError, ValueError):
            radius = -1.0
        if radius <= 0.0:
            print("Внимание: %s/%s: плохой radius, беру %g" % (coll_name, obj.name, default_radius))
            radius = default_radius
        p = obj.matrix_world.translation
        out.append({
            "id": pid,
            "title": str(obj.get("title", "")).strip() or pid,
            "radius": round(radius, 3),
            # Оси: Godot (x, y, z) = Blender (x, z, -y).
            "pos": [round(p.x, 3), round(p.z, 3), round(-p.y, 3)],
        })
    return out


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    data = {"version": 1, "chunk_size": CHUNK_SIZE, "grid_step": GRID_STEP}
    data.update(export_terrain(depsgraph))
    data["roads"] = export_roads()
    data["start"] = export_start()
    data["props"] = export_props()
    data["places"] = export_points("Places", 25.0)
    data["spots"] = export_points("Spots", 8.0)
    with open(os.path.join(OUT_DIR, "map.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    print("Экспорт карты: %d×%d чанков, сетка %d×%d, дорог %d, объектов %d, мест %d, точек %d -> %s" % (
        data["chunks"][0], data["chunks"][1], data["grid"][0], data["grid"][1], len(data["roads"]),
        len(data["props"]), len(data["places"]), len(data["spots"]), OUT_DIR))


main()
