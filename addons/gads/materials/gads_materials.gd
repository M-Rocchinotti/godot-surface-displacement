@tool
class_name GADSMaterials
extends RefCounted
## Creates GADS materials and switches their shader variant.
##
## Every GADS material is a [ShaderMaterial] whose shader is one of the generated variants in
## [code]render/shaders/variants/[/code]: [code]gads_[layered_]<mapping>_<quality>[_sil][_depth].gdshader[/code]
## ([code]_sil[/code]: silhouette POM, UV mapping).
## The mapping (UV, world-planar, triplanar), the layering (one relief, or up to three blended by
## vertex colour, slope and height) and the depth write are per-material choices; the quality
## (flat, POM, POM with self-shadowing) is what [GADSManager] switches at runtime. Switching
## keeps every parameter, because the variants share one set of uniforms.

enum Mapping { UV, WORLD, TRIPLANAR }
enum Quality { FLAT, POM, POM_SELF_SHADOW }
## Where a layer of a layered material lies: a vertex colour channel, or everywhere.
enum LayerMask { VERTEX_R, VERTEX_G, VERTEX_B, VERTEX_A, EVERYWHERE }

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
	"flow_speed": Vector2(0.0, 0.0),
	"pulse_amount": 0.0,
	"pulse_rate": 0.5,
	"detail_height_m": 0.0,
	"detail_scale": 8.0,
	"detail_normal_strength": 0.0,
	"cover_color": Color(0.92, 0.94, 0.97, 1.0),
	"cover_amount": 0.0,
	"cover_roughness": 0.65,
	"cover_slope": Vector2(0.35, 0.75),
	"cover_height_bias": 0.5,
	"cover_sharpness": 8.0,
	"wetness": 0.0,
	"puddle_level": 0.0,
	"cavity_color": Color(0.16, 0.14, 0.1, 1.0),
	"cavity_amount": 0.0,
	"edge_color": Color(0.85, 0.82, 0.76, 1.0),
	"edge_amount": 0.0,
	"cavity_radius": 3.0,
	"effects_vertex_mask": 0,
	"relief_vertex_mask": 0,
	"weather_response": 1.0,
	# UV-mapped variants only.
	"vector_displacement_m": 0.0,
	"vector_displacement_space": 0,
	"vector_displacement_signed": false,
}
## The defaults of the layered variants' layer parameters (layerN_<name>, N = 1, 2).
const LAYER_PARAMETER_DEFAULTS := {
	"tint": Color(1, 1, 1, 1),
	"normal_strength": 1.0,
	"height_m": 0.03,
	"scale": 1.0,
	"amount": 0.0,
	"slope": Vector2(0.0, 0.0),
	"blend_width": 0.1,
}


## A shader parameter of an GADS material: its value, or the shader's default when it was never set
## (null for an unset texture).
static func get_param(material: ShaderMaterial, name: String) -> Variant:
	var value: Variant = material.get_shader_parameter(name)
	if value != null:
		return value
	if name.begins_with("layer") and name.length() > 7 and name[6] == "_":
		if name.ends_with("_mask_channel"):
			return LayerMask.VERTEX_R if name[5] == "1" else LayerMask.VERTEX_G
		return LAYER_PARAMETER_DEFAULTS.get(name.substr(7))
	return PARAMETER_DEFAULTS.get(name)

static func variant_path(mapping: Mapping, quality: Quality, depth_write := false, layered := false, silhouette := false) -> String:
	var depth := depth_write and quality != Quality.FLAT
	var sil := silhouette and quality != Quality.FLAT and mapping == Mapping.UV and not layered
	return VARIANT_DIR + "gads_%s%s_%s%s%s.gdshader" % ["layered_" if layered else "", MAPPING_NAMES[mapping], QUALITY_NAMES[quality],
		"_sil" if sil else "", "_depth" if depth else ""]


static func get_shader(mapping: Mapping, quality: Quality, depth_write := false, layered := false, silhouette := false) -> Shader:
	return load(variant_path(mapping, quality, depth_write, layered, silhouette))


