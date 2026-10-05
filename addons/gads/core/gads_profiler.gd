@tool
class_name GADSProfiler
extends RefCounted
## What the GADS content of a scene costs, object by object, and what to change: the editor's GADS
## panel and [GADSStatsOverlay] show it; scripts can use it for their own tools.
##
## [codeblock]
## var report := GADSProfiler.collect(get_tree().current_scene, get_viewport().get_camera_3d())
## print(report["totals"])
## for r in report["recommendations"]:
##     print(r["message"])
## GADSProfiler.apply_fixes(GADSProfiler.optimize_for(GADSProfiler.Target.HANDHELD, scene))
## [/codeblock]

## Hardware targets for [method optimize_for]: each sets the GADSManager preset and how many
## pixels of relief a baked mesh keeps its geometry for (geometry_range). Settings only: no asset
## is re-baked or changed.
enum Target { CINEMATIC, HIGH_END, MAINSTREAM, HANDHELD, MOBILE }

const TARGETS := {
	Target.CINEMATIC: {"name": "Cinematic (fastest GPUs)", "preset": GADSSettings.Preset.ULTRA, "relief_px": 1.0},
	Target.HIGH_END: {"name": "High-end PC", "preset": GADSSettings.Preset.HIGH, "relief_px": 1.5},
	Target.MAINSTREAM: {"name": "Mainstream PC", "preset": GADSSettings.Preset.MEDIUM, "relief_px": 2.0},
	Target.HANDHELD: {"name": "Handheld PC (Steam Deck class)", "preset": GADSSettings.Preset.LOW, "relief_px": 3.0},
	Target.MOBILE: {"name": "Mobile / integrated GPU", "preset": GADSSettings.Preset.OFF, "relief_px": 4.0},
}

## Thresholds of the recommendations: a baked mesh with more than dense_triangles covering under
## small_coverage of the screen is wasteful; one with more than range_triangles should have a
## geometry_range.
static var dense_triangles := 200000
static var small_coverage := 0.05
static var range_triangles := 50000


## Statistics of everything GADS draws under [param root]. With [param camera], screen coverage per
## baked mesh (else -1). Returns {"objects": Array of per-object Dictionaries (see below),
## "surfaces": parallax surfaces, "surface_triangles", "fields", "field_triangles", "totals":
## {"objects", "base_triangles", "generated_triangles", "active_triangles", "collision_triangles",
## "memory_bytes", "cache_bytes"}, "frame": {"fps", "cpu_ms", "gpu_ms", "primitives",
## "draw_calls", "video_memory_bytes"}, "manager": {"preset", "budget_ms"} or {},
## "height_maps": Array of {"texture", "size", "useful_size", "fine_fraction"},
## "recommendations": Array of {"level", "message", "object", "fix"}}.
##
## Per baked mesh: "node", "name", "baked", "stale", "base_triangles", "triangles",
## "max_triangles" (the budget), "collision_triangles", "depth_m", "tolerance_m", "error_left_m",
## "budget_reached", "coverage", "memory_bytes", "geometry_range".
static func collect(root: Node, camera: Camera3D = null) -> Dictionary:
	var report := {"objects": [], "surfaces": 0, "surface_triangles": 0, "fields": 0, "field_triangles": 0, "height_maps": [],
		"recommendations": [], "manager": {}}
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "", true, false))
	var height_textures := {}
	var cache_dirs := {}
	for node in nodes:
		if node is GADSMeshInstance3D:
			var entry := _object_stats(node as GADSMeshInstance3D, camera)
			report["objects"].append(entry)
			cache_dirs[(node as GADSMeshInstance3D).cache_directory] = true
		elif node is GeometryInstance3D:
			var gads_surfaces := 0
			for m in GADSMaterials.materials_of(node):
				if GADSMaterials.is_gads_material(m):
					gads_surfaces += 1
			if gads_surfaces > 0:
				report["surfaces"] += gads_surfaces
				if node is MeshInstance3D:
					report["surface_triangles"] += mesh_triangles((node as MeshInstance3D).mesh)
		if node is GADSDisplacementField3D:
			var field := node as GADSDisplacementField3D
			report["fields"] += 1
			report["field_triangles"] += 2 * field.resolution * field.resolution * field.levels
		if node is GADSManager:
			var manager := node as GADSManager
			report["manager"] = {"preset": manager.preset, "budget_ms": manager.get_budget_ms(), "node": manager}
		if node is GeometryInstance3D or node.is_class("CSGShape3D") or node.is_class("GridMap"):
			for m in GADSMaterials.materials_of(node):
				if GADSMaterials.is_gads_material(m):
					var tex := (m as ShaderMaterial).get_shader_parameter("height_texture") as Texture2D
					if tex != null:
						height_textures[tex] = true
	var totals := {"objects": report["objects"].size(), "base_triangles": 0, "generated_triangles": 0, "active_triangles": 0,
		"collision_triangles": 0, "memory_bytes": 0, "cache_bytes": 0}
	for o: Dictionary in report["objects"]:
		totals["base_triangles"] += o["base_triangles"]
		totals["active_triangles"] += o["triangles"]
		totals["generated_triangles"] += maxi(0, o["triangles"] - o["base_triangles"]) if o["baked"] else 0
		totals["collision_triangles"] += o["collision_triangles"]
		totals["memory_bytes"] += o["memory_bytes"]
	totals["active_triangles"] += report["surface_triangles"] + report["field_triangles"]
	for dir: String in cache_dirs:
		totals["cache_bytes"] += _directory_bytes(dir)
	report["totals"] = totals
	report["frame"] = _frame_stats(root)
	for tex: Texture2D in height_textures:
		var img := tex.get_image()
		if img == null or img.is_empty():
			continue
		var detail := GADSHeightTools.analyse_detail(img)
		report["height_maps"].append({"texture": tex, "size": img.get_width(), "useful_size": detail["useful_size"],
			"fine_fraction": detail["fine_fraction"]})
	report["recommendations"] = recommend(report)
	return report


