@tool
class_name GADSSculpt
extends RefCounted
## Sculpting a GADSMeshInstance3D's surface: brush dabs on its sculpt map, a float image (metres,
## along the displacement direction) in the source mesh's own first UVs, which the bake adds to
## the materials' relief. Raise, lower, smooth and flatten, with a smooth falloff. The inspector's
## Sculpt tool paints with these in the 3D viewport; scripts can call them too:
## [codeblock]
## GADSSculpt.dab(node.get_sculpt_image(), Vector2(0.5, 0.5), 0.05, GADSSculpt.Mode.RAISE, 0.01)
## node.sculpt_changed()   # stores the map and bakes again
## [/codeblock]

enum Mode { RAISE, LOWER, SMOOTH, FLATTEN }

const MODE_NAMES := ["Raise", "Lower", "Smooth", "Flatten"]

## The editor's Sculpt tool (set by the GADSMeshInstance3D inspector, read by the plugin): whether it
## is on, the node it paints, its mode, brush radius (m) and strength (m per dab for Raise and
## Lower).
static var tool_active := false
static var tool_node: GADSMeshInstance3D
static var tool_mode := Mode.RAISE
static var tool_radius := 0.1
static var tool_strength := 0.002


## A new, flat sculpt map of [param size] x [param size] texels (FORMAT_RF).
static func new_image(size := 512) -> Image:
	return Image.create(size, size, false, Image.FORMAT_RF)


## Applies one brush dab to [param image] (FORMAT_RF, metres) at [param uv] (0..1) with
## [param radius] in uv units: RAISE / LOWER add or remove up to [param strength] metres at the
## centre, SMOOTH moves texels towards the average around them and FLATTEN towards the height at
## the centre, by up to [param strength] (0..1) of the way. The falloff is smooth (1 at the centre,
## 0 at the radius). [param flatten_to] overrides the height FLATTEN levels to (NAN: the
## centre's). Returns the rectangle of texels it changed.
static func dab(image: Image, uv: Vector2, radius: float, mode: Mode, strength: float, flatten_to := NAN) -> Rect2i:
	var w := image.get_width()
	var h := image.get_height()
	var cx := uv.x * w - 0.5
	var cy := uv.y * h - 0.5
	var rx := maxf(radius * w, 0.5)
	var ry := maxf(radius * h, 0.5)
	var x0 := clampi(floori(cx - rx), 0, w - 1)
	var x1 := clampi(ceili(cx + rx), 0, w - 1)
	var y0 := clampi(floori(cy - ry), 0, h - 1)
	var y1 := clampi(ceili(cy + ry), 0, h - 1)
	var data := image.get_data().to_float32_array()
	var target := flatten_to
	if mode == Mode.FLATTEN and is_nan(target):
		target = data[clampi(roundi(cy), 0, h - 1) * w + clampi(roundi(cx), 0, w - 1)]
	var source := data if mode != Mode.SMOOTH else data.duplicate()
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2((x - cx) / rx, (y - cy) / ry).length()
			if d >= 1.0:
				continue
			var f := 1.0 - d * d
			f = f * f # smooth to 0 at the rim
			var i := y * w + x
			match mode:
				Mode.RAISE:
					data[i] += strength * f
				Mode.LOWER:
					data[i] -= strength * f
				Mode.SMOOTH:
					var sum := 0.0
					var n := 0
					for oy in range(-2, 3):
						for ox in range(-2, 3):
							var sx := clampi(x + ox, 0, w - 1)
							var sy := clampi(y + oy, 0, h - 1)
							sum += source[sy * w + sx]
							n += 1
					data[i] = lerpf(source[i], sum / n, clampf(strength, 0.0, 1.0) * f)
				Mode.FLATTEN:
					data[i] = lerpf(data[i], target, clampf(strength, 0.0, 1.0) * f)
	image.set_data(w, h, false, Image.FORMAT_RF, data.to_byte_array())
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)


## Where the ray from [param origin] along [param direction] (both in the mesh's space) first hits
## [param mesh]: {"uv" (first UV set), "uv_per_m" (uv units per metre of the mesh there),
## "position", "normal"}, or {} when it misses. [param cache] (a Dictionary kept between calls)
## holds the mesh's ray structure, so dabs along a stroke are cheap.
static func pick(mesh: Mesh, origin: Vector3, direction: Vector3, cache: Dictionary = {}) -> Dictionary:
	if mesh == null:
		return {}
	var entry: Array = cache.get(mesh, [])
	if entry.is_empty():
		if cache.size() > 4:
			cache.clear()
		var corner_uv := PackedVector2Array()
		var corner_pos := PackedVector3Array()
		for s in mesh.get_surface_count():
			if GADSMeshBaker.surface_primitive(mesh, s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.is_empty():
				idx.resize(v.size())
				for i in v.size():
					idx[i] = i
			for i in idx:
				corner_pos.append(v[i])
				corner_uv.append(uv[i] if not uv.is_empty() else Vector2.INF)
		entry = [mesh.generate_triangle_mesh(), corner_uv, corner_pos]
		cache[mesh] = entry
	var tm: TriangleMesh = entry[0]
	if tm == null:
		return {}
	var hit := tm.intersect_ray(origin, direction)
	if hit.is_empty():
		return {}
	var f: int = hit["face_index"]
	var uvs: PackedVector2Array = entry[1]
	var pos: PackedVector3Array = entry[2]
	if f < 0 or f * 3 + 2 >= uvs.size() or uvs[f * 3] == Vector2.INF:
		return {}
	var a := pos[f * 3]
	var b := pos[f * 3 + 1]
	var c := pos[f * 3 + 2]
	var p: Vector3 = hit["position"]
	var n := (b - a).cross(c - a)
	var area := n.length()
	if area < 1e-12:
		return {}
	var wa := (c - b).cross(p - b).dot(n) / (area * area)
	var wb := (a - c).cross(p - c).dot(n) / (area * area)
	var wc := 1.0 - wa - wb
	var ua := uvs[f * 3]
	var ub := uvs[f * 3 + 1]
	var uc := uvs[f * 3 + 2]
	var uv_area := absf((ub - ua).cross(uc - ua))
	return {"uv": ua * wa + ub * wb + uc * wc, "uv_per_m": sqrt(uv_area / area), "position": p, "normal": n / area}