## {"mapping": Mapping, "quality": Quality, "depth_write": bool, "layered": bool, "silhouette":
## bool} of a GADS variant, or {} for any other shader.
static func parse(shader: Shader) -> Dictionary:
	if shader == null or not shader.resource_path.begins_with(VARIANT_DIR):
		return {}
	var stem := shader.resource_path.get_file().get_basename()
	if not stem.begins_with("gads_"):
		return {}
	var depth := stem.ends_with("_depth")
	stem = stem.trim_prefix("gads_").trim_suffix("_depth")
	var sil := stem.ends_with("_sil")
	stem = stem.trim_suffix("_sil")
	var layered := stem.begins_with("layered_")
	stem = stem.trim_prefix("layered_")
	for m in MAPPING_NAMES.size():
		if not stem.begins_with(MAPPING_NAMES[m] + "_"):
			continue
		var q := QUALITY_NAMES.find(stem.trim_prefix(MAPPING_NAMES[m] + "_"))
		if q >= 0:
			return {"mapping": m, "quality": q, "depth_write": depth, "layered": layered, "silhouette": sil}
	return {}


## The instance shader parameters that vary a shared material per node ([method set_variation]).
const RELIEF_SCALE_PARAMETER := &"gads_relief_scale"
const TINT_PARAMETER := &"gads_tint"


## Varies the GADS materials [param node] draws without making new ones (they keep batching):
## the relief [param relief_scale] times as deep (parallax and, for a GADSMeshInstance3D, its
## bake; 0 flattens it) and the albedo multiplied by [param tint]. Set as the node's instance
## shader parameters gads_relief_scale and gads_tint, which the inspector shows too.
static func set_variation(node: GeometryInstance3D, relief_scale := 1.0, tint := Color.WHITE) -> void:
	node.set_instance_shader_parameter(RELIEF_SCALE_PARAMETER, maxf(relief_scale, 0.0))
	node.set_instance_shader_parameter(TINT_PARAMETER, tint)
	if node.has_method(&"variation_changed"):
		node.call(&"variation_changed")


## {"relief_scale": float, "tint": Color} of [param node] (1 and white when unset).
static func get_variation(node: GeometryInstance3D) -> Dictionary:
	var s: Variant = node.get_instance_shader_parameter(RELIEF_SCALE_PARAMETER)
	var t: Variant = node.get_instance_shader_parameter(TINT_PARAMETER)
	return {"relief_scale": float(s) if s != null else 1.0, "tint": t as Color if t is Color else Color.WHITE}


## Gives [param to] the variation of [param from] (internal nodes drawing in a node's place).
static func copy_variation(from: GeometryInstance3D, to: GeometryInstance3D) -> void:
	var v := get_variation(from)
	to.set_instance_shader_parameter(RELIEF_SCALE_PARAMETER, v["relief_scale"])
	to.set_instance_shader_parameter(TINT_PARAMETER, v["tint"])


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
	var sil: bool = info["silhouette"] or bool(material.get_meta(&"gads_silhouette", false))
	var shader := get_shader(info["mapping"], quality, depth, info["layered"], sil)
	if material.shader == shader:
		return false
	# A flat variant cannot carry the depth write or the silhouette; remember them for the way back.
	if depth:
		material.set_meta(&"gads_depth_write", true)
	if sil:
		material.set_meta(&"gads_silhouette", true)
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
	material.shader = get_shader(info["mapping"], info["quality"], enabled, info["layered"],
		info["silhouette"] or bool(material.get_meta(&"gads_silhouette", false)))


## Opts [param material] in or out of silhouette POM: on a curved UV-mapped prop the parallax
## follows the surface's curvature and the relief shows in the outline (where the view ray passes
## over the relief, nothing is drawn). Parallax qualities only (kept through a flat preset); costs
## the curvature estimate and a discard, which turns off early depth for the material.
static func set_silhouette(material: ShaderMaterial, enabled: bool) -> void:
	var info := parse(material.shader)
	if info.is_empty():
		return
	if enabled:
		material.set_meta(&"gads_silhouette", true)
	elif material.has_meta(&"gads_silhouette"):
		material.remove_meta(&"gads_silhouette")
	var depth: bool = info["depth_write"] or bool(material.get_meta(&"gads_depth_write", false))
	material.shader = get_shader(info["mapping"], info["quality"], depth, info["layered"], enabled)


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


