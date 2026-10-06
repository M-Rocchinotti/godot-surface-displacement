@tool
class_name GADSProcedural
extends RefCounted
## Relief without texture files: tileable procedural height maps (noise, ridged, billow, rock,
## stones, cracks, bricks, tiles, waves, ripples, craters) and the maps a material needs from a
## height map (normal, ambient occlusion, curvature, a two-colour albedo, ORM), made by the
## native GADSHeightGenerator in milliseconds. Use them in memory, or write them as a texture set
## (the editor's Project > Tools > GADS: Generate Procedural Material does).
##
## [codeblock]
## $Wall.material_override = GADSProcedural.create_material("bricks", {"params": {"seed": 3}})
## var height := GADSProcedural.height_image("craters", 1024, {"scale": 6})
## [/codeblock]
##
## Every map tiles: each pattern repeats a whole number of times per tile. The same kind, size,
## seed and parameters give the same map on every machine.

const NATIVE := &"GADSHeightGenerator"

## Per kind: generator parameters, relief depth (m) for a 1 m tile, albedo colours (low, high),
## roughness. Parameters you pass override these.[br]
## Generator parameters: [code]seed[/code], [code]scale[/code] (features per tile),
## [code]octaves[/code], [code]gain[/code], [code]lacunarity[/code], [code]warp[/code] (domain
## warp, in features), [code]width[/code] (gaps, mortar, cracks, in features), [code]bevel[/code]
## (rounding), [code]variation[/code] (height between stones / bricks), [code]aspect[/code]
## (brick length / height), [code]roughness[/code] (fine noise), [code]sharpness[/code] (wave
## crests), [code]count[/code] (craters, ripple centres).
const PRESETS := {
	"noise": {"params": {"scale": 4, "octaves": 6}, "depth_m": 0.02, "colors": [Color(0.3, 0.27, 0.23), Color(0.6, 0.56, 0.5)], "roughness": 0.85},
	"ridged": {"params": {"scale": 3, "octaves": 6}, "depth_m": 0.04, "colors": [Color(0.25, 0.24, 0.23), Color(0.62, 0.6, 0.57)], "roughness": 0.8},
	"billow": {"params": {"scale": 4, "octaves": 5}, "depth_m": 0.03, "colors": [Color(0.28, 0.25, 0.2), Color(0.55, 0.5, 0.42)], "roughness": 0.9},
	"rock": {"params": {"scale": 3, "octaves": 7, "warp": 0.35}, "depth_m": 0.06, "colors": [Color(0.22, 0.21, 0.2), Color(0.58, 0.56, 0.53)], "roughness": 0.8},
	"stones": {"params": {"scale": 6, "width": 0.06, "bevel": 0.3, "variation": 0.35, "roughness": 0.05}, "depth_m": 0.04,
		"colors": [Color(0.18, 0.16, 0.13), Color(0.62, 0.6, 0.56)], "roughness": 0.75},
	"cracks": {"params": {"scale": 5, "width": 0.03, "warp": 0.4, "variation": 0.2, "roughness": 0.08}, "depth_m": 0.015,
		"colors": [Color(0.2, 0.15, 0.1), Color(0.55, 0.45, 0.33)], "roughness": 0.9},
	"bricks": {"params": {"scale": 8, "width": 0.1, "bevel": 0.12, "variation": 0.25, "roughness": 0.04}, "depth_m": 0.02,
		"colors": [Color(0.42, 0.4, 0.37), Color(0.55, 0.24, 0.17)], "roughness": 0.85},
	"tiles": {"params": {"scale": 4, "width": 0.04, "bevel": 0.05, "variation": 0.1, "roughness": 0.02}, "depth_m": 0.008,
		"colors": [Color(0.3, 0.3, 0.3), Color(0.82, 0.8, 0.76)], "roughness": 0.4},
	"waves": {"params": {"scale": 3, "sharpness": 0.4}, "depth_m": 0.03, "colors": [Color(0.55, 0.47, 0.34), Color(0.8, 0.72, 0.56)], "roughness": 0.95},
	"ripples": {"params": {"scale": 3}, "depth_m": 0.01, "colors": [Color(0.5, 0.43, 0.32), Color(0.76, 0.68, 0.53)], "roughness": 0.95},
	"craters": {"params": {"scale": 4, "roughness": 0.06}, "depth_m": 0.05, "colors": [Color(0.24, 0.22, 0.2), Color(0.55, 0.52, 0.48)], "roughness": 0.9},
}


