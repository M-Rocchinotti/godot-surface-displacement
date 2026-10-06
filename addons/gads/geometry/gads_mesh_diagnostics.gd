@tool
class_name GADSMeshDiagnostics
extends RefCounted
## What a mesh's topology means for displacement, before baking it: the edges where its surface is
## cut (UV seams, hard edges, surface borders), where it is open or non-manifold, and degenerate
## triangles. The bake welds positions, so seams, hard edges and surface borders refine and move
## together (no cracks); open edges move with the surface (or stay with lock_borders), and
## non-manifold edges and degenerate triangles are where a displaced mesh can tear or fold.
##
## [method analyse] returns the counts and the edges as line segments; [method make_overlay] makes
## a line mesh of them (the GADSMeshInstance3D inspector's Diagnose button shows it in the editor).

enum EdgeKind { OPEN, NON_MANIFOLD, UV_SEAM, HARD, SURFACE_BORDER }

const KIND_NAMES := ["open", "non_manifold", "uv_seam", "hard", "surface_border"]
## Overlay colours per EdgeKind.
const KIND_COLORS := [Color(1.0, 0.2, 0.2), Color(1.0, 0.2, 1.0), Color(1.0, 0.85, 0.1), Color(0.2, 0.9, 1.0), Color(0.4, 1.0, 0.4)]


