class_name GADSTessellatorGD
extends RefCounted
## The bake's tessellator in GDScript, for platforms without the GADS native library (macOS,
## mobile, web): the same interface as the native GADSTessellator, slower and simpler. Edges
## whose midpoint (or quarter points) leave the straight line between their ends' relief by more
## than max_error are split (and triangles whose centre leaves their plane split their longest
## edge), in rounds until nothing is left to split or the triangle budget is reached; a triangle
## splits into two, three or four as its edges are split, so neighbours always match. Relief is
## evaluated once per welded position (UV seams and hard edges do not open), along the welded
## positions' averaged normals (or the axis, for world-planar materials). Not supported here:
## vector displacement, blend shapes, skinned meshes, clusters, view-dependent tessellation and
## curvature-aware subdivision (bakes that need them report it).

const VERSION := "gd-1"
## Longer edges (in main-map texels) are split whatever the samples say: a bump narrower than
## the samples' spacing on a long edge is found as the edges shorten.
const MAX_EDGE_TEXELS := 32.0

var _maps: Array[Dictionary] = [] # {"w", "h", "data": PackedFloat32Array (red channel)}
var _surfaces: Array[Dictionary] = [] # {"arrays", "d"}
var _xform := Transform3D.IDENTITY
var _offset := {} # the sculpt map, as _maps' entries
var _settings := {}
var _error := ""
var _unsupported := ""
var _cancelled := false
var _progress := 0.0
var _triangles := 0
var _stats := {}
var _out: Array = []


func add_height_map(image: Image) -> int:
	_maps.append(_map_of(image))
	return _maps.size() - 1


func add_vector_map(_image: Image) -> Array:
	_unsupported = "vector displacement"
	return [-1, -1, -1]


func set_blend_shapes(_surface: int, _arrays: Array, _relative: bool) -> void:
	_unsupported = "blend shapes"


func add_surface(arrays: Array, displacement: Dictionary) -> void:
	if arrays[Mesh.ARRAY_BONES] != null and not (arrays[Mesh.ARRAY_BONES] as PackedInt32Array).is_empty():
		_unsupported = "skinned meshes"
	_surfaces.append({"arrays": arrays, "d": displacement})


func set_transform(xform: Transform3D) -> void:
	_xform = xform


func set_offset_map(image: Image) -> void:
	_offset = _map_of(image)


func set_settings(settings: Dictionary) -> void:
	_settings = settings
	if settings.get("view_dependent", false):
		_unsupported = "view-dependent tessellation"


func cancel() -> void:
	_cancelled = true


func get_progress() -> float:
	return _progress


func get_triangle_count() -> int:
	return _triangles


func get_stats() -> Dictionary:
	return _stats


func get_error() -> String:
	return _error


func get_surfaces() -> Array:
	return _out


func get_cluster_surfaces(_target: int) -> Array:
	return [_out]


static func _map_of(image: Image) -> Dictionary:
	var img := image.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RF)
	return {"w": img.get_width(), "h": img.get_height(), "data": img.get_data().to_float32_array()}


## Bilinear, repeating (height maps tile).
static func _sample(m: Dictionary, uv: Vector2) -> float:
	var w: int = m["w"]
	var h: int = m["h"]
	var data: PackedFloat32Array = m["data"]
	var x := uv.x * w - 0.5
	var y := uv.y * h - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var xa := posmod(x0, w)
	var xb := posmod(x0 + 1, w)
	var ya := posmod(y0, h) * w
	var yb := posmod(y0 + 1, h) * w
	return lerpf(lerpf(data[ya + xa], data[ya + xb], fx), lerpf(data[yb + xa], data[yb + xb], fx), fy)


## Bilinear, clamped (the sculpt map covers the mesh's own UVs once).
static func _sample_clamped(m: Dictionary, uv: Vector2) -> float:
	var w: int = m["w"]
	var h: int = m["h"]
	var data: PackedFloat32Array = m["data"]
	var x := clampf(uv.x * w - 0.5, 0.0, w - 1.0)
	var y := clampf(uv.y * h - 0.5, 0.0, h - 1.0)
	var x0 := mini(floori(x), maxi(w - 2, 0))
	var y0 := mini(floori(y), maxi(h - 2, 0))
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var fx := x - x0
	var fy := y - y0
	return lerpf(lerpf(data[y0 * w + x0], data[y0 * w + x1], fx), lerpf(data[y1 * w + x0], data[y1 * w + x1], fx), fy)


