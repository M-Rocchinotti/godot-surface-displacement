@tool
class_name GADSSurfacePresets
extends RefCounted
## Surface presets: how a kind of surface is displaced, not only what it looks like. Each sets the
## relief's depth per metre of texture (physical scale: a 2 m brick tile gets 2.4 cm), which way
## it goes (height_center: inward like mortar and dents, outward like snow and sand on the
## ground, or both ways like rock), the march's step scale and the parallax variant (cheap
## surfaces skip self-shadowing), self-shadow strength, surface effects (cavity and edge
## shading, wetness and puddles), roughness and metalness, the mapping a new material uses and
## the GADSProfile its baked meshes take. [method create] makes a material (from your textures,
## or procedural maps of the preset's pattern); [method apply] sets a material's displacement to
## a preset and keeps its textures and mapping.
## [codeblock]
## $Wall.material_override = GADSSurfacePresets.create("brick")           # procedural, 2 m tile
## GADSSurfacePresets.apply($Rock.material_override, "rock")              # its own textures
## GADSSurfacePresets.profile_for("rock").apply($Rock)                    # a GADSMeshInstance3D
## [/codeblock]

const M := GADSMaterials.Mapping
const Q := GADSMaterials.Quality

## id -> {"label", "mapping", "quality", "depth_per_m" (relief depth per metre of texture),
## "params" (shader parameters), "pattern" (GADSProcedural kind for create() without textures),
## "pattern_params", "colors", "profile" (GADSProfile id)}.
const PRESETS := {
	"brick": {"label": "Brick", "mapping": M.TRIPLANAR, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.012,
		"params": {"height_center": 1.0, "pom_steps_scale": 1.0, "self_shadow_strength": 1.0, "cavity_amount": 0.35,
			"edge_amount": 0.1, "roughness_scale": 0.95, "triplanar_sharpness": 8.0},
		"pattern": "bricks", "profile": "wall"},
	"concrete": {"label": "Concrete", "mapping": M.TRIPLANAR, "quality": Q.POM, "depth_per_m": 0.003,
		"params": {"height_center": 1.0, "pom_steps_scale": 0.6, "self_shadow_strength": 0.5, "cavity_amount": 0.25,
			"edge_amount": 0.0, "roughness_scale": 1.0, "triplanar_sharpness": 8.0},
		"pattern": "noise", "pattern_params": {"scale": 8, "octaves": 6}, "colors": [Color(0.42, 0.41, 0.39), Color(0.66, 0.65, 0.62)],
		"profile": "wall"},
	"rock": {"label": "Rock", "mapping": M.TRIPLANAR, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.03,
		"params": {"height_center": 0.5, "pom_steps_scale": 1.25, "self_shadow_strength": 1.0, "cavity_amount": 0.5,
			"edge_amount": 0.2, "roughness_scale": 0.9, "triplanar_sharpness": 4.0},
		"pattern": "rock", "profile": "rock"},
	"cliff": {"label": "Cliff", "mapping": M.TRIPLANAR, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.05,
		"params": {"height_center": 0.5, "pom_steps_scale": 1.5, "self_shadow_strength": 1.0, "cavity_amount": 0.55,
			"edge_amount": 0.25, "roughness_scale": 0.9, "triplanar_sharpness": 6.0},
		"pattern": "ridged", "profile": "rock"},
	"asphalt": {"label": "Asphalt", "mapping": M.WORLD, "quality": Q.POM, "depth_per_m": 0.002,
		"params": {"height_center": 0.0, "pom_steps_scale": 0.5, "self_shadow_strength": 0.4, "cavity_amount": 0.2,
			"edge_amount": 0.0, "roughness_scale": 0.9, "weather_response": 1.0},
		"pattern": "noise", "pattern_params": {"scale": 16, "octaves": 4}, "colors": [Color(0.08, 0.08, 0.085), Color(0.24, 0.24, 0.25)],
		"profile": "terrain"},
	"mud": {"label": "Mud", "mapping": M.WORLD, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.02,
		"params": {"height_center": 0.0, "pom_steps_scale": 1.0, "self_shadow_strength": 0.7, "cavity_amount": 0.3,
			"edge_amount": 0.0, "roughness_scale": 0.75, "wetness": 0.35, "puddle_level": 0.2},
		"pattern": "billow", "colors": [Color(0.16, 0.12, 0.08), Color(0.36, 0.28, 0.2)], "profile": "terrain"},
	"snow": {"label": "Snow", "mapping": M.WORLD, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.015,
		"params": {"height_center": 0.0, "pom_steps_scale": 0.8, "self_shadow_strength": 0.5, "cavity_amount": 0.0,
			"edge_amount": 0.0, "roughness_scale": 0.65, "weather_response": 0.0},
		"pattern": "dunes", "pattern_params": {"scale": 3, "roughness": 0.03}, "colors": [Color(0.78, 0.81, 0.86), Color(0.96, 0.97, 0.99)],
		"profile": "terrain"},
	"sand": {"label": "Sand", "mapping": M.WORLD, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.01,
		"params": {"height_center": 0.0, "pom_steps_scale": 0.8, "self_shadow_strength": 0.8, "cavity_amount": 0.15,
			"edge_amount": 0.0, "roughness_scale": 1.0},
		"pattern": "ripples", "profile": "terrain"},
	"wood": {"label": "Wood / Bark", "mapping": M.UV, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.008,
		"params": {"height_center": 1.0, "pom_steps_scale": 1.0, "self_shadow_strength": 0.8, "cavity_amount": 0.45,
			"edge_amount": 0.1, "roughness_scale": 0.9},
		"pattern": "cracks", "pattern_params": {"scale": 4, "width": 0.05, "warp": 0.6, "variation": 0.3, "roughness": 0.1},
		"colors": [Color(0.14, 0.09, 0.06), Color(0.42, 0.3, 0.2)], "profile": "prop"},
	"metal_damage": {"label": "Metal Damage", "mapping": M.UV, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.004,
		"params": {"height_center": 1.0, "pom_steps_scale": 0.8, "self_shadow_strength": 0.5, "cavity_amount": 0.3,
			"edge_amount": 0.35, "roughness_scale": 0.5, "metallic_scale": 1.0},
		"pattern": "craters", "colors": [Color(0.42, 0.43, 0.45), Color(0.66, 0.67, 0.7)], "profile": "prop"},
	"terrain": {"label": "Terrain", "mapping": M.WORLD, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.015,
		"params": {"height_center": 0.0, "pom_steps_scale": 1.0, "self_shadow_strength": 1.0, "cavity_amount": 0.3,
			"edge_amount": 0.05, "roughness_scale": 0.95},
		"pattern": "stones", "profile": "terrain"},
	"organic": {"label": "Organic", "mapping": M.UV, "quality": Q.POM_SELF_SHADOW, "depth_per_m": 0.006,
		"params": {"height_center": 0.5, "pom_steps_scale": 1.0, "self_shadow_strength": 0.7, "cavity_amount": 0.3,
			"edge_amount": 0.0, "roughness_scale": 0.6},
		"pattern": "scales", "profile": "character"},
}


