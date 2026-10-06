@tool
class_name GADSMeshExporter
extends RefCounted
## Writes meshes (a GADSMeshInstance3D's bake, every cluster of it) to files other tools read:
## glTF binary ([code].glb[/code]), glTF with a separate buffer ([code].gltf[/code]) or Wavefront
## OBJ ([code].obj[/code] with a [code].mtl[/code] and its textures as PNG next to it).
##
## Positions, normals, UVs (both sets), tangents and vertex colours (glTF), one material per
## surface. GADS materials are written as plain PBR materials (albedo, normal, roughness /
## metallic / occlusion from the ORM texture, UV scale and offset): the geometry carries the relief,
## so the height map is left out. The rest data GADS keeps in CUSTOM0 / CUSTOM1 and the LODs are
## not written.

const FORMATS := ["glb", "gltf", "obj"]


## Writes [param meshes] to [param path] (the extension picks the format: glb, gltf or obj), each
## as its own object. [param materials] are one per surface of the first mesh (every mesh of a
## clustered bake has the same surfaces); a missing or null entry uses the mesh's own surface
## material. Returns OK or the error, and prints why.
static func export_meshes(meshes: Array, path: String, materials: Array = [], names: PackedStringArray = PackedStringArray()) -> Error:
	var ext := path.get_extension().to_lower()
	if not ext in FORMATS:
		push_error("GADS: cannot export to %s: use .glb, .gltf or .obj." % path)
		return ERR_FILE_UNRECOGNIZED
	var clean: Array[ArrayMesh] = []
	for m: Mesh in meshes:
		if m == null or m.get_surface_count() == 0:
			continue
		clean.append(strip(m))
	if clean.is_empty():
		push_error("GADS: nothing to export to %s (no mesh)." % path)
		return ERR_INVALID_DATA
	var mats: Array[Material] = []
	for s in clean[0].get_surface_count():
		var m: Material = materials[s] if s < materials.size() else null
		if m == null:
			m = meshes[0].surface_get_material(s)
		mats.append(to_standard(m) if GADSMaterials.is_gads_material(m) else m)
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	if ext == "obj":
		return _write_obj(clean, mats, path, names)
	return _write_gltf(clean, mats, path, names)


