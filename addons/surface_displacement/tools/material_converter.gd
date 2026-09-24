@tool
class_name SDMaterialConverter
extends RefCounted
## Converts BaseMaterial3D (StandardMaterial3D / ORMMaterial3D) materials that use a height map
## into Surface Displacement materials. [method plan] only looks; [method apply] assigns (the
## editor plugin wraps the same assignments in undo/redo).
##
## What carries over: albedo colour and texture, normal map and scale, ORM texture
## (ORMMaterial3D) or constant roughness / metallic, AO on/off, specular, UV scale and offset,
## world triplanar mapping and its sharpness, the height map (flipped if the material flips it).
## The relief depth is BaseMaterial3D's heightmap_scale (hundredths of a texture repeat) turned
## into metres with [param metres_per_repeat] (default 1 m per texture repeat) - check it per
## material. Materials with transparency, emission, unshaded shading, object-space triplanar
## mapping or separate AO / roughness / metallic textures are not converted (reported in
## "skipped" with every reason). Everything else a converted material sets that an SD material
## has no equivalent for (rim, clearcoat, a cull mode, ...) is listed in "dropped".

## Properties an SD material does not carry over: [property, its default, what to call it]. A
## converted material that differs from the default loses it (reported, see [method plan]).
const NOT_CARRIED := [
	["rim_enabled", false, "rim"],
	["clearcoat_enabled", false, "clearcoat"],
	["anisotropy_enabled", false, "anisotropy"],
	["subsurf_scatter_enabled", false, "subsurface scattering"],
	["subsurf_scatter_transmittance_enabled", false, "subsurface transmittance"],
	["backlight_enabled", false, "backlight"],
	["refraction_enabled", false, "refraction"],
	["detail_enabled", false, "detail textures"],
	["heightmap_flip_tangent", false, "heightmap_flip_tangent"],
	["heightmap_flip_binormal", false, "heightmap_flip_binormal"],
	["albedo_texture_force_srgb", false, "albedo_texture_force_srgb"],
	["albedo_texture_msdf", false, "albedo_texture_msdf"],
	["vertex_color_use_as_albedo", false, "vertex colour as albedo"],
	["texture_repeat", true, "texture_repeat off (SD textures always repeat)"],
	["cull_mode", BaseMaterial3D.CULL_BACK, "cull_mode"],
	["depth_draw_mode", BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY, "depth_draw_mode"],
	["no_depth_test", false, "no_depth_test"],
	["disable_ambient_light", false, "disable_ambient_light"],
	["disable_fog", false, "disable_fog"],
	["disable_specular_occlusion", false, "disable_specular_occlusion"],
	["disable_receive_shadows", false, "disable_receive_shadows"],
	["diffuse_mode", BaseMaterial3D.DIFFUSE_BURLEY, "diffuse_mode (SD shades Burley)"],
	["specular_mode", BaseMaterial3D.SPECULAR_SCHLICK_GGX, "specular_mode (SD shades Schlick-GGX)"],
	["uv2_scale", Vector3.ONE, "uv2_scale"],
	["uv2_offset", Vector3.ZERO, "uv2_offset"],
	["uv2_triplanar", false, "uv2_triplanar"],
	["ao_on_uv2", false, "ao_on_uv2"],
	["ao_light_affect", 0.0, "ao_light_affect"],
	["billboard_mode", BaseMaterial3D.BILLBOARD_DISABLED, "billboard_mode"],
	["grow", false, "grow"],
	["use_point_size", false, "use_point_size"],
	["use_particle_trails", false, "use_particle_trails"],
	["fixed_size", false, "fixed_size"],
	["proximity_fade_enabled", false, "proximity_fade"],
	["distance_fade_mode", BaseMaterial3D.DISTANCE_FADE_DISABLED, "distance_fade"],
	["stencil_mode", 0, "stencil_mode"],
	["render_priority", 0, "render_priority"],
	["next_pass", null, "next_pass"],
]


## {"assignments": [{"node", "surface" (-1 = material_override), "from" (the material that was
## drawn), "previous" (what the slot held: the override, possibly null), "to"}], "skipped":
## [{"node", "material", "reason" (every reason, "; "-separated)}], "dropped": [{"material",
## "properties": what it sets that its SD material does not carry}], "converted": number of
## distinct materials}.
static func plan(roots: Array[Node], metres_per_repeat := 1.0) -> Dictionary:
	var assignments := []
	var skipped := []
	var dropped := []
	var converted := {}
	var nodes: Array[Node] = []
	for r in roots:
		if r is GeometryInstance3D:
			nodes.append(r)
		nodes.append_array(r.find_children("*", "MeshInstance3D", true, false))
	for node in nodes:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var slots := []
		if mi.material_override != null:
			slots.append([-1, mi.material_override])
		else:
			for s in mi.mesh.get_surface_count():
				var m := mi.get_surface_override_material(s)
				slots.append([s, m if m != null else mi.mesh.surface_get_material(s)])
		for slot: Array in slots:
			var material := slot[1] as BaseMaterial3D
			if material == null:
				continue
			var reason := skip_reason(material)
			if not reason.is_empty():
				skipped.append({"node": mi, "material": material, "reason": reason})
				continue
			if not converted.has(material):
				converted[material] = convert_material(material, metres_per_repeat)
				var lost := dropped_properties(material)
				if not lost.is_empty():
					dropped.append({"material": material, "properties": lost})
			var previous: Material = mi.material_override if slot[0] < 0 else mi.get_surface_override_material(slot[0])
			assignments.append({"node": mi, "surface": slot[0], "from": slot[1], "previous": previous, "to": converted[material]})
	return {"assignments": assignments, "skipped": skipped, "dropped": dropped, "converted": converted.size()}


