@tool
class_name GADSMaterials
extends RefCounted
## Creates GADS materials and switches their shader variant.
##
## Every GADS material is a [ShaderMaterial] whose shader is one of the generated variants in
## [code]render/shaders/variants/[/code]: [code]gads_<mapping>_<quality>[_depth].gdshader[/code]. The mapping
## (UV, world-planar, triplanar) and the depth write are per-material choices; the quality (flat,
## POM, POM with self-shadowing) is what [GADSManager] switches at runtime. Switching keeps
## every parameter, because the variants share one set of uniforms.

enum Mapping { UV, WORLD, TRIPLANAR }
enum Quality { FLAT, POM, POM_SELF_SHADOW }

const VARIANT_DIR := "res://addons/gads/render/shaders/variants/"
const MAPPING_NAMES: Array[String] = ["uv", "world", "triplanar"]
const QUALITY_NAMES: Array[String] = ["flat", "pom", "pom_ss"]
## The shader's default for every non-texture uniform of gads_core.gdshaderinc (the render tests
## check that the two agree), for code that reads a parameter a material never set.
const PARAMETER_DEFAULTS := {
	"albedo_tint": Color(1, 1, 1, 1),
	"normal_strength": 1.0,
	"ao_strength": 1.0,
	"roughness_scale": 1.0,
	"metallic_scale": 0.0,
	"specular": 0.5,
	"height_m": 0.03,
	"height_center": 1.0,
	"height_remap": Vector2(0.0, 1.0),
	"pom_steps_scale": 1.0,
	"self_shadow_strength": 1.0,
	"uv_scale": Vector2(1.0, 1.0),
	"uv_offset": Vector2(0.0, 0.0),
	"texture_size_m": Vector2(2.0, 2.0),
	"planar_rotation_deg": 0.0,
	"planar_offset_m": Vector2(0.0, 0.0),
	"triplanar_sharpness": 4.0,
	"detail_height_m": 0.0,
	"detail_scale": 8.0,
	"detail_normal_strength": 0.0,
}


## A shader parameter of an GADS material: its value, or the shader's default when it was never set
## (null for an unset texture).
static func get_param(material: ShaderMaterial, name: String) -> Variant:
	var value: Variant = material.get_shader_parameter(name)
	return PARAMETER_DEFAULTS.get(name) if value == null else value

static func variant_path(mapping: Mapping, quality: Quality, depth_write := false) -> String:
	var depth := depth_write and quality != Quality.FLAT
	return VARIANT_DIR + "gads_%s_%s%s.gdshader" % [MAPPING_NAMES[mapping], QUALITY_NAMES[quality], "_depth" if depth else ""]


static func get_shader(mapping: Mapping, quality: Quality, depth_write := false) -> Shader:
	return load(variant_path(mapping, quality, depth_write))


## {"mapping": Mapping, "quality": Quality, "depth_write": bool} of an GADS variant, or {} for any
## other shader.
static func parse(shader: Shader) -> Dictionary:
	if shader == null or not shader.resource_path.begins_with(VARIANT_DIR):
		return {}
	var stem := shader.resource_path.get_file().get_basename()
	if not stem.begins_with("gads_"):
		return {}
	var depth := stem.ends_with("_depth")
	stem = stem.trim_prefix("gads_").trim_suffix("_depth")
	for m in MAPPING_NAMES.size():
		if not stem.begins_with(MAPPING_NAMES[m] + "_"):
			continue
		var q := QUALITY_NAMES.find(stem.trim_prefix(MAPPING_NAMES[m] + "_"))
		if q >= 0:
			return {"mapping": m, "quality": q, "depth_write": depth}
	return {}


static func is_gads_material(material: Material) -> bool:
	return material is ShaderMaterial and not parse((material as ShaderMaterial).shader).is_empty()