## A layered GADS material: the main layer from [param textures] and [param params] as in
## [method create], plus up to two layers on top. Each layer is a Dictionary: textures under
## "albedo", "normal", "orm", "height"; settings "height_m", "scale" (repeats per main repeat),
## "mask" ([enum LayerMask], where it lies; default R for layer 1, G for layer 2), "amount"
## (default 1), "slope" (Vector2 band of the surface's up-facing, e.g. (0.6, 0.85) for tops
## only), "blend_width", "tint", "normal_strength".
static func create_layered(mapping: Mapping, textures: Dictionary, params: Dictionary, layers: Array,
		quality := Quality.POM_SELF_SHADOW, depth_write := false) -> ShaderMaterial:
	var material := create(mapping, textures, params, quality, depth_write)
	material.shader = get_shader(mapping, quality, depth_write, true)
	for i in mini(layers.size(), 2):
		var layer: Dictionary = layers[i]
		var prefix := "layer%d_" % (i + 1)
		for key: String in ["albedo", "normal", "orm", "height"]:
			if layer.has(key):
				material.set_shader_parameter(prefix + key + "_texture", layer[key])
		material.set_shader_parameter(prefix + "amount", float(layer.get("amount", 1.0)))
		if layer.has("mask"):
			material.set_shader_parameter(prefix + "mask_channel", int(layer["mask"]))
		for key: String in ["height_m", "scale", "slope", "blend_width", "tint", "normal_strength"]:
			if layer.has(key):
				material.set_shader_parameter(prefix + key, layer[key])
	return material


## One layered GADS material from up to three plain ones (e.g. a terrain's ground, rock and snow):
## the first is the main layer (a copy of it on the layered variant of its mapping and quality),
## the second and third become layers 1 and 2 under [param masks] (default vertex colour R and G),
## each with its own textures, depth, tint and normal strength, and a scale that keeps its own
## texture size. Returns null when the first is not a GADS material.
static func combine_layers(materials: Array, masks: Array = [LayerMask.VERTEX_R, LayerMask.VERTEX_G]) -> ShaderMaterial:
	if materials.is_empty() or not is_gads_material(materials[0]):
		return null
	var main := materials[0] as ShaderMaterial
	var info := parse(main.shader)
	var out := main.duplicate() as ShaderMaterial
	out.shader = get_shader(info["mapping"], info["quality"], info["depth_write"], true)
	for i in range(1, mini(materials.size(), 3)):
		var layer := materials[i] as ShaderMaterial
		if not is_gads_material(layer):
			continue
		var prefix := "layer%d_" % i
		for key: String in ["albedo", "normal", "orm", "height"]:
			out.set_shader_parameter(prefix + key + "_texture", layer.get_shader_parameter(key + "_texture"))
		out.set_shader_parameter(prefix + "height_m", get_param(layer, "height_m"))
		out.set_shader_parameter(prefix + "tint", get_param(layer, "albedo_tint"))
		out.set_shader_parameter(prefix + "normal_strength", get_param(layer, "normal_strength"))
		var scale := 1.0
		if info["mapping"] == Mapping.UV:
			scale = (get_param(layer, "uv_scale") as Vector2).x / maxf((get_param(main, "uv_scale") as Vector2).x, 1e-6)
		else:
			scale = (get_param(main, "texture_size_m") as Vector2).x / maxf((get_param(layer, "texture_size_m") as Vector2).x, 1e-6)
		out.set_shader_parameter(prefix + "scale", scale)
		out.set_shader_parameter(prefix + "amount", 1.0)
		out.set_shader_parameter(prefix + "mask_channel", masks[i - 1] if i - 1 < masks.size() else i - 1)
	return out


## Packs per-layer textures into one [Texture2DArray] so a shader samples every layer through a
## single texture unit (one unit instead of one per layer, which keeps the fragment shader within
## the Compatibility renderer's 16-unit limit). All slices share a resolution -- the largest layer's,
## capped at [param max_size] -- so smaller layers are resized up. [param textures] may hold nulls
## and textures without a readable image; those become a [param fill] slice. [param format] is the
## slice format ([constant Image.FORMAT_RGBA8] for colour, [constant Image.FORMAT_RF] for height).
static func build_layer_array(textures: Array, format: Image.Format, fill: Color, max_size := 2048) -> Texture2DArray:
	var size := 4
	for tex in textures:
		if tex is Texture2D:
			size = maxi(size, maxi((tex as Texture2D).get_width(), (tex as Texture2D).get_height()))
	size = mini(size, max_size)
	var images: Array[Image] = []
	for tex in textures:
		var img: Image = (tex as Texture2D).get_image() if tex is Texture2D else null
		if img == null:
			img = Image.create(size, size, false, format)
			img.fill(fill)
		else:
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			img.convert(format)
			if img.get_width() != size or img.get_height() != size:
				img.resize(size, size, Image.INTERPOLATE_LANCZOS)
		img.generate_mipmaps()
		images.append(img)
	var array := Texture2DArray.new()
	array.create_from_images(images)
	return array


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
