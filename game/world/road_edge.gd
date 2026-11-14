class_name RoadEdge
extends RefCounted
## Один участок дорожной сети (из одного RoadPath) между узлами a_node и
## b_node. Точки в глобальных координатах с шагом ~RoadPath.SAMPLE_M.

var index: int = -1
var a_node: int = -1
var b_node: int = -1
var type: int = 0 ## WorldDefs.RoadType
var width: float = 12.0
var points: PackedVector3Array = PackedVector3Array()
var dists: PackedFloat32Array = PackedFloat32Array() ## накопленная длина до точки
var length: float = 0.0
var bbox: Rect2 = Rect2() ## в плоскости XZ, с учётом ширины


static func from_points(pts: PackedVector3Array, road_type: int) -> RoadEdge:
	var e := RoadEdge.new()
	e.type = road_type
	e.width = WorldDefs.ROAD_WIDTHS[road_type]
	e.points = pts
	var acc := 0.0
	var minx := INF
	var minz := INF
	var maxx := -INF
	var maxz := -INF
	for k in pts.size():
		if k > 0:
			acc += pts[k].distance_to(pts[k - 1])
		e.dists.append(acc)
		minx = minf(minx, pts[k].x)
		minz = minf(minz, pts[k].z)
		maxx = maxf(maxx, pts[k].x)
		maxz = maxf(maxz, pts[k].z)
	e.length = acc
	var pad := e.width * 0.5
	e.bbox = Rect2(minx - pad, minz - pad, maxx - minx + pad * 2.0, maxz - minz + pad * 2.0)
	return e


func key() -> int:
	return index


func is_highway() -> bool:
	return type == WorldDefs.RoadType.HIGHWAY


## Направление дороги в точке i (в плоскости XZ, нормализовано).
func tangent_at(i: int) -> Vector3:
	var n := points.size()
	var a := points[clampi(i - 1, 0, n - 1)]
	var b := points[clampi(i + 1, 0, n - 1)]
	var t := Vector3(b.x - a.x, 0.0, b.z - a.z)
	return t.normalized() if t.length_squared() > 0.0001 else Vector3.FORWARD


## Точка на оси дороги на расстоянии s от начала.
func sample(s: float) -> Vector3:
	s = clampf(s, 0.0, length)
	var i := _segment_at(s)
	var seg := dists[i + 1] - dists[i]
	var t := (s - dists[i]) / seg if seg > 0.0001 else 0.0
	return points[i].lerp(points[i + 1], t)


## Направление на расстоянии s (по ходу от начала к концу).
func tangent_at_distance(s: float) -> Vector3:
	var i := _segment_at(clampf(s, 0.0, length))
	var t := points[i + 1] - points[i]
	t.y = 0.0
	return t.normalized() if t.length_squared() > 0.0001 else Vector3.FORWARD


## Ближайшая точка оси: возвращает Vector2(s, расстояние по XZ).
func project(pos: Vector3, hint_s: float = -1.0, window_m: float = -1.0) -> Vector2:
	var i0 := 0
	var i1 := points.size() - 2
	if hint_s >= 0.0 and window_m > 0.0:
		i0 = maxi(_segment_at(maxf(hint_s - window_m, 0.0)), 0)
		i1 = mini(_segment_at(minf(hint_s + window_m, length)), points.size() - 2)
	var best_d := INF
	var best_s := 0.0
	for i in range(i0, i1 + 1):
		var a := points[i]
		var b := points[i + 1]
		var sx := b.x - a.x
		var sz := b.z - a.z
		var l2 := sx * sx + sz * sz
		var t := 0.0
		if l2 > 0.0001:
			t = clampf(((pos.x - a.x) * sx + (pos.z - a.z) * sz) / l2, 0.0, 1.0)
		var dx := pos.x - (a.x + sx * t)
		var dz := pos.z - (a.z + sz * t)
		var d := dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best_s = lerpf(dists[i], dists[i + 1], t)
	return Vector2(best_s, sqrt(best_d))


func _segment_at(s: float) -> int:
	# Двоичный поиск отрезка, содержащего расстояние s.
	var lo := 0
	var hi := dists.size() - 2
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if dists[mid] <= s:
			lo = mid
		else:
			hi = mid - 1
	return clampi(lo, 0, maxi(points.size() - 2, 0))
