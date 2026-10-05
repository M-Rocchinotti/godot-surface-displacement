@tool
class_name GADSValidator
extends RefCounted
## Checks a scene for the setup mistakes that break or weaken GADS. Each issue is
## {"level": "error" | "warning" | "info", "message": String}.


static func validate(root: Node) -> Array:
	var issues := []
	for name: StringName in GADSGlobals.definitions():
		if not ProjectSettings.has_setting("shader_globals/" + String(name)):
			issues.append(_issue("error", "Shader global '%s' is missing: enable the plugin (it registers them) and reload." % name))
	if ProjectSettings.get_setting("rendering/shading/overrides/force_lambert_over_burley", false):
		issues.append(_issue("warning", "force_lambert_over_burley is on: the self-shadowing variants still light with Burley, as BaseMaterial3D does by default."))
	var managers := root.find_children("*", "GADSManager", true, false)
	if root is GADSManager:
		managers.append(root)
	if managers.is_empty():
		issues.append(_issue("info", "No GADSManager node: materials use the quality in Project Settings > Shader Globals and the variant they were saved with."))
	elif managers.size() > 1:
		issues.append(_issue("warning", "%d GADSManager nodes: they share the same shader globals; keep one." % managers.size()))
	for node in managers:
		var gads := node as GADSManager
		if gads.preset == GADSSettings.Preset.CUSTOM and gads.custom_settings == null:
			issues.append(_issue("warning", "GADSManager %s: preset Custom without custom_settings runs the Medium preset." % gads.name))
	var seen := {}
	var drawing := root.find_children("*", "GeometryInstance3D", true, false) + root.find_children("*", "GridMap", true, false)
	if root is GeometryInstance3D:
		drawing.append(root)
	for node in drawing:
		for m in GADSMaterials.materials_of(node):
			if seen.has(m) or not GADSMaterials.is_gads_material(m):
				continue
			seen[m] = true
			issues.append_array(_check_material(m as ShaderMaterial, node))
		if node is MeshInstance3D:
			issues.append_array(_check_mesh_attributes(node as MeshInstance3D))
	for node in root.find_children("*", "GADSDisplacementField3D", true, false):
		issues.append_array(_check_field(node as GADSDisplacementField3D))
	var baked_meshes := root.find_children("*", "GADSMeshInstance3D", true, false)
	if root is GADSMeshInstance3D:
		baked_meshes.append(root)
	for node in baked_meshes:
		issues.append_array(_check_baked_mesh(node as GADSMeshInstance3D))
	for node in root.find_children("*", "GADSPebbleScatter3D", true, false):
		if not node.get_parent() is GADSDisplacementField3D:
			issues.append(_issue("error", "GADSPebbleScatter3D %s draws nothing: it must be a child of a GADSDisplacementField3D." % node.name))
	return issues


static func print_report(issues: Array) -> void:
	if issues.is_empty():
		print("GADS: setup OK.")
		return
	for i: Dictionary in issues:
		var line: String = "GADS %s: %s" % [i["level"], i["message"]]
		if i["level"] == "error":
			push_error(line)
		elif i["level"] == "warning":
			push_warning(line)
		else:
			print(line)


static func _issue(level: String, message: String) -> Dictionary:
	return {"level": level, "message": message}