## Whether the native generator is loaded (the GADS library for this platform).
static func is_available() -> bool:
	return ClassDB.class_exists(NATIVE)


## The kinds of height map: noise, ridged, billow, rock, stones, cracks, bricks, tiles, waves,
## ripples, craters.
static func get_kinds() -> PackedStringArray:
	return PackedStringArray(PRESETS.keys())


## The generator parameters for [param kind]: its preset's with [param params] on top.
static func params_of(kind: String, params := {}) -> Dictionary:
	var p: Dictionary = (PRESETS.get(kind, {}) as Dictionary).get("params", {}).duplicate()
	p.merge(params, true)
	return p


## A [param size] x [param size] height map (FORMAT_RF, 0..1, 1 = top, no mipmaps) of
## [param kind] with [param params] (see [constant PRESETS]); null when the kind is unknown or the
## native library is missing.
static func height_image(kind: String, size := 512, params := {}) -> Image:
	if not _native_ok():
		return null
	return ClassDB.class_call_static(NATIVE, &"generate", kind, size, params_of(kind, params))


## [method height_image] as a texture for a GADS material: half floats with mipmaps.
static func height_texture(kind: String, size := 512, params := {}) -> ImageTexture:
	var img := height_image(kind, size, params)
	return texture_of(img, true) if img != null else null


## Tangent-space normals (OpenGL convention, as GADS materials read them; RGB8, no mipmaps) of a
## height map whose 0..1 range spans [param depth_m] metres over a tile of [param tile_m].
static func normal_image(height: Image, depth_m: float, tile_m := Vector2.ONE) -> Image:
	if not _native_ok() or height == null:
		return null
	return ClassDB.class_call_static(NATIVE, &"normal_map", height, depth_m, tile_m)


## Ambient occlusion of the relief (FORMAT_RF, 1 = open) from its horizon within
## [param radius_m] (default: four times the depth).
static func ao_image(height: Image, depth_m: float, tile_m := Vector2.ONE, radius_m := -1.0) -> Image:
	if not _native_ok() or height == null:
		return null
	return ClassDB.class_call_static(NATIVE, &"ambient_occlusion", height, depth_m, tile_m, radius_m if radius_m > 0.0 else 4.0 * depth_m)


## Curvature (FORMAT_RF): 0.5 flat, above on crests and edges, below in hollows and cracks;
## [param radius_texels] the scale it looks at.
static func curvature_image(height: Image, radius_texels := 4.0, gain := 4.0) -> Image:
	if not _native_ok() or height == null:
		return null
	return ClassDB.class_call_static(NATIVE, &"curvature", height, radius_texels, gain)


## Albedo (RGB8): [param low] to [param high] by height, darker where occluded and in hollows.
static func albedo_image(height: Image, low: Color, high: Color, ao: Image = null, curvature: Image = null) -> Image:
	if not _native_ok() or height == null:
		return null
	return ClassDB.class_call_static(NATIVE, &"albedo_map", height, low, high, ao, curvature, 0.6, 0.5)


## ORM (RGB8: occlusion, roughness, metallic 0): [param roughness], a little lower on crests and
## higher in hollows.
static func orm_image(ao: Image, curvature: Image, roughness := 0.85) -> Image:
	if not _native_ok() or (ao == null and curvature == null):
		return null
	return ClassDB.class_call_static(NATIVE, &"orm_map", ao, curvature, roughness, 0.15)


## The relief depth (m) [method make_maps] uses for [param options]: "depth_m", or the kind's
## depth for a 1 m tile times the tile size.
static func depth_of(kind: String, options := {}) -> float:
	if options.has("depth_m"):
		return float(options["depth_m"])
	var tile: Vector2 = options.get("tile_m", Vector2.ONE)
	return float((PRESETS.get(kind, {}) as Dictionary).get("depth_m", 0.03)) * maxf(tile.x, tile.y)