static func _remap(h: float, remap: Vector2) -> float:
	var span := remap.y - remap.x
	span = 1e-5 if absf(span) < 1e-5 else span
	return clampf((h - remap.x) / span, 0.0, 1.0)


static func _height_blend(below: float, above: float, m: float, width: float) -> float:
	if m <= 0.0:
		return 0.0
	if m >= 1.0:
		return 1.0
	return smoothstep(-width, width, above - below + (2.0 * m - 1.0) * (1.0 + width))


static func _triplanar_weights(n: Vector3, sharpness: float) -> Array[float]:
	var w: Array[float] = [pow(absf(n.x), sharpness), pow(absf(n.y), sharpness), pow(absf(n.z), sharpness)]
	var sum := maxf(w[0] + w[1] + w[2], 1e-6)
	for k in 3:
		w[k] /= sum
		w[k] = 0.0 if w[k] < 0.05 else w[k]
	sum = maxf(w[0] + w[1] + w[2], 1e-6)
	for k in 3:
		w[k] /= sum
	return w


static func _planar_uv(d: Dictionary, plane: int, world: Vector3, n: Vector3) -> Vector2:
	var offset: Vector2 = d.get("planar_offset_m", Vector2.ZERO)
	var size: Vector2 = d.get("texture_size_m", Vector2(2, 2))
	var q := world - Vector3(offset.x, 0.0, offset.y)
	var gu: Vector3
	var gv: Vector3
	if plane < 0:
		var r := deg_to_rad(float(d.get("rotation_deg", 0.0)))
		gu = Vector3(cos(r), 0.0, -sin(r)) / size.x
		gv = Vector3(sin(r), 0.0, cos(r)) / size.y
	else:
		var right: Vector3
		var up: Vector3
		if plane == 0:
			right = Vector3(0, 0, -1.0 if n.x >= 0.0 else 1.0)
			up = Vector3.UP
		elif plane == 1:
			right = Vector3.RIGHT
			up = Vector3(0, 0, -1.0 if n.y >= 0.0 else 1.0)
		else:
			right = Vector3(1.0 if n.z >= 0.0 else -1.0, 0, 0)
			up = Vector3.UP
		gu = right / size.x
		gv = -up / size.y
	return Vector2(gu.dot(q), gv.dot(q))


## The relief (m) of one projection at main-map uv [param uv], with the layers' masks.
func _relief_at(d: Dictionary, uv: Vector2, masks: Array[float]) -> float:
	var h := _remap(_sample(_maps[d["height_map"]], uv), d.get("remap", Vector2(0, 1)))
	var center := float(d.get("center", 1.0))
	var relief := float(d["height_m"]) * (h - center)
	var detail := int(d.get("detail_height_map", -1))
	if detail >= 0 and float(d.get("detail_height_m", 0.0)) != 0.0:
		relief += float(d["detail_height_m"]) * (_sample(_maps[detail], uv * float(d.get("detail_scale", 8.0))) - 0.5)
	var layers: Array = d.get("layers", [])
	for k in mini(layers.size(), 2):
		if masks[k] <= 0.0:
			continue
		var l: Dictionary = layers[k]
		var hk := _sample(_maps[l["height_map"]], uv * float(l.get("scale", 1.0)))
		var t := _height_blend(h, hk, masks[k], float(l.get("blend_width", 0.1)))
		relief += (float(l["height_m"]) * (hk - center) - relief) * t
		h += (hk - h) * t
	return relief