static func apply(planned: Dictionary) -> void:
	for a: Dictionary in planned["assignments"]:
		assign(a["node"], a["surface"], a["to"])


static func assign(mi: MeshInstance3D, surface: int, material: Material) -> void:
	if surface < 0:
		mi.material_override = material
	else:
		mi.set_surface_override_material(surface, material)


## Why [param m] cannot be converted (every reason, "; "-separated), or "" if it can.
static func skip_reason(m: BaseMaterial3D) -> String:
	return "; ".join(skip_reasons(m))


## Every reason why [param m] cannot be converted (empty if it can).
static func skip_reasons(m: BaseMaterial3D) -> PackedStringArray:
	var reasons := PackedStringArray()
	if not m.heightmap_enabled or m.heightmap_texture == null:
		reasons.append("no height map (nothing to displace)")
	if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		reasons.append("transparent")
	if m.shading_mode != BaseMaterial3D.SHADING_MODE_PER_PIXEL:
		reasons.append("not per-pixel shaded")
	if m.emission_enabled:
		reasons.append("emission is not supported")
	if m.uv1_triplanar and not m.uv1_world_triplanar:
		reasons.append("object-space triplanar (Surface Displacement's triplanar mapping is in world space)")
	if not m is ORMMaterial3D and (m.roughness_texture != null or m.metallic_texture != null or (m.ao_enabled and m.ao_texture != null)):
		reasons.append("separate AO / roughness / metallic textures (pack them into one ORM texture first)")
	return reasons


## What [param m] sets that its SD material does not carry over (see [constant NOT_CARRIED]),
## plus the triplanar UV offset, which world triplanar mapping does not use.
static func dropped_properties(m: BaseMaterial3D) -> PackedStringArray:
	var lost := PackedStringArray()
	for entry: Array in NOT_CARRIED:
		if entry[0] in m and m.get(entry[0]) != entry[1]:
			lost.append(entry[2])
	if m.uv1_triplanar and m.uv1_offset != Vector3.ZERO:
		lost.append("uv1_offset (world triplanar mapping has no UV offset)")
	return lost


static func convert_material(m: BaseMaterial3D, metres_per_repeat := 1.0) -> ShaderMaterial:
	var triplanar := m.uv1_triplanar
	var mapping := SDMaterials.Mapping.TRIPLANAR if triplanar else SDMaterials.Mapping.UV
	var textures := {"albedo": m.albedo_texture, "height": m.heightmap_texture}
	if m.normal_enabled and m.normal_texture != null:
		textures["normal"] = m.normal_texture
	var params := {
		"albedo_tint": m.albedo_color,
		"normal_strength": m.normal_scale if m.normal_enabled else 0.0,
		"roughness_scale": m.roughness,
		"metallic_scale": m.metallic,
		"specular": m.metallic_specular,
		"ao_strength": 0.0,
		"height_center": 1.0,
		"height_remap": Vector2(1.0, 0.0) if m.heightmap_flip_texture else Vector2(0.0, 1.0),
	}
	if m is ORMMaterial3D:
		textures["orm"] = m.orm_texture
		# ORMMaterial3D reads roughness and metallic from the texture unscaled.
		params["roughness_scale"] = 1.0
		params["metallic_scale"] = 1.0
		params["ao_strength"] = 1.0 if m.ao_enabled else 0.0
	if triplanar:
		var scale := m.uv1_scale
		params["texture_size_m"] = Vector2(1.0 / maxf(scale.x, 1e-4), 1.0 / maxf(scale.z, 1e-4))
		params["triplanar_sharpness"] = clampf(m.uv1_triplanar_sharpness, 1.0, 16.0)
		params["height_m"] = m.heightmap_scale * 0.01 * params["texture_size_m"].x
	else:
		params["uv_scale"] = Vector2(m.uv1_scale.x, m.uv1_scale.y)
		params["uv_offset"] = Vector2(m.uv1_offset.x, m.uv1_offset.y)
		params["height_m"] = m.heightmap_scale * 0.01 * metres_per_repeat
	var out := SDMaterials.create(mapping, textures, params)
	out.resource_name = (m.resource_name if not m.resource_name.is_empty() else "material") + " (SD)"
	return out
