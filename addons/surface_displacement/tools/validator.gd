@tool
class_name SDValidator
extends RefCounted
## Checks a scene for the setup mistakes that break or weaken Surface Displacement. Each issue is
## {"level": "error" | "warning" | "info", "message": String}.


static func validate(root: Node) -> Array:
	var issues := []
	for name: StringName in SDGlobals.definitions():
		if not ProjectSettings.has_setting("shader_globals/" + String(name)):
			issues.append(_issue("error", "Shader global '%s' is missing: enable the plugin (it registers them) and reload." % name))
	if ProjectSettings.get_setting("rendering/shading/overrides/force_lambert_over_burley", false):
		issues.append(_issue("warning", "force_lambert_over_burley is on: the self-shadowing variants still light with Burley, as BaseMaterial3D does by default."))
	var managers := root.find_children("*", "SurfaceDisplacement", true, false)
	if root is SurfaceDisplacement:
		managers.append(root)
	if managers.is_empty():
		issues.append(_issue("info", "No SurfaceDisplacement node: materials use the quality in Project Settings > Shader Globals and the variant they were saved with."))
	elif managers.size() > 1:
		issues.append(_issue("warning", "%d SurfaceDisplacement nodes: they share the same shader globals; keep one." % managers.size()))
	var seen := {}
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		for m in _materials_of(node as GeometryInstance3D):
			if seen.has(m) or not SDMaterials.is_sd_material(m):
				continue
			seen[m] = true
			issues.append_array(_check_material(m as ShaderMaterial, node))
	for node in root.find_children("*", "DisplacementField3D", true, false):
		issues.append_array(_check_field(node as DisplacementField3D))
	return issues


static func print_report(issues: Array) -> void:
	if issues.is_empty():
		print("Surface Displacement: setup OK.")
		return
	for i: Dictionary in issues:
		var line: String = "Surface Displacement %s: %s" % [i["level"], i["message"]]
		if i["level"] == "error":
			push_error(line)
		elif i["level"] == "warning":
			push_warning(line)
		else:
			print(line)


static func _issue(level: String, message: String) -> Dictionary:
	return {"level": level, "message": message}


static func _materials_of(gi: GeometryInstance3D) -> Array:
	var out := [gi.material_override]
	if gi is MeshInstance3D:
		var mi := gi as MeshInstance3D
		for s in mi.get_surface_override_material_count():
			out.append(mi.get_surface_override_material(s))
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				out.append(mi.mesh.surface_get_material(s))
	return out.filter(func(m: Material) -> bool: return m != null)


static func _check_material(m: ShaderMaterial, node: Node) -> Array:
	var issues := []
	var label := "%s on %s" % [m.resource_name if not m.resource_name.is_empty() else "SD material", node.name]
	var info := SDMaterials.parse(m.shader)
	var height := m.get_shader_parameter("height_texture") as Texture2D
	if height == null:
		issues.append(_issue("warning", "%s has no height texture: it draws flat." % label))
	else:
		var img := height.get_image()
		if img != null and not img.has_mipmaps():
			issues.append(_issue("error", "%s: the height texture has no mipmaps (the march samples the full-size map at every distance: shimmer and cost). Import it with mipmaps." % label))
		if img != null and img.get_format() in [Image.FORMAT_L8, Image.FORMAT_R8, Image.FORMAT_RGB8, Image.FORMAT_RGBA8, Image.FORMAT_LA8]:
			issues.append(_issue("info", "%s: 8-bit height texture; fine for small relief, a 16-bit float (EXR) map avoids terracing under self-shadowing." % label))
		if img != null and img.is_compressed():
			issues.append(_issue("warning", "%s: the height texture is VRAM compressed; block artefacts show as relief. Import it lossless." % label))
	for key in ["albedo_texture", "normal_texture", "orm_texture"]:
		var tex := m.get_shader_parameter(key) as Texture2D
		if tex != null and tex.get_image() != null and not tex.get_image().has_mipmaps():
			issues.append(_issue("warning", "%s: %s has no mipmaps." % [label, key]))
	if info.get("depth_write", false) or m.get_meta(&"sd_depth_write", false):
		issues.append(_issue("info", "%s writes depth: its march runs in the depth pre-pass too and early-Z is lost (see README)." % label))
	return issues


static func _check_field(field: DisplacementField3D) -> Array:
	var issues := []
	var label := "DisplacementField3D %s" % field.name
	if field.layers.is_empty():
		issues.append(_issue("error", "%s has no layers." % label))
	for layer in field.layers:
		if layer == null:
			continue
		var info := SDMaterials.parse(layer.shader)
		if info.is_empty() or info["mapping"] != SDMaterials.Mapping.WORLD:
			issues.append(_issue("error", "%s: layer %s is not a world-planar SD material." % [label, layer.resource_name]))
		elif not is_zero_approx(float(SDMaterials.get_param(layer, "height_center"))):
			issues.append(_issue("warning", "%s: layer %s has height_center %.2f; the field's relief sits above the ground (0), so the parallax around it should too." % [label, layer.resource_name, SDMaterials.get_param(layer, "height_center")]))
	if field.ground_bake == null and field.is_inside_tree() and SDGroundBake.collect_ground(field.get_tree(), field.ground_group).is_empty():
		issues.append(_issue("info", "%s: no meshes in group '%s'; the ground is the flat plane at the field's height." % [label, field.ground_group]))
	for k in field.levels - 1:
		var r := field.get_morph_range(k)
		var spacing := field.base_spacing * pow(2.0, k)
		var outer := field.resolution / 2.0 * spacing
		if k > 0 and r.x < sqrt(2.0) * (outer * 0.5 + field.get_snap() * 0.5) - 1e-4:
			issues.append(_issue("warning", "%s: ring %d is too small for its snap step; its morph is abrupt. Raise the resolution." % [label, k]))
	return issues