## The maps of a material from [param kind]: {"height" (RF), "normal", "albedo", "orm" (RGB8),
## "depth_m", "tile_m"}. [param options]: "size" (512), "params", "depth_m" and "colors" (default
## the kind's), "roughness", "tile_m" (Vector2, the metres one repeat covers: 1 m).
static func make_maps(kind: String, options := {}) -> Dictionary:
	var preset: Dictionary = PRESETS.get(kind, {})
	var size := int(options.get("size", 512))
	var tile: Vector2 = options.get("tile_m", Vector2.ONE)
	var depth := depth_of(kind, options)
	var height := height_image(kind, size, options.get("params", {}))
	if height == null:
		return {}
	var ao := ao_image(height, depth, tile)
	var curv := curvature_image(height, maxf(size / 128.0, 2.0))
	var colors: Array = options.get("colors", preset.get("colors", [Color(0.3, 0.3, 0.3), Color(0.7, 0.7, 0.7)]))
	return {
		"height": height,
		"normal": normal_image(height, depth, tile),
		"albedo": albedo_image(height, colors[0], colors[1], ao, curv),
		"orm": orm_image(ao, curv, float(options.get("roughness", preset.get("roughness", 0.85)))),
		"depth_m": depth,
		"tile_m": tile,
	}


## A GADS material of [param kind] with its maps in memory (see [method make_maps] for
## [param options]; also "mapping" ([enum GADSMaterials.Mapping], UV) and "quality"
## ([enum GADSMaterials.Quality], POM with self-shadowing)). World and triplanar mappings use
## the tile as texture size and put the relief above the surface on world-planar ground.
static func create_material(kind: String, options := {}) -> ShaderMaterial:
	var maps := make_maps(kind, options)
	if maps.is_empty():
		return null
	var mapping: int = options.get("mapping", GADSMaterials.Mapping.UV)
	var textures := {
		"height": texture_of(maps["height"], true),
		"normal": texture_of(maps["normal"]),
		"albedo": texture_of(maps["albedo"]),
		"orm": texture_of(maps["orm"]),
	}
	var params := {"height_m": maps["depth_m"], "height_center": 0.0 if mapping == GADSMaterials.Mapping.WORLD else 1.0}
	if mapping != GADSMaterials.Mapping.UV:
		params["texture_size_m"] = maps["tile_m"]
	var material := GADSMaterials.create(mapping, textures, params, options.get("quality", GADSMaterials.Quality.POM_SELF_SHADOW))
	material.resource_name = kind
	return material


## Writes the maps of [param kind] (see [method make_maps]) into [param dir] as a texture set the
## texture-set tools recognise: "<name>_height.exr" (half float), "<name>_normal.png",
## "<name>_albedo.png", "<name>_orm.png", each with import settings (lossless height with
## mipmaps). Returns {role: path}, empty on failure. Import them (the editor does) before use.
static func write_texture_set(kind: String, dir: String, name: String, options := {}) -> Dictionary:
	var maps := make_maps(kind, options)
	if maps.is_empty():
		return {}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var base := dir.path_join(name)
	var out := {}
	var height := (maps["height"] as Image).duplicate() as Image
	height.convert(Image.FORMAT_RH)
	# grayscale = false keeps the single channel named R (see GADSHeightTools.convert_to_half_exr).
	if height.save_exr(ProjectSettings.globalize_path(base + "_height.exr"), false) != OK:
		push_error("GADS: cannot write %s_height.exr" % base)
		return {}
	GADSHeightTools.write_import(base + "_height.exr")
	out["height"] = base + "_height.exr"
	for role: String in ["normal", "albedo", "orm"]:
		var path := "%s_%s.png" % [base, role]
		if (maps[role] as Image).save_png(ProjectSettings.globalize_path(path)) != OK:
			push_error("GADS: cannot write %s" % path)
			return {}
		GADSTextureSet._write_import(path, role == "normal")
		out[role] = path
	return out


## A texture of [param img] with mipmaps; [param half_float] stores it as half floats (heights).
static func texture_of(img: Image, half_float := false) -> ImageTexture:
	if img == null:
		return null
	var copy := img.duplicate() as Image
	if half_float:
		copy.convert(Image.FORMAT_RH)
	copy.generate_mipmaps()
	return ImageTexture.create_from_image(copy)


static func _native_ok() -> bool:
	if not is_available():
		push_error("GADS: procedural maps need the GADS native library, which is not loaded on this platform.")
		return false
	return true