## {"triangles", "vertices" (welded positions), "surfaces", "degenerate" (triangles of no area),
## "missing_uv": [surface indices without UVs], "counts": {kind name: edges}, "segments": {kind name:
## PackedVector3Array of segment end points, two per edge}, "notes": [String]}. Positions closer
## than [param weld] (m; < 0: 1e-6 of the mesh size) are one; source normals further apart than
## [param hard_angle_deg] make a hard edge.
static func analyse(mesh: Mesh, weld := -1.0, hard_angle_deg := 30.0) -> Dictionary:
	var out := {"triangles": 0, "vertices": 0, "surfaces": 0, "degenerate": 0, "missing_uv": [], "counts": {}, "segments": {}, "notes": []}
	for k in KIND_NAMES:
		out["counts"][k] = 0
		out["segments"][k] = PackedVector3Array()
	if mesh == null:
		return out
	out["surfaces"] = mesh.get_surface_count()
	if weld < 0.0:
		weld = maxf(mesh.get_aabb().get_longest_axis_size() * 1e-6, 1e-9)
	var cos_hard := cos(deg_to_rad(hard_angle_deg))
	var positions := {} # snapped position -> welded index
	var welded_pos: Array[Vector3] = []
	# Edge (welded a, b; a < b) -> list of [surface, triangle corner a, corner b] (corner: [uv, normal])
	var edges := {}
	for s in mesh.get_surface_count():
		if GADSMeshBaker.surface_primitive(mesh, s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if idx.is_empty():
			idx.resize(v.size())
			for i in v.size():
				idx[i] = i
		if uv.is_empty():
			(out["missing_uv"] as Array).append(s)
		var ids := PackedInt32Array()
		ids.resize(v.size())
		for i in v.size():
			var key := (v[i] / weld).round()
			if not positions.has(key):
				positions[key] = welded_pos.size()
				welded_pos.append(v[i])
			ids[i] = positions[key]
		for t in range(0, idx.size() - 2, 3):
			out["triangles"] += 1
			var c := [idx[t], idx[t + 1], idx[t + 2]]
			var a: Vector3 = v[c[0]]
			if (v[c[1]] - a).cross(v[c[2]] - a).length_squared() <= weld * weld * 1e-6 or ids[c[0]] == ids[c[1]] or ids[c[1]] == ids[c[2]] or ids[c[0]] == ids[c[2]]:
				out["degenerate"] += 1
				continue
			for k in 3:
				var i0: int = c[k]
				var i1: int = c[(k + 1) % 3]
				var g0 := ids[i0]
				var g1 := ids[i1]
				if g0 > g1:
					var tmp := i0
					i0 = i1
					i1 = tmp
					var tg := g0
					g0 = g1
					g1 = tg
				var e := Vector2i(g0, g1)
				if not edges.has(e):
					edges[e] = []
				(edges[e] as Array).append([s, uv[i0] if not uv.is_empty() else Vector2.INF, uv[i1] if not uv.is_empty() else Vector2.INF,
					nrm[i0] if not nrm.is_empty() else Vector3.ZERO, nrm[i1] if not nrm.is_empty() else Vector3.ZERO])
	out["vertices"] = welded_pos.size()
	for e: Vector2i in edges:
		var uses: Array = edges[e]
		var kind := -1
		if uses.size() == 1:
			kind = EdgeKind.OPEN
		elif uses.size() > 2:
			kind = EdgeKind.NON_MANIFOLD
		else:
			var u: Array = uses[0]
			var w: Array = uses[1]
			if u[0] != w[0]:
				kind = EdgeKind.SURFACE_BORDER
			elif not (u[1] as Vector2).is_equal_approx(w[1]) or not (u[2] as Vector2).is_equal_approx(w[2]):
				kind = EdgeKind.UV_SEAM
			elif (u[3] as Vector3) != Vector3.ZERO and ((u[3] as Vector3).dot(w[3]) < cos_hard or (u[4] as Vector3).dot(w[4]) < cos_hard):
				kind = EdgeKind.HARD
		if kind < 0:
			continue
		var name: String = KIND_NAMES[kind]
		out["counts"][name] += 1
		# Packed arrays are values: append to the dictionary's own copy and put it back.
		var segments: PackedVector3Array = out["segments"][name]
		segments.append(welded_pos[e.x])
		segments.append(welded_pos[e.y])
		out["segments"][name] = segments
	var notes: Array = out["notes"]
	if out["counts"]["non_manifold"] > 0:
		notes.append("%d non-manifold edges (three or more triangles on one edge): the bake treats them as borders; displaced, the mesh can tear there." % out["counts"]["non_manifold"])
	if out["degenerate"] > 0:
		notes.append("%d degenerate triangles (no area): the bake skips them." % out["degenerate"])
	if not (out["missing_uv"] as Array).is_empty():
		notes.append("Surfaces without UVs %s: a UV-mapped GADS material cannot place its height map there (world-planar and triplanar mappings need none)." % [out["missing_uv"]])
	if out["counts"]["open"] > 0:
		notes.append("%d open edges: they move with the surface (lock_borders keeps them where they are, for meshes that tile)." % out["counts"]["open"])
	return out


## A line mesh of [param report]'s edges ([method analyse]) as coloured lines (open red,
## non-manifold magenta, UV seams yellow, hard edges cyan, surface borders green); draw it with
## [method overlay_material] to see them through the surface.
static func make_overlay(report: Dictionary) -> ArrayMesh:
	var points := PackedVector3Array()
	var colors := PackedColorArray()
	for kind in KIND_NAMES.size():
		var segments: PackedVector3Array = report["segments"][KIND_NAMES[kind]]
		points.append_array(segments)
		for i in segments.size():
			colors.append(KIND_COLORS[kind])
	var mesh := ArrayMesh.new()
	if points.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## A material for [method make_overlay]: unshaded vertex colours, drawn over everything.
static func overlay_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.no_depth_test = true
	m.render_priority = 10
	return m


## One line per edge kind with its count, and the notes.
static func summary(report: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("%d triangles, %d positions, %d surfaces." % [report["triangles"], report["vertices"], report["surfaces"]])
	var parts := PackedStringArray()
	for name in KIND_NAMES:
		if report["counts"][name] > 0:
			parts.append("%s %d" % [String(name).replace("_", " "), report["counts"][name]])
	lines.append("Edges: " + (", ".join(parts) if not parts.is_empty() else "closed, no seams or hard edges") + ".")
	for n: String in report["notes"]:
		lines.append(n)
	return "\n".join(lines)
