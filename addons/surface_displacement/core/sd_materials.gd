@tool
class_name SDMaterials
extends RefCounted
## Creates Surface Displacement materials and switches their shader variant.
##
## Every SD material is a [ShaderMaterial] whose shader is one of the generated variants in
## [code]shaders/variants/[/code]: [code]sd_<mapping>_<quality>[_depth].gdshader[/code]. The mapping
## (UV, world-planar, triplanar) and the depth write are per-material choices; the quality (flat,
## POM, POM with self-shadowing) is what [SurfaceDisplacement] switches at runtime. Switching keeps
## every parameter, because the variants share one set of uniforms.

enum Mapping { UV, WORLD, TRIPLANAR }
enum Quality { FLAT, POM, POM_SELF_SHADOW }

const VARIANT_DIR := "res://addons/surface_displacement/shaders/variants/"
const MAPPING_NAMES: Array[String] = ["uv", "world", "triplanar"]
const QUALITY_NAMES: Array[String] = ["flat", "pom", "pom_ss"]

static var _cache := {}


static func variant_path(mapping: Mapping, quality: Quality, depth_write := false) -> String:
	var depth := depth_write and quality != Quality.FLAT
	return VARIANT_DIR + "sd_%s_%s%s.gdshader" % [MAPPING_NAMES[mapping], QUALITY_NAMES[quality], "_depth" if depth else ""]


static func get_shader(mapping: Mapping, quality: Quality, depth_write := false) -> Shader:
	var path := variant_path(mapping, quality, depth_write)
	if not _cache.has(path):
		_cache[path] = load(path)
	return _cache[path]


## {"mapping": Mapping, "quality": Quality, "depth_write": bool} of an SD variant, or {} for any
## other shader.
static func parse(shader: Shader) -> Dictionary:
	if shader == null or not shader.resource_path.begins_with(VARIANT_DIR):
		return {}
	var stem := shader.resource_path.get_file().get_basename()
	if not stem.begins_with("sd_"):
		return {}
	var depth := stem.ends_with("_depth")
	stem = stem.trim_prefix("sd_").trim_suffix("_depth")
	for m in MAPPING_NAMES.size():
		if not stem.begins_with(MAPPING_NAMES[m] + "_"):
			continue
		var q := QUALITY_NAMES.find(stem.trim_prefix(MAPPING_NAMES[m] + "_"))
		if q >= 0:
			return {"mapping": m, "quality": q, "depth_write": depth}
	return {}


static func is_sd_material(material: Material) -> bool:
	return material is ShaderMaterial and not parse((material as ShaderMaterial).shader).is_empty()


## Switches [param material] to [param quality], keeping its mapping and depth write. Returns
## true if the shader changed. Materials that are not SD variants are left alone.
static func set_quality(material: ShaderMaterial, quality: Quality) -> bool:
	var info := parse(material.shader)
	if info.is_empty():
		return false
	var depth: bool = info["depth_write"] or bool(material.get_meta(&"sd_depth_write", false))
	var shader := get_shader(info["mapping"], quality, depth)
	if material.shader == shader:
		return false
	# A flat variant cannot carry the depth write; remember it for the way back.
	if depth:
		material.set_meta(&"sd_depth_write", true)
	material.shader = shader
	return true


## Opts [param material] in or out of the depth write (see the README for its cost).
static func set_depth_write(material: ShaderMaterial, enabled: bool) -> void:
	var info := parse(material.shader)
	if info.is_empty():
		return
	if enabled:
		material.set_meta(&"sd_depth_write", true)
	elif material.has_meta(&"sd_depth_write"):
		material.remove_meta(&"sd_depth_write")
	material.shader = get_shader(info["mapping"], info["quality"], enabled)


## A new SD material. [param textures]: any of "albedo", "normal", "orm", "height" -> Texture2D.
## [param params]: shader parameters by name (height_m, height_center, texture_size_m, ...).
static func create(mapping: Mapping, textures: Dictionary, params := {}, quality := Quality.POM_SELF_SHADOW,
		depth_write := false) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = get_shader(mapping, quality, depth_write)
	if depth_write:
		material.set_meta(&"sd_depth_write", true)
	for key: String in textures:
		material.set_shader_parameter(key + "_texture", textures[key])
	for key: String in params:
		material.set_shader_parameter(key, params[key])
	return material


## A material from a texture folder written by tools/prepare_textures.py: <dir>/<id>_albedo.jpg,
## _normal.jpg, _arm.jpg, _height.exr and <id>.sd.json (real size and suggested relief depth).
## [param params] override the defaults derived from the metadata.
static func from_texture_set(dir: String, mapping: Mapping, params := {}, quality := Quality.POM_SELF_SHADOW,
		depth_write := false) -> ShaderMaterial:
	var set_id := dir.trim_suffix("/").get_file()
	var base := dir.trim_suffix("/") + "/" + set_id
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + ".sd.json"))
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