## The recommendations for a report from [method collect]: each {"level": "warning" | "info",
## "message", "object" (or null), "fix": {} or {"object", "property", "value"} / {"object",
## "method", "args"}}.
static func recommend(report: Dictionary) -> Array:
	var out := []
	if report["manager"].is_empty() and (report["surfaces"] > 0 or not report["objects"].is_empty()):
		out.append(_rec("info", "No GADSManager node: materials keep the quality they were saved with and nothing scales them to the hardware.", null, {}))
	for o: Dictionary in report["objects"]:
		var node: GADSMeshInstance3D = o["node"]
		var name: String = o["name"]
		if not o["baked"]:
			out.append(_rec("info", "%s is not baked: it draws the source mesh with parallax." % name, node,
				{"object": node, "method": "bake", "args": []}))
			continue
		if o["stale"]:
			out.append(_rec("warning", "%s: its bake is stale (source, materials, settings or placement changed). Bake it again." % name, node,
				{"object": node, "method": "bake", "args": []}))
		var suggested := node.suggest_geometry_range()
		if o["coverage"] >= 0.0 and o["triangles"] > dense_triangles and o["coverage"] < small_coverage:
			var fix := {}
			if o["geometry_range"] <= 0.0 or o["geometry_range"] > suggested:
				fix = {"object": node, "property": "geometry_range", "value": snappedf(suggested, 0.1)}
			out.append(_rec("warning", "%s uses %s triangles but covers %.1f %% of the screen. %s" % [name, format_count(o["triangles"]),
				o["coverage"] * 100.0, "Draw it with parallax beyond %.1f m (geometry_range)." % suggested if not fix.is_empty()
				else "Lower its quality and bake again."], node, fix))
		elif o["geometry_range"] <= 0.0 and o["triangles"] > range_triangles:
			out.append(_rec("info", "%s draws its %s baked triangles at every distance; beyond %.1f m its relief is under two pixels (geometry_range)." % [
				name, format_count(o["triangles"]), suggested], node, {"object": node, "property": "geometry_range", "value": snappedf(suggested, 0.1)}))
		if o["budget_reached"]:
			out.append(_rec("warning", "%s: the triangle budget (%s) stopped the bake %.2f mm from the relief (tolerance %.2f mm). Raise the quality and bake again." % [
				name, format_count(o["max_triangles"]), o["error_left_m"] * 1000.0, o["tolerance_m"] * 1000.0], node,
				{"object": node, "property": "quality", "value": mini(node.quality + 1, GADSMeshInstance3D.Quality.ULTRA)}
				if node.quality < GADSMeshInstance3D.Quality.ULTRA else {}))
	for hm: Dictionary in report["height_maps"]:
		if hm["useful_size"] < hm["size"]:
			var tex: Texture2D = hm["texture"]
			out.append(_rec("info", "Height map %s (%d px) holds no relief finer than %d px: a %d px map draws the same relief with %d %% of the memory." % [
				tex.resource_path.get_file() if not tex.resource_path.is_empty() else "(built-in)", hm["size"], hm["useful_size"], hm["useful_size"],
				int(100.0 * pow(float(hm["useful_size"]) / hm["size"], 2.0))], tex, {}))
	return out


## The changes that tune the scene under [param root] for [param target]: the GADSManager preset
## and each baked mesh's geometry_range. Apply them with [method apply_fixes] (or, in the editor,
## as one undoable action: the GADS panel does).
static func optimize_for(target: Target, root: Node) -> Array:
	var t: Dictionary = TARGETS[target]
	var fixes := []
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "", true, false))
	for node in nodes:
		if node is GADSManager and (node as GADSManager).preset != t["preset"]:
			fixes.append({"object": node, "property": "preset", "value": t["preset"]})
		elif node is GADSMeshInstance3D and (node as GADSMeshInstance3D).baked:
			var mi := node as GADSMeshInstance3D
			var range_m := snappedf(mi.suggest_geometry_range(t["relief_px"]), 0.1)
			if not is_equal_approx(mi.geometry_range, range_m):
				fixes.append({"object": mi, "property": "geometry_range", "value": range_m})
	return fixes


