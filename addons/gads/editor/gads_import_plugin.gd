@tool
extends EditorScenePostImportPlugin
## Adds a GADS section to the scene import options (Advanced Import Settings, or the Import dock):
## convert height-mapped materials into GADS materials, and turn meshes named "*-gads" (or every
## mesh drawing a GADS material) into baked GADSMeshInstance3D nodes. See GADSImportTools.

const PREFIX := "gads/"


func _get_import_options(_path: String) -> void:
	add_import_option_advanced(TYPE_BOOL, PREFIX + "convert_materials", false)
	add_import_option_advanced(TYPE_FLOAT, PREFIX + "metres_per_repeat", 1.0, PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater,suffix:m")
	add_import_option_advanced(TYPE_INT, PREFIX + "meshes", GADSImportTools.Meshes.SUFFIX, PROPERTY_HINT_ENUM,
		"None,Named *-gads,Every Mesh With a GADS Material")
	add_import_option_advanced(TYPE_BOOL, PREFIX + "bake", true)
	add_import_option_advanced(TYPE_INT, PREFIX + "quality", GADSMeshInstance3D.Quality.MEDIUM, PROPERTY_HINT_ENUM,
		"Draft,Low,Medium,High,Ultra")


func _post_process(scene: Node) -> void:
	var options := {}
	for key: String in GADSImportTools.DEFAULTS:
		var value: Variant = get_option_value(PREFIX + key)
		if value != null:
			options[key] = value
	var report := GADSImportTools.process(scene, options)
	if report["converted"] > 0 or report["meshes"] > 0:
		print("GADS import: %d materials converted, %d GADSMeshInstance3D (%d baked)." % [report["converted"], report["meshes"], report["baked"]])
	for line: String in report["skipped"]:
		print("GADS import: %s" % line)
