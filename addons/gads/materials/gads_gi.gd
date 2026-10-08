class_name GADSGI
extends RefCounted
## Global illumination with GADS materials. SDFGI, LightmapGI, reflection probes, SSAO and SSIL
## read what the GADS shaders draw; VoxelGI's bake reads only standard materials and takes every
## other one as white, so GADS surfaces would bounce white light. [method bake_voxel_gi] bakes a
## VoxelGI with each GADS surface standing in as a standard material of its colour.
## [codeblock]
## GADSGI.bake_voxel_gi($VoxelGI)  # instead of $VoxelGI.bake()
## [/codeblock]


## A StandardMaterial3D standing in for [param material] where the engine reads only standard
## materials: its albedo the average of the albedo texture times albedo_tint (and
## [param tint], a node's gads_tint), with no texture (the bake would sample it at the mesh's UVs,
## which world-planar and triplanar materials do not use), its roughness the material's.
static func proxy_material(material: ShaderMaterial, tint := Color.WHITE) -> StandardMaterial3D:
	var proxy := StandardMaterial3D.new()
	var colour := Color.WHITE
	var tex := material.get_shader_parameter("albedo_texture") as Texture2D
	if tex != null:
		colour = average_colour(tex)
	colour *= GADSMaterials.get_param(material, "albedo_tint") as Color
	proxy.albedo_color = Color(colour.r * tint.r, colour.g * tint.g, colour.b * tint.b, 1.0)
	proxy.roughness = clampf(float(GADSMaterials.get_param(material, "roughness_scale")), 0.0, 1.0)
	proxy.resource_name = "GADS proxy of %s" % material.resource_name
	return proxy


## The average colour of [param texture] (sRGB, as the material samples it).
static func average_colour(texture: Texture2D) -> Color:
	var img := texture.get_image()
	if img == null or img.is_empty():
		return Color.WHITE
	img = img.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBAF)
	# Halving with bilinear filtering averages 2 x 2 texels a step: a box filter down to one.
	while img.get_width() > 1 or img.get_height() > 1:
		img.resize(maxi(img.get_width() / 2, 1), maxi(img.get_height() / 2, 1), Image.INTERPOLATE_BILINEAR)
	var c := img.get_pixel(0, 0)
	return Color(c.r, c.g, c.b, 1.0)


## Bakes [param gi] ([method VoxelGI.bake]) with the GADS surfaces under [param from_node] (null:
## the VoxelGI's parent) drawn as their [method proxy_material] during the bake, so their colours
## bounce; the materials are put back after. Returns how many surfaces stood in.
static func bake_voxel_gi(gi: VoxelGI, from_node: Node = null, create_visual_debug := false) -> int:
	if from_node == null:
		from_node = gi.get_parent() if gi.get_parent() != null else gi
	var swaps := _swap_in(from_node)
	gi.bake(from_node, create_visual_debug)
	_swap_back(swaps)
	return swaps.size()


## Puts proxies in place of the GADS materials under [param root]; returns what to put back:
## [node, surface (-1: material_override), material before].
static func _swap_in(root: Node) -> Array:
	var swaps := []
	var proxies := {}
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "GeometryInstance3D", true, false))
	for node in nodes:
		var gi_node := node as GeometryInstance3D
		if gi_node == null:
			continue
		var tint := GADSMaterials.get_variation(gi_node)["tint"] as Color
		if GADSMaterials.is_gads_material(gi_node.material_override):
			swaps.append([gi_node, -1, gi_node.material_override])
			gi_node.material_override = _proxy_for(gi_node.material_override as ShaderMaterial, tint, proxies)
			continue
		var mi := gi_node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var active := mi.get_active_material(s)
			if GADSMaterials.is_gads_material(active):
				swaps.append([mi, s, mi.get_surface_override_material(s)])
				mi.set_surface_override_material(s, _proxy_for(active as ShaderMaterial, tint, proxies))
	return swaps


static func _proxy_for(material: ShaderMaterial, tint: Color, proxies: Dictionary) -> StandardMaterial3D:
	var key := [material, tint]
	if not proxies.has(key):
		proxies[key] = proxy_material(material, tint)
	return proxies[key]


static func _swap_back(swaps: Array) -> void:
	for i in range(swaps.size() - 1, -1, -1):
		var entry: Array = swaps[i]
		var node := entry[0] as GeometryInstance3D
		if not is_instance_valid(node):
			continue
		if entry[1] < 0:
			node.material_override = entry[2]
		else:
			(node as MeshInstance3D).set_surface_override_material(entry[1], entry[2])