## Name words that tell the kind of surface, in the order they are tried (a cliff before rock,
## ground words before rock: "rocks_ground" is ground).
const DETECT_WORDS := [
	["cliff", ["cliff", "rockface", "crag"]],
	["brick", ["brick", "bricks", "masonry"]],
	["concrete", ["concrete", "cement", "plaster", "stucco"]],
	["asphalt", ["asphalt", "tarmac", "road"]],
	["snow", ["snow", "ice", "frost"]],
	["sand", ["sand", "beach", "desert", "dune", "dunes"]],
	["mud", ["mud", "dirt", "soil", "clay", "muddy"]],
	["wood", ["wood", "wooden", "bark", "plank", "planks", "timber", "log", "tree"]],
	["metal_damage", ["metal", "rust", "rusty", "steel", "iron", "scratched", "painted"]],
	["organic", ["scales", "skin", "leather", "reptile", "organic", "flesh"]],
	["terrain", ["ground", "gravel", "pebbles", "forest", "grass", "terrain", "floor", "cobblestone", "cobble", "path"]],
	["rock", ["rock", "rocks", "rocky", "stone", "stones", "boulder", "boulders"]],
]


## The preset a texture set's or material's name suggests ("rocks_ground_05": terrain,
## "Rock_Cliff": cliff, "brick_wall_001": brick), or "" when no word tells.
static func detect(name: String) -> String:
	var words := PackedStringArray()
	for w in name.to_lower().replace("-", "_").replace(" ", "_").replace(".", "_").split("_", false):
		words.append(w)
	for entry: Array in DETECT_WORDS:
		for w in words:
			if w in entry[1]:
				return entry[0]
	return ""