## The displacement (m) at a vertex: the material's relief there (its mapping, the layers by the
## vertex colour, the displacement mask), plus the sculpt offset at the source uv.
func _displacement(d: Dictionary, world: Vector3, dir: Vector3, uv: Vector2, color: Color) -> float:
	var offset := _sample_clamped(_offset, uv) if not _offset.is_empty() else 0.0
	if d.is_empty() or int(d.get("height_map", -1)) < 0:
		return offset
	var channel := int(d.get("relief_mask_channel", -1))
	var mask := clampf(color[channel], 0.0, 1.0) if channel >= 0 and channel < 4 else 1.0
	if mask <= 0.0:
		return offset
	var masks: Array[float] = [0.0, 0.0]
	var layers: Array = d.get("layers", [])
	for k in mini(layers.size(), 2):
		var l: Dictionary = layers[k]
		if int(l.get("height_map", -1)) < 0 or float(l.get("amount", 0.0)) <= 0.0:
			continue
		var ch := int(l.get("mask_channel", k))
		var m: float = (color[ch] if ch >= 0 and ch < 4 else 1.0) * float(l["amount"])
		var slope: Vector2 = l.get("slope", Vector2.ZERO)
		if slope.y > slope.x:
			m *= smoothstep(slope.x, slope.y, dir.y)
		masks[k] = m
	var mapping := int(d.get("mapping", GADSMaterials.Mapping.UV))
	if mapping == GADSMaterials.Mapping.UV:
		var scale: Vector2 = d.get("uv_scale", Vector2.ONE)
		var off: Vector2 = d.get("uv_offset", Vector2.ZERO)
		return offset + mask * _relief_at(d, uv * scale + off, masks)
	if mapping == GADSMaterials.Mapping.WORLD:
		return offset + mask * _relief_at(d, _planar_uv(d, -1, world, dir), masks)
	var w := _triplanar_weights(dir, float(d.get("triplanar_sharpness", 4.0)))
	var relief := 0.0
	for a in 3:
		if w[a] > 0.0:
			relief += w[a] * _relief_at(d, _planar_uv(d, a, world, dir), masks)
	return offset + mask * relief


## Texels of the main map an edge spans (its length in the map's own texels).
func _edge_texels(d: Dictionary, a: Dictionary, b: Dictionary) -> float:
	if d.is_empty() or int(d.get("height_map", -1)) < 0:
		if _offset.is_empty():
			return 0.0
		return ((a["uv"] - b["uv"]) as Vector2).length() * maxf(_offset["w"], _offset["h"])
	var m: Dictionary = _maps[d["height_map"]]
	var size := maxf(m["w"], m["h"])
	if int(d.get("mapping", 0)) == GADSMaterials.Mapping.UV:
		var scale: Vector2 = d.get("uv_scale", Vector2.ONE)
		return (((a["uv"] - b["uv"]) as Vector2) * scale).length() * size
	var tsize: Vector2 = d.get("texture_size_m", Vector2(2, 2))
	return (_xform * (a["p"] as Vector3)).distance_to(_xform * (b["p"] as Vector3)) / minf(tsize.x, tsize.y) * size