static func _check_material(m: ShaderMaterial, node: Node) -> Array:
	var issues := []
	var label := "%s on %s" % [m.resource_name if not m.resource_name.is_empty() else "GADS material", node.name]
	var info := GADSMaterials.parse(m.shader)
	var height := m.get_shader_parameter("height_texture") as Texture2D
	if height == null:
		issues.append(_issue("warning", "%s has no height texture: it draws flat." % label))
	elif float(GADSMaterials.get_param(m, "height_m")) <= 0.0:
		issues.append(_issue("warning", "%s has height_m 0: it draws flat. Set the relief depth in metres." % label))
	var remap: Vector2 = GADSMaterials.get_param(m, "height_remap")
	if absf(remap.y - remap.x) < 1e-4:
		issues.append(_issue("error", "%s: height_remap %s maps every height to the same value (x and y must differ)." % [label, remap]))
	if height != null:
		var img := height.get_image()
		if img != null and not img.has_mipmaps():
			issues.append(_issue("error", "%s: the height texture has no mipmaps (the march samples the full-size map at every distance: shimmer and cost). Import it with mipmaps." % label))
		if img != null and img.get_format() in [Image.FORMAT_L8, Image.FORMAT_R8, Image.FORMAT_RGB8, Image.FORMAT_RGBA8, Image.FORMAT_LA8]:
			issues.append(_issue("info", "%s: 8-bit height texture; fine for small relief, a 16-bit float (EXR) map avoids terracing under self-shadowing." % label))
		if img != null and img.is_compressed():
			issues.append(_issue("warning", "%s: the height texture is VRAM compressed; block artefacts show as relief. Import it lossless." % label))
	if float(GADSMaterials.get_param(m, "detail_height_m")) > 0.0 and m.get_shader_parameter("detail_height_texture") == null:
		issues.append(_issue("warning", "%s: detail_height_m is set but there is no detail_height_texture; the relief is only lowered by half of it." % label))
	for key in ["albedo_texture", "normal_texture", "orm_texture", "detail_height_texture", "detail_normal_texture"]:
		var tex := m.get_shader_parameter(key) as Texture2D
		if tex != null and tex.get_image() != null and not tex.get_image().has_mipmaps():
			issues.append(_issue("warning", "%s: %s has no mipmaps." % [label, key]))
	if info.get("depth_write", false) or m.get_meta(&"gads_depth_write", false):
		issues.append(_issue("info", "%s writes depth: its march runs in the depth pre-pass too and early-Z is lost (see README)." % label))
	return issues


## A UV-mapped GADS material needs UVs on the surfaces it shades. (Missing tangents cannot be
## told from the mesh: Godot reports and fills in arbitrary ones.)
static func _check_mesh_attributes(mi: MeshInstance3D) -> Array:
	var issues := []
	# Primitive meshes always have UVs and tangents; an ArrayMesh says what it has.
	var mesh := mi.mesh as ArrayMesh
	if mesh == null:
		return issues
	for s in mesh.get_surface_count():
		var m := GADSGroundBake.surface_material(mi, s) as ShaderMaterial
		var info := GADSMaterials.parse(m.shader) if m != null else {}
		if info.is_empty() or info["mapping"] != GADSMaterials.Mapping.UV:
			continue
		var format: int = mesh.surface_get_format(s)
		if format & Mesh.ARRAY_FORMAT_TEX_UV == 0:
			issues.append(_issue("error", "%s, surface %d: UV-mapped GADS material on a mesh without UVs. Use world-planar or triplanar mapping, or give the mesh UVs." % [mi.name, s]))
	return issues


