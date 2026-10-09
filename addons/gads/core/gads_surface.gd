@tool
class_name GADSSurface
extends RefCounted
## One node's relief, for scripts ([method GADS.surface]): how deep it draws (this node only),
## its tint, its quality and its height map.
## [codeblock]
## var wall := GADS.surface($Wall)
## wall.displacement_strength = 0.04       # 4 cm on this wall; others sharing the material keep theirs
## wall.quality = GADS.QUALITY_ULTRA
## [/codeblock]

## The node this is the relief of.
var node: GeometryInstance3D

## The relief depth this node draws (m): its deepest GADS material's height_m times its relief
## scale. Setting it changes this node only (its gads_relief_scale; a material shared with other
## nodes keeps its depth). A baked GADSMeshInstance3D then needs a new bake (live in the editor).
var displacement_strength: float:
	get:
		return get_material_depth() * relief_scale
	set(value):
		var depth := get_material_depth()
		relief_scale = value / depth if depth > 0.0 else 0.0

## This node's share of its materials' relief (1: as authored, 0: none).
var relief_scale: float:
	get:
		return float(GADSMaterials.get_variation(node)["relief_scale"])
	set(value):
		GADSMaterials.set_variation(node, maxf(value, 0.0), tint)

## This node's albedo tint (on top of the material's).
var tint: Color:
	get:
		return GADSMaterials.get_variation(node)["tint"]
	set(value):
		GADSMaterials.set_variation(node, relief_scale, value)

## A [GADS] quality level for this node: its GADS materials' variant (Off: normal mapping only,
## Low and Medium: parallax, High and Ultra: parallax with self-shadowing) and, on a
## GADSMeshInstance3D, its bake quality. Materials are shared resources, and a GADSManager sets
## every material's variant again when its preset changes.
var quality: int:
	get:
		if node is GADSMeshInstance3D and (node as GADSMeshInstance3D).quality <= GADSMeshInstance3D.Quality.ULTRA:
			return maxi((node as GADSMeshInstance3D).quality, GADS.QUALITY_LOW)
		var m := get_material()
		if m == null:
			return GADS.QUALITY_OFF
		match GADSMaterials.parse(m.shader).get("quality", GADSMaterials.Quality.FLAT):
			GADSMaterials.Quality.FLAT:
				return GADS.QUALITY_OFF
			GADSMaterials.Quality.POM:
				return GADS.QUALITY_MEDIUM
		return GADS.QUALITY_HIGH
	set(value):
		var variant := GADSMaterials.Quality.FLAT
		if value >= GADS.QUALITY_HIGH:
			variant = GADSMaterials.Quality.POM_SELF_SHADOW
		elif value >= GADS.QUALITY_LOW:
			variant = GADSMaterials.Quality.POM
		for m in get_materials():
			GADSMaterials.set_quality(m, variant)
		if node is GADSMeshInstance3D and value >= GADS.QUALITY_LOW:
			(node as GADSMeshInstance3D).quality = clampi(value, GADSMeshInstance3D.Quality.LOW, GADSMeshInstance3D.Quality.ULTRA) as GADSMeshInstance3D.Quality


func _init(target: GeometryInstance3D) -> void:
	node = target


## The node's GADS materials (override, surface materials, overlay).
func get_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	if node == null:
		return out
	for m in GADSMaterials.materials_of(node):
		if GADSMaterials.is_gads_material(m) and not out.has(m):
			out.append(m as ShaderMaterial)
	return out


## The node's first GADS material, or null.
func get_material() -> ShaderMaterial:
	var all := get_materials()
	return all[0] if not all.is_empty() else null


## The deepest height_m among the node's GADS materials (m), before its relief scale.
func get_material_depth() -> float:
	var depth := 0.0
	for m in get_materials():
		depth = maxf(depth, float(GADSMaterials.get_param(m, "height_m")))
	return depth


## Gives the node's GADS materials [param texture] as their height map, and [param depth_m] as
## their depth when it is 0 or more. These are the materials' own settings, shared with every
## node that uses them.
func set_height_texture(texture: Texture2D, depth_m := -1.0) -> void:
	for m in get_materials():
		m.set_shader_parameter("height_texture", texture)
		if depth_m >= 0.0:
			m.set_shader_parameter("height_m", depth_m)