func run() -> bool:
	var t0 := Time.get_ticks_msec()
	if not _unsupported.is_empty():
		_error = "the GADS native library is needed for %s (this platform bakes with the GDScript tessellator)" % _unsupported
		return false
	var max_error := float(_settings.get("max_error", 0.0005))
	var min_texels := maxf(float(_settings.get("min_edge_texels", 1.0)), 0.25)
	var max_triangles := int(_settings.get("max_triangles", 500000))
	var max_level := int(_settings.get("max_level", 24))
	var lock_borders := bool(_settings.get("lock_borders", false))
	var geometry_normals := bool(_settings.get("geometry_normals", true))
	var mode := int(_settings.get("direction_mode", 0))
	var axis: Vector3 = _settings.get("direction", Vector3.UP)
	var all_world := true
	for s in _surfaces:
		var d: Dictionary = s["d"]
		if not d.is_empty() and int(d.get("mapping", 0)) != GADSMaterials.Mapping.WORLD:
			all_world = false
	var use_axis := mode == 2 or (mode == 0 and all_world and not _surfaces.is_empty())
	var normal_basis := _xform.basis.inverse().transposed()
	var to_object := _xform.affine_inverse()
	var weld := maxf(float(_settings.get("weld_distance", -1.0)), 0.0)
	if weld <= 0.0:
		var aabb := AABB()
		for s in _surfaces:
			for p: Vector3 in s["arrays"][Mesh.ARRAY_VERTEX]:
				aabb = aabb.expand(p)
		weld = maxf(aabb.get_longest_axis_size() * 1e-6, 1e-9)
	# Welded positions over every surface: id -> {"dir": sum of world normals, "border"}.
	var wid_of := {}
	var welded: Array[Dictionary] = []
	var source_triangles := 0
	var meshes: Array[Dictionary] = []
	for s in _surfaces:
		var arrays: Array = s["arrays"]
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: Variant = arrays[Mesh.ARRAY_NORMAL]
		var uv: Variant = arrays[Mesh.ARRAY_TEX_UV]
		var uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
		var col: Variant = arrays[Mesh.ARRAY_COLOR]
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		var indices := PackedInt32Array(idx) if idx != null else PackedInt32Array(range(pos.size()))
		var verts: Array[Dictionary] = []
		for i in pos.size():
			var key := Vector3i((pos[i] / weld).round())
			if not wid_of.has(key):
				wid_of[key] = welded.size()
				welded.append({"dir": Vector3.ZERO})
			var n: Vector3 = (nrm as PackedVector3Array)[i] if nrm != null and i < (nrm as PackedVector3Array).size() else Vector3.ZERO
			var v := {"p": pos[i], "n": n, "uv": (uv as PackedVector2Array)[i] if uv != null and i < (uv as PackedVector2Array).size() else Vector2.ZERO,
				"uv2": (uv2 as PackedVector2Array)[i] if uv2 != null and i < (uv2 as PackedVector2Array).size() else Vector2.ZERO,
				"c": (col as PackedColorArray)[i] if col != null and i < (col as PackedColorArray).size() else Color.WHITE,
				"w": wid_of[key], "level": 0}
			verts.append(v)
		var tris := PackedInt32Array()
		for t in range(0, indices.size() - 2, 3):
			var a := indices[t]
			var b := indices[t + 1]
			var c := indices[t + 2]
			var face := (pos[b] - pos[a]).cross(pos[c] - pos[a])
			if face.length_squared() <= 0.0:
				continue
			tris.append_array([a, b, c])
			for k in [a, b, c]:
				var n: Vector3 = verts[k]["n"]
				if n.is_zero_approx():
					n = -face.normalized() # Godot's front faces wind clockwise
				welded[verts[k]["w"]]["dir"] += (normal_basis * n).normalized()
		source_triangles += tris.size() / 3
		meshes.append({"verts": verts, "tris": tris, "d": s["d"], "has_uv": uv != null, "has_uv2": uv2 != null, "has_color": col != null})
	# Open edges (one triangle on them, counted on welded positions) for lock_borders.
	var edge_use := {}
	for m in meshes:
		var verts: Array[Dictionary] = m["verts"]
		var tris: PackedInt32Array = m["tris"]
		for t in range(0, tris.size(), 3):
			for e in 3:
				var key := _edge_key(verts[tris[t + e]]["w"], verts[tris[t + (e + 1) % 3]]["w"])
				edge_use[key] = int(edge_use.get(key, 0)) + 1
	var border := {}
	if lock_borders:
		for key: Vector2i in edge_use:
			if edge_use[key] == 1:
				border[key.x] = true
				border[key.y] = true
	var dir_of := func(w: int) -> Vector3:
		if use_axis:
			return axis.normalized()
		var d: Vector3 = welded[w]["dir"]
		return d.normalized() if not d.is_zero_approx() else Vector3.UP
	# Relief per welded position, evaluated from the first vertex that asks.
	var relief := {}
	var relief_of := func(m: Dictionary, v: Dictionary) -> float:
		var w: int = v["w"]
		if relief.has(w):
			return relief[w]
		var r := 0.0
		if not border.has(w):
			r = _displacement(m["d"], _xform * (v["p"] as Vector3), dir_of.call(w), v["uv"], v["c"])
		relief[w] = r
		return r
	# Rounds of splitting.
	_triangles = source_triangles
	var rounds := 0
	var budget_reached := false
	var mid_wid := {} # welded edge -> the welded id of its midpoint
	var decisions := {} # welded edge -> split? (an edge's decision never changes)
	while rounds < max_level and not _cancelled:
		var any := false
		var new_count := 0
		var marks: Array = []
		for m in meshes:
			var verts: Array[Dictionary] = m["verts"]
			var tris: PackedInt32Array = m["tris"]
			var d: Dictionary = m["d"]
			var mark := PackedByteArray()
			mark.resize(tris.size() / 3)
			for t in range(0, tris.size(), 3):
				var bits := 0
				var longest := -1
				var longest_len := -1.0
				for e in 3:
					var a: Dictionary = verts[tris[t + e]]
					var b: Dictionary = verts[tris[t + (e + 1) % 3]]
					var key := _edge_key(a["w"], b["w"])
					var texels := _edge_texels(d, a, b)
					if texels > longest_len:
						longest_len = texels
						longest = e
					if not decisions.has(key):
						var split := texels > MAX_EDGE_TEXELS and not (d.is_empty() and _offset.is_empty())
						if not split and texels > min_texels:
							var ra: float = relief_of.call(m, a)
							var rb: float = relief_of.call(m, b)
							for f in [0.25, 0.5, 0.75]:
								var q := _lerp_vertex(a, b, f)
								var err := absf(_displacement(d, _xform * (q["p"] as Vector3), dir_of.call(a["w"]).lerp(dir_of.call(b["w"]), f).normalized(), q["uv"], q["c"]) - lerpf(ra, rb, f))
								if err > max_error:
									split = true
									break
						decisions[key] = split
					if decisions[key]:
						bits |= 1 << e
				if bits == 0 and longest_len > min_texels:
					# A bump inside the triangle that no edge sees: split its longest edge.
					var a: Dictionary = verts[tris[t]]
					var b: Dictionary = verts[tris[t + 1]]
					var c: Dictionary = verts[tris[t + 2]]
					var centre := _lerp_vertex(_lerp_vertex(a, b, 0.5), c, 1.0 / 3.0)
					var planar := (float(relief_of.call(m, a)) + float(relief_of.call(m, b)) + float(relief_of.call(m, c))) / 3.0
					var dir: Vector3 = (dir_of.call(a["w"]) + dir_of.call(b["w"]) + dir_of.call(c["w"])).normalized()
					var err := absf(_displacement(d, _xform * (centre["p"] as Vector3), dir, centre["uv"], centre["c"]) - planar)
					if err > max_error:
						var key := _edge_key(verts[tris[t + longest]]["w"], verts[tris[t + (longest + 1) % 3]]["w"])
						decisions[key] = true
				mark[t / 3] = bits
			marks.append(mark)
		# Marks again with the decisions of this round complete (a triangle's longest edge may have
		# been decided by its neighbour's centre test).
		for mi in meshes.size():
			var m: Dictionary = meshes[mi]
			var verts: Array[Dictionary] = m["verts"]
			var tris: PackedInt32Array = m["tris"]
			var mark: PackedByteArray = marks[mi]
			for t in range(0, tris.size(), 3):
				var bits := 0
				for e in 3:
					if decisions.get(_edge_key(verts[tris[t + e]]["w"], verts[tris[t + (e + 1) % 3]]["w"]), false):
						bits |= 1 << e
				mark[t / 3] = bits
				new_count += [0, 1, 1, 2, 1, 2, 2, 3][bits]
				any = any or bits != 0
			marks[mi] = mark
		if not any:
			break
		if _triangles + new_count > max_triangles:
			budget_reached = true
			break
		rounds += 1
		# Split.
		for mi in meshes.size():
			var m: Dictionary = meshes[mi]
			var verts: Array[Dictionary] = m["verts"]
			var tris: PackedInt32Array = m["tris"]
			var mark: PackedByteArray = marks[mi]
			var mid_of := {} # vertex index pair -> midpoint index (this surface)
			var out := PackedInt32Array()
			for t in range(0, tris.size(), 3):
				var bits := mark[t / 3]
				var a := tris[t]
				var b := tris[t + 1]
				var c := tris[t + 2]
				if bits == 0:
					out.append_array([a, b, c])
					continue
				var mab := _midpoint(verts, mid_of, mid_wid, welded, a, b, rounds) if bits & 1 else -1
				var mbc := _midpoint(verts, mid_of, mid_wid, welded, b, c, rounds) if bits & 2 else -1
				var mca := _midpoint(verts, mid_of, mid_wid, welded, c, a, rounds) if bits & 4 else -1
				match bits:
					1:
						out.append_array([a, mab, c, mab, b, c])
					2:
						out.append_array([a, b, mbc, a, mbc, c])
					4:
						out.append_array([a, b, mca, mca, b, c])
					3:
						out.append_array([a, mab, mbc, mab, b, mbc, a, mbc, c])
					6:
						out.append_array([a, b, mbc, a, mbc, mca, mca, mbc, c])
					5:
						out.append_array([a, mab, mca, mab, b, c, mab, c, mca])
					7:
						out.append_array([a, mab, mca, mab, b, mbc, mca, mbc, c, mab, mbc, mca])
			m["tris"] = out
		_triangles += new_count
		_progress = minf(0.95, float(rounds) / maxf(max_level, 1))
	if _cancelled:
		_error = "cancelled"
		return false
	# Displace, normals, rest data.
	_out.clear()
	var vertex_count := 0
	for m in meshes:
		var verts: Array[Dictionary] = m["verts"]
		var tris: PackedInt32Array = m["tris"]
		var count := verts.size()
		var positions := PackedVector3Array()
		positions.resize(count)
		var rest_dirs := PackedVector3Array()
		rest_dirs.resize(count)
		for i in count:
			var v: Dictionary = verts[i]
			var dir: Vector3 = dir_of.call(v["w"])
			var world := _xform * (v["p"] as Vector3) + dir * float(relief_of.call(m, v))
			positions[i] = to_object * world
			rest_dirs[i] = (_xform.basis.transposed() * dir).normalized()
		var normals := PackedVector3Array()
		normals.resize(count)
		if geometry_normals:
			# Area-weighted face normals, shared by the vertices of a welded position with the same
			# source normal (UV seams stay smooth, hard edges stay hard).
			var acc := {}
			for t in range(0, tris.size(), 3):
				var face := (positions[tris[t + 2]] - positions[tris[t]]).cross(positions[tris[t + 1]] - positions[tris[t]])
				for k in 3:
					var key := _normal_key(verts[tris[t + k]])
					acc[key] = acc.get(key, Vector3.ZERO) + face
			for i in count:
				var n: Vector3 = acc.get(_normal_key(verts[i]), Vector3.ZERO)
				normals[i] = n.normalized() if not n.is_zero_approx() else (verts[i]["n"] as Vector3)
		else:
			for i in count:
				normals[i] = (verts[i]["n"] as Vector3).normalized()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = normals
		var custom0 := PackedFloat32Array()
		custom0.resize(count * 4)
		var custom1 := PackedFloat32Array()
		custom1.resize(count * 4)
		var uvs := PackedVector2Array()
		var uv2s := PackedVector2Array()
		var colors := PackedColorArray()
		for i in count:
			var v: Dictionary = verts[i]
			var p: Vector3 = v["p"]
			custom0[i * 4] = p.x
			custom0[i * 4 + 1] = p.y
			custom0[i * 4 + 2] = p.z
			custom1[i * 4] = rest_dirs[i].x
			custom1[i * 4 + 1] = rest_dirs[i].y
			custom1[i * 4 + 2] = rest_dirs[i].z
			custom1[i * 4 + 3] = float(v["level"]) / 32.0
			uvs.append(v["uv"])
			uv2s.append(v["uv2"])
			colors.append(v["c"])
		arrays[Mesh.ARRAY_CUSTOM0] = custom0
		arrays[Mesh.ARRAY_CUSTOM1] = custom1
		if m["has_uv"]:
			arrays[Mesh.ARRAY_TEX_UV] = uvs
		if m["has_uv2"]:
			arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		if m["has_color"]:
			arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = tris
		arrays[Mesh.ARRAY_TANGENT] = _tangents(positions, normals, uvs if m["has_uv"] else PackedVector2Array(), tris)
		_out.append(arrays)
		vertex_count += count
	_progress = 1.0
	_stats = {"source_triangles": source_triangles, "triangles": _triangles, "vertices": vertex_count, "rounds": rounds,
		"max_level": rounds, "budget_reached": budget_reached, "max_error_left": max_error if budget_reached else 0.0,
		"max_pixels_left": 0.0, "milliseconds": Time.get_ticks_msec() - t0, "tessellator": VERSION}
	return true