static func _check_field(field: GADSDisplacementField3D) -> Array:
	var issues := []
	var label := "GADSDisplacementField3D %s" % field.name
	if field.layers.is_empty():
		issues.append(_issue("error", "%s has no layers." % label))
	elif field.layers.size() > GADSDisplacementField3D.MAX_LAYERS:
		issues.append(_issue("warning", "%s has %d layers; only the first %d are used." % [label, field.layers.size(), GADSDisplacementField3D.MAX_LAYERS]))
	var bake := field.ground_bake
	# A captured bake names the layers it was made for (GADSGroundBake.from_arrays() names none).
	# Only names that are resource paths are stable; layers made in code cannot be compared.
	if bake != null and not bake.layer_names.is_empty():
		var stale := bake.layer_names.size() != field.layers.size()
		for i in mini(bake.layer_names.size(), field.layers.size()):
			var layer := field.layers[i]
			if layer != null and bake.layer_names[i].begins_with("res://") and bake.layer_names[i] != layer.resource_path:
				stale = true
		if stale:
			issues.append(_issue("warning", "%s: its ground bake was made for other layers; bake the ground again." % label))
	for layer in field.layers:
		if layer == null:
			continue
		var info := GADSMaterials.parse(layer.shader)
		if info.is_empty() or info["mapping"] != GADSMaterials.Mapping.WORLD:
			issues.append(_issue("error", "%s: layer %s is not a world-planar GADS material." % [label, layer.resource_name]))
		elif info["layered"]:
			issues.append(_issue("warning", "%s: layer %s is a layered material; the field displaces only its main layer (use one field layer per material layer)." % [label, layer.resource_name]))
		elif not is_zero_approx(float(GADSMaterials.get_param(layer, "height_center"))):
			issues.append(_issue("warning", "%s: layer %s has height_center %.2f; the field's relief sits above the ground (0), so the parallax around it should too." % [label, layer.resource_name, GADSMaterials.get_param(layer, "height_center")]))
	if field.is_inside_tree():
		var ground := GADSGroundBake.collect_ground(field.get_tree(), field.ground_group)
		if field.ground_bake == null and ground.is_empty():
			issues.append(_issue("info", "%s: no meshes in group '%s'; the ground is the flat plane at the field's height." % [label, field.ground_group]))
		var others := {}
		for mi in ground:
			for s in (mi.mesh.get_surface_count() if mi.mesh != null else 0):
				var m := GADSGroundBake.surface_material(mi, s)
				var info := GADSMaterials.parse((m as ShaderMaterial).shader) if m is ShaderMaterial else {}
				if not info.is_empty() and info["mapping"] == GADSMaterials.Mapping.WORLD and GADSGroundBake.layer_index(m, field.layers) < 0:
					others[m] = true
		for m: Material in others:
			issues.append(_issue("info", "%s: ground material %s is not one of its layers, so the field leaves it flat (parallax only). Add it to layers to displace it." % [label, m.resource_name]))
	for k in field.levels - 1:
		var r := field.get_morph_range(k)
		var spacing := field.base_spacing * pow(2.0, k)
		var outer := field.resolution / 2.0 * spacing
		if k > 0 and r.x < sqrt(2.0) * (outer * 0.5 + field.get_snap() * 0.5) - 1e-4:
			issues.append(_issue("warning", "%s: ring %d is too small for its snap step; its morph is abrupt. Raise the resolution." % [label, k]))
	return issues


static func _check_baked_mesh(mi: GADSMeshInstance3D) -> Array:
	var issues := []
	if not GADSMeshBaker.is_available():
		issues.append(_issue("warning" if mi.baked else "error", "GADSMeshInstance3D %s: the GADS native library is not loaded on this platform, so it cannot be baked." % mi.name))
	var problem := GADSMeshBaker.check_mesh(mi.source_mesh)
	if not problem.is_empty():
		issues.append(_issue("error", "GADSMeshInstance3D %s cannot be baked: %s." % [mi.name, problem]))
	elif not mi.baked:
		issues.append(_issue("info", "GADSMeshInstance3D %s is not baked: it draws the source mesh with parallax." % mi.name))
	elif mi.is_bake_stale():
		issues.append(_issue("warning", "GADSMeshInstance3D %s: the source, its materials, the bake settings or (world and triplanar mappings) its placement changed since the bake. Bake it again." % mi.name))
	if mi.baked and mi.bake_stats.get("budget_reached", false):
		issues.append(_issue("info", "GADSMeshInstance3D %s: the triangle budget stopped the bake %.2f mm from the relief (tolerance %.2f mm); raise the quality to follow it closer." % [
			mi.name, float(mi.bake_stats.get("max_error_left", 0.0)) * 1000.0, float(mi.bake_stats.get("error_m", 0.0)) * 1000.0]))
	return issues
