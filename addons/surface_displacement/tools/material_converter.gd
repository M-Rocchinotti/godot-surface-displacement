@tool
class_name SDMaterialConverter
extends RefCounted
## Converts BaseMaterial3D (StandardMaterial3D / ORMMaterial3D) materials that use a height map
## into Surface Displacement materials. [method plan] only looks; [method apply] assigns (the
## editor plugin wraps the same assignments in undo/redo).
##
## What carries over: albedo colour and texture, normal map and scale, ORM texture
## (ORMMaterial3D) or constant roughness / metallic, AO on/off, specular, emission (colour, energy
## multiplier and texture), UV scale and offset, world triplanar mapping and its sharpness, the
## height map (flipped if the material flips it).
## The relief depth is BaseMaterial3D's heightmap_scale (hundredths of a texture repeat) turned
## into metres with [param metres_per_repeat] (default 1 m per texture repeat) - check it per
## material. Materials with transparency, unshaded shading, object-space triplanar mapping,
## separate AO / roughness / metallic textures, emission on UV2 or an emission colour added to an
## emission texture are not converted (reported in "skipped" with the reason).


## {"assignments": [{"node", "surface" (-1 = material_override), "from" (the material that was
## drawn), "previous" (what the slot held: the override, possibly null), "to"}], "skipped":
## [{"node", "material", "reason"}], "converted": number of distinct materials}.
static func plan(roots: Array[Node], metres_per_repeat := 1.0) -> Dictionary:
	var assignments := []
	var skipped := []
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
			var previous: Material = mi.material_override if slot[0] < 0 else mi.get_surface_override_material(slot[0])
			assignments.append({"node": mi, "surface": slot[0], "from": slot[1], "previous": previous, "to": converted[material]})
	return {"assignments": assignments, "skipped": skipped, "converted": converted.size()}


static func apply(planned: Dictionary) -> void:
	for a: Dictionary in planned["assignments"]:
		assign(a["node"], a["surface"], a["to"])


static func assign(mi: MeshInstance3D, surface: int, material: Material) -> void:
	if surface < 0:
		mi.material_override = material
	else:
		mi.set_surface_override_material(surface, material)


## Why [param m] cannot be converted, or "" if it can.
static func skip_reason(m: BaseMaterial3D) -> String:
	if not m.heightmap_enabled or m.heightmap_texture == null:
		return "no height map (nothing to displace)"
	if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return "transparent"
	if m.shading_mode != BaseMaterial3D.SHADING_MODE_PER_PIXEL:
		return "not per-pixel shaded"
	if m.emission_enabled and m.emission_on_uv2:
		return "emission on UV2 (Surface Displacement samples every texture on UV1)"
	if m.emission_enabled and m.emission_operator == BaseMaterial3D.EMISSION_OP_ADD and m.emission_texture != null and not _is_black(m.emission):
		return "emission colour added to an emission texture (Surface Displacement multiplies them: set the emission operator to Multiply or the colour to black first)"
	if m.uv1_triplanar and not m.uv1_world_triplanar:
		return "object-space triplanar (Surface Displacement's triplanar mapping is in world space)"
	if not m is ORMMaterial3D and (m.roughness_texture != null or m.metallic_texture != null or (m.ao_enabled and m.ao_texture != null)):
		return "separate AO / roughness / metallic textures (pack them into one ORM texture first)"
	return ""


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
	if m.emission_enabled:
		_convert_emission(m, textures, params)
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


## BaseMaterial3D emits (colour + texture) * energy with the Add operator and colour * texture *
## energy with Multiply; an SD material emits texture * colour * energy. Add without a texture
## becomes a white texture times the colour, Add with a texture (and a black colour, see
## skip_reason()) the texture times white.
static func _convert_emission(m: BaseMaterial3D, textures: Dictionary, params: Dictionary) -> void:
	var energy := m.emission_energy_multiplier
	# With physical light units BaseMaterial3D multiplies in the intensity (nits) as well.
	if ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false):
		energy *= m.emission_intensity
	params["emission_energy"] = energy
	if m.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY:
		textures["emission"] = m.emission_texture
		params["emission_color"] = m.emission
	elif m.emission_texture != null:
		textures["emission"] = m.emission_texture
		params["emission_color"] = Color.WHITE
	elif not _is_black(m.emission):
		textures["emission"] = _white_texture()
		params["emission_color"] = m.emission


static func _is_black(c: Color) -> bool:
	return c.r <= 0.0 and c.g <= 0.0 and c.b <= 0.0


## A small white texture, with mipmaps so Validate Setup does not report it (a 1 x 1 one has a
## single level and reads back without).
static func _white_texture() -> ImageTexture:
	var img := Image.create(4, 4, true, Image.FORMAT_RGB8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)