## The relief depth per metre of texture preset [param id] gives (0 for an unknown id).
static func depth_per_metre(id: String) -> float:
	return float((PRESETS.get(id, {}) as Dictionary).get("depth_per_m", 0.0))


## The preset ids, in menu order.
static func ids() -> PackedStringArray:
	return PackedStringArray(PRESETS.keys())


static func label(id: String) -> String:
	return String((PRESETS.get(id, {}) as Dictionary).get("label", id))


## The shader parameters preset [param id] gives a material whose texture covers
## [param tile_m] metres (its height_m from the preset's depth per metre), or {} for an unknown id.
static func params_for(id: String, tile_m := 2.0) -> Dictionary:
	if not PRESETS.has(id):
		return {}
	var preset: Dictionary = PRESETS[id]
	var out: Dictionary = (preset["params"] as Dictionary).duplicate()
	out["height_m"] = snappedf(float(preset["depth_per_m"]) * tile_m, 0.0001)
	return out


## The metres one repeat of [param material]'s textures covers: texture_size_m on world and
## triplanar mappings, [param uv_tile_m] (unknown from the material) on UV mapping.
static func tile_of(material: ShaderMaterial, uv_tile_m := 2.0) -> float:
	var info := GADSMaterials.parse(material.shader)
	if info.is_empty() or info["mapping"] == M.UV:
		return uv_tile_m
	var size: Vector2 = GADSMaterials.get_param(material, "texture_size_m")
	return maxf(size.x, size.y)


## Sets [param material]'s displacement to preset [param id] (see the class description): its
## parameters, height_m for its texture size (UV mapping: [param uv_tile_m] metres per repeat) and
## parallax variant; textures and mapping stay. World-planar materials keep height_center 0 (the
## ground convention the near-camera field relies on). Returns false for an unknown id or a
## material that is not a GADS material.
static func apply(material: ShaderMaterial, id: String, uv_tile_m := 2.0) -> bool:
	if not PRESETS.has(id) or not GADSMaterials.is_gads_material(material):
		return false
	var values := params_for(id, tile_of(material, uv_tile_m))
	if GADSMaterials.parse(material.shader).get("mapping", M.UV) == M.WORLD:
		values["height_center"] = 0.0
	for key: String in values:
		material.set_shader_parameter(key, values[key])
	GADSMaterials.set_quality(material, PRESETS[id]["quality"])
	return true


## A new GADS material of preset [param id]. [param textures]: as [method GADSMaterials.create]
## takes them; empty: procedural maps of the preset's pattern ([GADSProcedural]). Options:
## "tile_m" (metres one repeat covers, 2), "mapping" (default the preset's), "size" (procedural
## maps, 512 px), "seed".
static func create(id: String, textures := {}, options := {}) -> ShaderMaterial:
	if not PRESETS.has(id):
		push_error("GADSSurfacePresets: unknown preset %s (%s)" % [id, ", ".join(ids())])
		return null
	var preset: Dictionary = PRESETS[id]
	var tile := float(options.get("tile_m", 2.0))
	var mapping: int = options.get("mapping", preset["mapping"])
	var tex := textures
	if tex.is_empty():
		var pattern_params: Dictionary = (preset.get("pattern_params", {}) as Dictionary).duplicate()
		if options.has("seed"):
			pattern_params["seed"] = options["seed"]
		var maps_options := {"size": int(options.get("size", 512)), "tile_m": Vector2(tile, tile), "params": pattern_params,
			"depth_m": float(preset["depth_per_m"]) * tile}
		if preset.has("colors"):
			maps_options["colors"] = preset["colors"]
		var maps := GADSProcedural.make_maps(preset["pattern"], maps_options)
		if maps.is_empty():
			return null
		tex = {"height": GADSProcedural.texture_of(maps["height"], true), "normal": GADSProcedural.texture_of(maps["normal"]),
			"albedo": GADSProcedural.texture_of(maps["albedo"]), "orm": GADSProcedural.texture_of(maps["orm"])}
	var params := {}
	if mapping != M.UV:
		params["texture_size_m"] = Vector2(tile, tile)
	var material := GADSMaterials.create(mapping, tex, params, preset["quality"])
	apply(material, id, tile)
	material.resource_name = id
	return material


## The GADSProfile a baked mesh of preset [param id] takes (rock for Rock and Cliff, wall for
## Brick and Concrete, terrain for ground, prop, character for Organic), or null.
static func profile_for(id: String) -> GADSProfile:
	if not PRESETS.has(id):
		return null
	return GADSProfile.builtin(PRESETS[id]["profile"])