## Applies fixes from [method recommend] or [method optimize_for] directly (no undo).
static func apply_fixes(fixes: Array) -> void:
	for fix: Dictionary in fixes:
		if fix.is_empty() or not is_instance_valid(fix["object"]):
			continue
		if fix.has("property"):
			(fix["object"] as Object).set(fix["property"], fix["value"])
		elif fix.has("method"):
			(fix["object"] as Object).callv(fix["method"], fix.get("args", []))


static func mesh_triangles(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var n := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		n += indices.size() / 3 if not indices.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


## Video memory of a mesh's vertex and index buffers (an estimate from its format: positions,
## compressed normals and tangents, uvs, colours, the bake's float custom channels, indices plus
## about half again for LODs).
static func mesh_bytes(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var vertices := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var per_vertex := 12 + 8
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			per_vertex += 8
		if arrays[Mesh.ARRAY_TEX_UV2] != null:
			per_vertex += 8
		if arrays[Mesh.ARRAY_COLOR] != null:
			per_vertex += 4
		for ch in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1]:
			if arrays[ch] != null:
				per_vertex += 16
		var indices: int = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if arrays[Mesh.ARRAY_INDEX] != null else 0
		total += vertices * per_vertex + int(indices * (2 if vertices < 65536 else 4) * 1.5)
	return total


## Share of the viewport (0-1) the axis-aligned bounds of [param node] cover as seen by
## [param camera]; 1 when the camera is inside or behind part of them.
static func screen_coverage(node: VisualInstance3D, camera: Camera3D) -> float:
	var aabb := node.global_transform * node.get_aabb()
	if aabb.has_point(camera.global_position):
		return 1.0
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in 8:
		var p := aabb.get_endpoint(i)
		if camera.is_position_behind(p):
			return 1.0
		var q := camera.unproject_position(p)
		lo = lo.min(q)
		hi = hi.max(q)
	var size := camera.get_viewport().get_visible_rect().size
	lo = lo.clamp(Vector2.ZERO, size)
	hi = hi.clamp(Vector2.ZERO, size)
	return clampf((hi.x - lo.x) * (hi.y - lo.y) / maxf(size.x * size.y, 1.0), 0.0, 1.0)


static func format_count(n: int) -> String:
	if n >= 1000000:
		return "%.2f M" % (n / 1e6)
	if n >= 10000:
		return "%.1f k" % (n / 1e3)
	return str(n)


static func format_bytes(n: int) -> String:
	if n >= 1 << 30:
		return "%.2f GB" % (n / float(1 << 30))
	if n >= 1 << 20:
		return "%.1f MB" % (n / float(1 << 20))
	if n >= 1 << 10:
		return "%.0f KB" % (n / float(1 << 10))
	return "%d B" % n


static func _object_stats(node: GADSMeshInstance3D, camera: Camera3D) -> Dictionary:
	var s := node.bake_stats
	var settings := node.get_bake_settings()
	var base := mesh_triangles(node.source_mesh)
	var shape := node.collision_shape as ConcavePolygonShape3D
	return {
		"node": node,
		"name": String(node.name),
		"baked": node.baked,
		"stale": node.baked and node.is_bake_stale(),
		"base_triangles": base,
		"triangles": mesh_triangles(node.mesh) if node.baked else base,
		"max_triangles": int(settings["max_triangles"]),
		"collision_triangles": int(s.get("collision_triangles", shape.get_faces().size() / 3 if shape != null else 0)),
		"depth_m": node.get_relief_depth(),
		"tolerance_m": float(s.get("error_m", settings["max_error"])),
		"error_left_m": float(s.get("max_error_left", 0.0)),
		"budget_reached": bool(s.get("budget_reached", false)),
		"coverage": screen_coverage(node, camera) if camera != null and node.is_inside_tree() and camera.is_inside_tree() else -1.0,
		"memory_bytes": mesh_bytes(node.mesh) if node.baked else 0,
		"geometry_range": node.geometry_range,
	}


static func _frame_stats(root: Node) -> Dictionary:
	var frame := {"fps": Engine.get_frames_per_second(), "cpu_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"gpu_ms": -1.0, "primitives": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"video_memory_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)}
	if root.is_inside_tree() and root.get_viewport() != null:
		var rid := root.get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(rid, true)
		frame["gpu_ms"] = RenderingServer.viewport_get_measured_render_time_gpu(rid)
	return frame


static func _directory_bytes(dir_path: String) -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	var total := 0
	for f in dir.get_files():
		if f.get_extension() in ["mesh", "res"]:
			var file := FileAccess.open(dir_path.path_join(f), FileAccess.READ)
			if file != null:
				total += file.get_length()
	return total


static func _rec(level: String, message: String, object: Object, fix: Dictionary) -> Dictionary:
	return {"level": level, "message": message, "object": object, "fix": fix}