## Every material [param node] draws with (any kind, each once): a GeometryInstance3D's
## override and overlay; a MeshInstance3D's surface overrides and its mesh's materials; the mesh
## of a MultiMeshInstance3D, CPUParticles3D or CSGMesh3D and the draw passes of a
## GPUParticles3D; a CSG shape's material; the item meshes of a GridMap's MeshLibrary; each
## followed along its next_pass chain.
static func materials_of(node: Node) -> Array[Material]:
	var out: Array[Material] = []
	if node is GeometryInstance3D:
		_add_material(out, (node as GeometryInstance3D).material_override)
		_add_material(out, (node as GeometryInstance3D).material_overlay)
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		for s in mi.get_surface_override_material_count():
			_add_material(out, mi.get_surface_override_material(s))
		_add_mesh(out, mi.mesh)
	elif node is MultiMeshInstance3D:
		var multimesh := (node as MultiMeshInstance3D).multimesh
		if multimesh != null:
			_add_mesh(out, multimesh.mesh)
	elif node is GPUParticles3D:
		var particles := node as GPUParticles3D
		for i in particles.draw_passes:
			_add_mesh(out, particles.get_draw_pass_mesh(i))
	elif node is CPUParticles3D:
		_add_mesh(out, (node as CPUParticles3D).mesh)
	elif node.is_class("CSGShape3D"):
		# By name: CSG and GridMap are engine modules that a custom build can leave out.
		_add_material(out, node.get("material") as Material)
		_add_mesh(out, node.get("mesh") as Mesh)
	elif node.is_class("GridMap"):
		var library := node.get("mesh_library") as MeshLibrary
		if library != null:
			for id in library.get_item_list():
				_add_mesh(out, library.get_item_mesh(id))
	return out


static func _add_mesh(out: Array[Material], mesh: Mesh) -> void:
	if mesh != null:
		for s in mesh.get_surface_count():
			_add_material(out, mesh.surface_get_material(s))


static func _add_material(out: Array[Material], material: Material) -> void:
	while material != null and not out.has(material):
		out.append(material)
		material = material.next_pass


## Switches [param material] to [param quality], keeping its mapping and depth write. Returns
## true if the shader changed. Materials that are not GADS variants are left alone.
static func set_quality(material: ShaderMaterial, quality: Quality) -> bool:
	var info := parse(material.shader)
	if info.is_empty():
		return false
	var depth: bool = info["depth_write"] or bool(material.get_meta(&"gads_depth_write", false))
	var shader := get_shader(info["mapping"], quality, depth)
	if material.shader == shader:
		return false
	# A flat variant cannot carry the depth write; remember it for the way back.
	if depth:
		material.set_meta(&"gads_depth_write", true)
	material.shader = shader
	return true


## Opts [param material] in or out of the depth write (see the README for its cost).
static func set_depth_write(material: ShaderMaterial, enabled: bool) -> void:
	var info := parse(material.shader)
	if info.is_empty():
		return
	if enabled:
		material.set_meta(&"gads_depth_write", true)
	elif material.has_meta(&"gads_depth_write"):
		material.remove_meta(&"gads_depth_write")
	material.shader = get_shader(info["mapping"], info["quality"], enabled)


## A new GADS material. [param textures]: any of "albedo", "normal", "orm", "height",
## "detail_height", "detail_normal" -> Texture2D. [param params]: shader parameters by name
## (height_m, height_center, texture_size_m, detail_scale, ...). A detail height map without a
## detail_height_m gets a fifth of the main depth; a detail normal map without a
## detail_normal_strength gets 1.
static func create(mapping: Mapping, textures: Dictionary, params := {}, quality := Quality.POM_SELF_SHADOW,
		depth_write := false) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = get_shader(mapping, quality, depth_write)
	if depth_write:
		material.set_meta(&"gads_depth_write", true)
	for key: String in textures:
		material.set_shader_parameter(key + "_texture", textures[key])
	if textures.has("detail_height") and not params.has("detail_height_m"):
		material.set_shader_parameter("detail_height_m", 0.2 * float(params.get("height_m", PARAMETER_DEFAULTS["height_m"])))
	if textures.has("detail_normal") and not params.has("detail_normal_strength"):
		material.set_shader_parameter("detail_normal_strength", 1.0)
	for key: String in params:
		material.set_shader_parameter(key, params[key])
	return material


## A material from a texture folder written by tools/prepare_textures.py: <dir>/<id>_albedo.jpg,
## _normal.jpg, _arm.jpg, _height.exr and <id>.gads.json (real size and suggested relief depth).
## [param params] override the defaults derived from the metadata.
static func from_texture_set(dir: String, mapping: Mapping, params := {}, quality := Quality.POM_SELF_SHADOW,
		depth_write := false) -> ShaderMaterial:
	var set_id := dir.trim_suffix("/").get_file()
	var base := dir.trim_suffix("/") + "/" + set_id
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + ".gads.json"))
	var all := {}
	if meta is Dictionary:
		var size: Array = meta.get("size_m", [2.0, 2.0])
		all["texture_size_m"] = Vector2(size[0], size[1])
		all["height_m"] = float(meta.get("height_m", 0.03))
	all.merge(params, true)
	var textures := {
		"albedo": load(base + "_albedo.jpg"),
		"normal": load(base + "_normal.jpg"),
		"orm": load(base + "_arm.jpg"),
		"height": load(base + "_height.exr"),
	}
	return create(mapping, textures, all, quality, depth_write)