## A copy of [param mesh] with only what other tools use: positions, normals, tangents, UVs,
## UV2, vertex colours and indices of each triangle surface (no custom arrays, no LODs, no blend
## shapes), with the surfaces' materials and names.
static func strip(mesh: Mesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		if GADSMeshBaker.surface_primitive(mesh, s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var src := mesh.surface_get_arrays(s)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		for k in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX]:
			arrays[k] = src[k]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var i := out.get_surface_count() - 1
		out.surface_set_material(i, mesh.surface_get_material(s))
		if mesh is ArrayMesh:
			out.surface_set_name(i, (mesh as ArrayMesh).surface_get_name(s))
	return out


## A StandardMaterial3D that looks like [param material] (a GADS material) without its relief:
## albedo texture and tint, normal map and strength, roughness, metallic and occlusion from the
## ORM texture, UV scale and offset (UV mapping) or world triplanar at the texture size (world
## and triplanar mappings).
static func to_standard(material: Material) -> StandardMaterial3D:
	var sm := material as ShaderMaterial
	var out := StandardMaterial3D.new()
	out.resource_name = material.resource_name
	var tint: Color = GADSMaterials.get_param(sm, "albedo_tint")
	out.albedo_color = tint
	out.albedo_texture = sm.get_shader_parameter("albedo_texture") as Texture2D
	var normal := sm.get_shader_parameter("normal_texture") as Texture2D
	if normal != null:
		out.normal_enabled = true
		out.normal_texture = normal
		out.normal_scale = GADSMaterials.get_param(sm, "normal_strength")
	var orm := sm.get_shader_parameter("orm_texture") as Texture2D
	out.roughness = GADSMaterials.get_param(sm, "roughness_scale")
	out.metallic = GADSMaterials.get_param(sm, "metallic_scale")
	out.metallic_specular = GADSMaterials.get_param(sm, "specular")
	if orm != null:
		out.roughness_texture = orm
		out.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		out.metallic_texture = orm
		out.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		out.ao_enabled = true
		out.ao_texture = orm
		out.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		out.ao_light_affect = GADSMaterials.get_param(sm, "ao_strength")
	var info := GADSMaterials.parse(sm.shader)
	if info.get("mapping", GADSMaterials.Mapping.UV) == GADSMaterials.Mapping.UV:
		var scale: Vector2 = GADSMaterials.get_param(sm, "uv_scale")
		var offset: Vector2 = GADSMaterials.get_param(sm, "uv_offset")
		out.uv1_scale = Vector3(scale.x, scale.y, 1.0)
		out.uv1_offset = Vector3(offset.x, offset.y, 0.0)
	else:
		var size: Vector2 = GADSMaterials.get_param(sm, "texture_size_m")
		out.uv1_triplanar = true
		out.uv1_world_triplanar = true
		out.uv1_scale = Vector3(1.0 / maxf(size.x, 1e-6), 1.0 / maxf(size.y, 1e-6), 1.0 / maxf(size.x, 1e-6))
	return out


static func _write_gltf(meshes: Array[ArrayMesh], materials: Array[Material], path: String, names: PackedStringArray) -> Error:
	var root := Node3D.new()
	root.name = path.get_file().get_basename()
	for i in meshes.size():
		var mi := MeshInstance3D.new()
		mi.name = names[i] if i < names.size() else "mesh_%d" % i
		var m := meshes[i]
		for s in m.get_surface_count():
			if s < materials.size() and materials[s] != null:
				m.surface_set_material(s, materials[s])
		mi.mesh = m
		root.add_child(mi)
		mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	root.free()
	if err != OK:
		push_error("GADS: writing %s failed: %s." % [path, error_string(err)])
	return err


static func _write_obj(meshes: Array[ArrayMesh], materials: Array[Material], path: String, names: PackedStringArray) -> Error:
	var stem := path.get_file().get_basename()
	var mtl_path := path.get_basename() + ".mtl"
	var lines := PackedStringArray()
	lines.append("# Written by GADS (Godot Adaptive Displacement System)")
	lines.append("mtllib %s" % mtl_path.get_file())
	var base := [1, 1, 1] # v, vt, vn indices of the next vertex (OBJ counts from 1)
	for i in meshes.size():
		var m := meshes[i]
		lines.append("o %s" % (names[i] if i < names.size() else "mesh_%d" % i))
		for s in m.get_surface_count():
			var arrays := m.surface_get_arrays(s)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.is_empty():
				idx.resize(v.size())
				for k in v.size():
					idx[k] = k
			for p in v:
				lines.append("v %s %s %s" % [_num(p.x), _num(p.y), _num(p.z)])
			for t in uv:
				# OBJ's v runs up, Godot's down.
				lines.append("vt %s %s" % [_num(t.x), _num(1.0 - t.y)])
			for q in n:
				lines.append("vn %s %s %s" % [_num(q.x), _num(q.y), _num(q.z)])
			lines.append("usemtl %s" % _material_name(materials, s))
			var has_uv := not uv.is_empty()
			var has_n := not n.is_empty()
			for t in range(0, idx.size() - 2, 3):
				# Godot's front faces are clockwise, OBJ's counter-clockwise.
				var face := PackedStringArray()
				for k in [idx[t], idx[t + 2], idx[t + 1]]:
					var a := str(base[0] + k)
					var b := str(base[1] + k) if has_uv else ""
					var c := str(base[2] + k) if has_n else ""
					face.append(a + ("/" + b if has_uv or has_n else "") + ("/" + c if has_n else ""))
				lines.append("f " + " ".join(face))
			base[0] += v.size()
			base[1] += uv.size()
			base[2] += n.size()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("GADS: cannot write %s: %s." % [path, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	f.store_string("\n".join(lines) + "\n")
	f.close()
	return _write_mtl(materials, mtl_path, stem)


static func _write_mtl(materials: Array[Material], path: String, stem: String) -> Error:
	var lines := PackedStringArray()
	lines.append("# Written by GADS (Godot Adaptive Displacement System)")
	for s in materials.size():
		lines.append("")
		lines.append("newmtl %s" % _material_name(materials, s))
		var m := materials[s] as BaseMaterial3D
		if m == null:
			lines.append("Kd 0.8 0.8 0.8")
			continue
		var c := m.albedo_color
		lines.append("Kd %s %s %s" % [_num(c.r), _num(c.g), _num(c.b)])
		lines.append("Pr %s" % _num(m.roughness))
		lines.append("Pm %s" % _num(m.metallic))
		var maps := [["map_Kd", m.albedo_texture, "albedo"]]
		if m.normal_enabled:
			maps.append(["norm", m.normal_texture, "normal"])
		if m.roughness_texture != null:
			maps.append(["map_Pr", m.roughness_texture, "orm"])
		for entry: Array in maps:
			var tex: Texture2D = entry[1]
			if tex == null:
				continue
			var img := tex.get_image()
			if img == null:
				continue
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			img.clear_mipmaps()
			var file := "%s_%d_%s.png" % [stem, s, entry[2]]
			if img.save_png(path.get_base_dir().path_join(file)) == OK:
				lines.append("%s %s" % [entry[0], file])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string("\n".join(lines) + "\n")
	f.close()
	return OK


static func _material_name(materials: Array[Material], s: int) -> String:
	var m: Material = materials[s] if s < materials.size() else null
	var n := "surface_%d" % s
	if m != null and not m.resource_name.is_empty():
		n += "_" + m.resource_name.validate_filename().replace(" ", "_")
	return n


static func _num(x: float) -> String:
	return String.num(x, 6)