static func _edge_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


static func _normal_key(v: Dictionary) -> Array:
	return [v["w"], Vector3i(((v["n"] as Vector3) * 1000.0).round())]


static func _lerp_vertex(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	return {"p": (a["p"] as Vector3).lerp(b["p"], f), "n": (a["n"] as Vector3).lerp(b["n"], f).normalized(),
		"uv": (a["uv"] as Vector2).lerp(b["uv"], f), "uv2": (a["uv2"] as Vector2).lerp(b["uv2"], f),
		"c": (a["c"] as Color).lerp(b["c"], f)}


## The midpoint vertex of edge (a, b) of a surface (made once, shared by both triangles on it),
## welded with every other midpoint of the same welded edge.
static func _midpoint(verts: Array[Dictionary], mid_of: Dictionary, mid_wid: Dictionary, welded: Array[Dictionary], a: int, b: int, level: int) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if mid_of.has(key):
		return mid_of[key]
	var va: Dictionary = verts[a]
	var vb: Dictionary = verts[b]
	var v := _lerp_vertex(va, vb, 0.5)
	var wkey := _edge_key(va["w"], vb["w"])
	if not mid_wid.has(wkey):
		mid_wid[wkey] = welded.size()
		welded.append({"dir": (welded[va["w"]]["dir"] as Vector3).normalized() + (welded[vb["w"]]["dir"] as Vector3).normalized()})
	v["w"] = mid_wid[wkey]
	v["level"] = level
	verts.append(v)
	mid_of[key] = verts.size() - 1
	return verts.size() - 1


## Tangents (xyz, sign) from the UVs, per vertex (MikkTSpace-like accumulation); without UVs any
## direction across the normal.
static func _tangents(positions: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, tris: PackedInt32Array) -> PackedFloat32Array:
	var count := positions.size()
	var tan := PackedVector3Array()
	tan.resize(count)
	var bit := PackedVector3Array()
	bit.resize(count)
	if not uvs.is_empty():
		for t in range(0, tris.size(), 3):
			var i0 := tris[t]
			var i1 := tris[t + 1]
			var i2 := tris[t + 2]
			var e1 := positions[i1] - positions[i0]
			var e2 := positions[i2] - positions[i0]
			var d1 := uvs[i1] - uvs[i0]
			var d2 := uvs[i2] - uvs[i0]
			var r := d1.x * d2.y - d2.x * d1.y
			if absf(r) < 1e-20:
				continue
			var tu := (e1 * d2.y - e2 * d1.y) / r
			var tv := (e2 * d1.x - e1 * d2.x) / r
			for i in [i0, i1, i2]:
				tan[i] += tu
				bit[i] += tv
	var out := PackedFloat32Array()
	out.resize(count * 4)
	for i in count:
		var n := normals[i]
		var t := tan[i] - n * n.dot(tan[i])
		if t.length_squared() < 1e-20:
			t = (Vector3.UP if absf(n.y) < 0.999 else Vector3.RIGHT).cross(n)
		t = t.normalized()
		out[i * 4] = t.x
		out[i * 4 + 1] = t.y
		out[i * 4 + 2] = t.z
		out[i * 4 + 3] = -1.0 if n.cross(t).dot(bit[i]) < 0.0 else 1.0
	return out
