@tool
extends EditorImportPlugin
## "GADS Height Map" in the Import dock's Import As: a height map imported for displacement, at
## full precision (16-bit PNGs keep their 16 bits, RAW / R16 heightmaps import at all), one
## channel, lossless, remapped and with mipmaps made for relief ([GADSHeightImport]). RAW and R16
## files import this way by default; for images pick it in Import As. Two presets: Material
## Height (half floats, remapped to 0..1) and Terrain Heightmap (32-bit floats, values as stored).

enum Preset { MATERIAL, TERRAIN }


func _get_importer_name() -> String:
	return "gads.height_map"


func _get_visible_name() -> String:
	return "GADS Height Map"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["png", "exr", "hdr", "jpg", "jpeg", "webp", "tga", "bmp"] + GADSHeightImport.RAW_EXTENSIONS)


func _get_save_extension() -> String:
	return "res"


func _get_resource_type() -> String:
	return "ImageTexture"


## Below the engine's texture importer, so images import as textures unless chosen; RAW and R16
## files have no other importer.
func _get_priority() -> float:
	return 0.5


func _get_import_order() -> int:
	return 0


func _get_format_version() -> int:
	return 1


func _get_preset_count() -> int:
	return 2


func _get_preset_name(preset_index: int) -> String:
	return "Terrain Heightmap" if preset_index == Preset.TERRAIN else "Material Height"


func _get_import_options(path: String, preset_index: int) -> Array[Dictionary]:
	# RAW / R16 files are terrain heightmaps: their defaults are the terrain preset's.
	var terrain := preset_index == Preset.TERRAIN or path.get_extension().to_lower() in GADSHeightImport.RAW_EXTENSIONS
	return [
		{"name": "channel", "default_value": GADSHeightImport.Channel.RED, "property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "Red,Green,Blue,Alpha,Luminance"},
		{"name": "invert", "default_value": false},
		{"name": "remap", "default_value": GADSHeightImport.Remap.NONE if terrain else GADSHeightImport.Remap.MIN_MAX,
			"property_hint": PROPERTY_HINT_ENUM, "hint_string": "None,Min Max,Percentiles"},
		{"name": "mipmaps/generate", "default_value": true},
		{"name": "mipmaps/filter", "default_value": GADSHeightImport.MipFilter.AVERAGE, "property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "Average,Max,Min"},
		{"name": "precision/float32", "default_value": terrain},
		{"name": "raw/width", "default_value": 0, "property_hint": PROPERTY_HINT_RANGE, "hint_string": "0,65536,1,or_greater"},
		{"name": "raw/big_endian", "default_value": false},
	]


func _get_option_visibility(path: String, option_name: StringName, options: Dictionary) -> bool:
	if String(option_name).begins_with("raw/"):
		return path.get_extension().to_lower() in GADSHeightImport.RAW_EXTENSIONS
	if option_name == &"mipmaps/filter":
		return bool(options.get("mipmaps/generate", true))
	return true


func _can_import_threaded() -> bool:
	return true


func _import(source_file: String, save_path: String, options: Dictionary, _platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var tex := GADSHeightImport.import_texture(source_file, options_for(options))
	if tex == null:
		return ERR_FILE_CORRUPT
	return ResourceSaver.save(tex, "%s.%s" % [save_path, _get_save_extension()], ResourceSaver.FLAG_COMPRESS)


## The importer's options as [method GADSHeightImport.import_texture] takes them.
static func options_for(options: Dictionary) -> Dictionary:
	return {
		"channel": int(options.get("channel", GADSHeightImport.Channel.RED)),
		"invert": bool(options.get("invert", false)),
		"remap": int(options.get("remap", GADSHeightImport.Remap.NONE)),
		"mipmaps": bool(options.get("mipmaps/generate", true)),
		"mip_filter": int(options.get("mipmaps/filter", GADSHeightImport.MipFilter.AVERAGE)),
		"float": bool(options.get("precision/float32", false)),
		"raw_width": int(options.get("raw/width", 0)),
		"raw_big_endian": bool(options.get("raw/big_endian", false)),
	}
