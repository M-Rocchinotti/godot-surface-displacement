@tool
extends EditorPlugin
## Editor-side test, run by tests/run_editor_check.py inside a throwaway project: exercises the
## GADS plugin's Tools actions (including making and baking a GADSMeshInstance3D) and their
## undo/redo in a real editor, checks what
## a save writes, prints "EDITOR CHECK OK" or "EDITOR CHECK FAIL", then quits the editor.

var _frames := 0
var _failures: PackedStringArray = []
var _sd_plugin: EditorPlugin
var _busy := false


func _enter_tree() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	if _busy:
		return
	_frames += 1
	if _frames == 30:
		EditorInterface.open_scene_from_path("res://check_scene.tscn")
	elif _frames == 60:
		_busy = true
		await _run()
		_busy = false


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failures.append(what)


func _frames_wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	var root := EditorInterface.get_edited_scene_root()
	_check(root != null and root.name == "CheckScene", "test scene is open")
	if root == null:
		_finish()
		return
	_sd_plugin = load("res://addons/gads/plugin.gd").new()
	var manager := EditorInterface.get_editor_undo_redo()
	var ur := manager.get_history_undo_redo(manager.get_object_history_id(root))
	var project_text := FileAccess.get_file_as_string("res://project.godot")
	_check(project_text.contains("gads_pom_steps=") and project_text.contains("gads_dfg="), "the plugin registered its shader globals in project.godot")

	# 1. GADSManager node, undo, redo.
	_sd_plugin.add_manager_node()
	_check(root.find_children("*", "GADSManager", true, false).size() == 1, "Add GADSManager Node adds one")
	ur.undo()
	_check(root.find_children("*", "GADSManager", true, false).is_empty(), "undo removes it")
	ur.redo()
	_check(root.find_children("*", "GADSManager", true, false).size() == 1, "redo adds it back")

	# 2. Field for the selected ground.
	var ground := root.get_node("Ground") as MeshInstance3D
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(ground)
	_sd_plugin.add_field_for_selection()
	var fields := root.find_children("*", "GADSDisplacementField3D", true, false)
	var field := fields[0] as GADSDisplacementField3D if fields.size() == 1 else null
	_check(field != null and field.layers.size() == 1 and field.layers[0] == ground.material_override and ground.is_in_group(&"gads_ground"),
			"Add GADSDisplacementField3D uses the selected ground's material as its layer and puts the ground in the group")
	ur.undo()
	_check(root.find_children("*", "GADSDisplacementField3D", true, false).is_empty() and not ground.is_in_group(&"gads_ground"), "undo removes the field and the group")
	ur.redo()
	field = root.find_children("*", "GADSDisplacementField3D", true, false)[0] as GADSDisplacementField3D

	# 3. Material conversion.
	var box := root.get_node("HeightBox") as MeshInstance3D
	var glass := root.get_node("GlassBox") as MeshInstance3D
	var csg := root.get_node("HeightCSG") as GeometryInstance3D
	var old := box.material_override
	var old_csg := csg.get("material") as Material
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(box)
	EditorInterface.get_selection().add_node(glass)
	EditorInterface.get_selection().add_node(csg)
	_sd_plugin.convert_selection()
	var info := GADSMaterials.parse((box.material_override as ShaderMaterial).shader) if box.material_override is ShaderMaterial else {}
	_check(not info.is_empty() and info["mapping"] == GADSMaterials.Mapping.UV and glass.material_override is StandardMaterial3D,
			"Convert Materials turns the height-map material into a UV-mapped GADS material and skips the transparent one")
	_check(GADSMaterials.is_gads_material(csg.get("material")), "it converts a CSG shape's material too")
	ur.undo()
	_check(box.material_override == old and csg.get("material") == old_csg, "undo restores the original materials")
	ur.redo()
	_check(box.material_override is ShaderMaterial and GADSMaterials.is_gads_material(csg.get("material")), "redo converts again")

	# 4. Ground bake (renders in the editor).
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(field)
	await _sd_plugin.bake_selected_field()
	_check(field.ground_bake != null and FileAccess.file_exists("res://check_scene_ground.res"), "Bake Ground saves the bake next to the scene and assigns it")
	if field.ground_bake != null:
		_check(absf(field.ground_bake.sample_height(Vector2(1.0, -2.0))) < 0.001 and field.ground_bake.sample_weights(Vector2(1.0, -2.0)).r > 0.99,
				"the baked ground is at y = 0 and carries the ground's layer")
	ur.undo()
	_check(field.ground_bake == null, "undo removes the bake from the field")
	ur.redo()
	# A second bake while the first is still assigned (the resource cache holds the old one).
	ground.position.y = 0.5
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(field)
	await _sd_plugin.bake_selected_field()
	_check(field.ground_bake != null and absf(field.ground_bake.sample_height(Vector2(1.0, -2.0)) - 0.5) < 0.001
			and field.ground_bake.resource_path == "res://check_scene_ground.res",
			"baking again gives the field the new ground, still from the saved file")
	# Undo and redo of the re-bake must leave a bake that is saved as a reference, not embedded.
	ur.undo()
	ur.redo()
	ground.position.y = 0.0

	# 5. Validation.
	var issues := GADSValidator.validate(root)
	var errors := issues.filter(func(i: Dictionary) -> bool: return i["level"] == "error")
	_check(errors.is_empty(), "Validate Setup finds no errors (%d issues)" % issues.size())

	# 6. Height-map preparation.
	var stats := GADSHeightTools.convert_to_half_exr("res://height_source.png", "res://height_source_gads_height.exr")
	_check(not stats.is_empty() and FileAccess.file_exists("res://height_source_gads_height.exr") and FileAccess.file_exists("res://height_source_gads_height.exr.import"),
			"Prepare Height Maps writes a 16-bit EXR with its import settings (source levels: %d)" % stats.get("levels", 0))
	var exr := Image.load_from_file(ProjectSettings.globalize_path("res://height_source_gads_height.exr"))
	_check(exr != null and exr.get_format() == Image.FORMAT_RH and absf(exr.get_pixel(31, 0).r - 1.0) < 0.01 and absf(exr.get_pixel(0, 0).r) < 0.01,
			"it is one half-float channel, remapped to 0-1")

	# 7. Baked displacement: make the converted box a GADSMeshInstance3D, bake it, undo and redo.
	var box_mesh := box.mesh
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(box)
	_sd_plugin.convert_selected_meshes()
	var baked_box := root.get_node("HeightBox") as GADSMeshInstance3D
	_check(baked_box != null and baked_box.source_mesh == box_mesh and baked_box.mesh == box_mesh and not baked_box.baked,
			"Make Selected Meshes GADSMeshInstance3D keeps the mesh as the source")
	ur.undo()
	_check(not root.get_node("HeightBox") is GADSMeshInstance3D and box.mesh == box_mesh, "undo makes it a plain MeshInstance3D again")
	ur.redo()
	baked_box = root.get_node("HeightBox") as GADSMeshInstance3D
	EditorInterface.edit_node(baked_box)
	await _frames_wait(5)
	var buttons := EditorInterface.get_inspector().find_children("*", "Button", true, false).filter(
			func(b: Button) -> bool: return b.text in ["Bake", "Rebuild", "Clear"])
	_check(buttons.size() == 3, "the inspector shows Bake, Rebuild and Clear")
	_sd_plugin.bake_selected_meshes()
	var baked_path: String = baked_box.bake_stats.get("path", "") if baked_box != null else ""
	_check(baked_box != null and baked_box.baked and baked_path.begins_with("res://gads_baked/") and FileAccess.file_exists(baked_path)
			and baked_box.mesh.resource_path == baked_path and baked_box.bake_stats.get("triangles", 0) > 12,
			"Bake Selected GADSMeshInstance3D bakes it into res://gads_baked/ (%d triangles)" % (baked_box.bake_stats.get("triangles", 0) if baked_box != null else 0))
	ur.undo()
	_check(not baked_box.baked and baked_box.mesh == box_mesh, "undo shows the source mesh again")
	ur.redo()
	_check(baked_box.baked and baked_box.mesh.resource_path == baked_path, "redo shows the bake again")
	EditorInterface.get_selection().clear()

	# 8. The GADS bottom panel profiles the scene.
	var panels := EditorInterface.get_base_control().find_children("GADS", "VBoxContainer", true, false).filter(
			func(n: Node) -> bool: return n.has_method("refresh_report"))
	_check(panels.size() == 1, "the GADS bottom panel is there")
	if panels.size() == 1:
		panels[0].refresh_report()
		var report: Dictionary = panels[0].get_report()
		_check(report.get("totals", {}).get("objects", 0) == 1 and report.get("surfaces", 0) >= 2,
				"it lists the baked box and the parallax surfaces (%s)" % report.get("totals", {}))

	# 10. A downloaded texture set becomes a GADS material (Create Material from Selected Textures).
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://texset"))
	var albedo := Image.create(32, 32, false, Image.FORMAT_RGB8)
	albedo.fill(Color(0.6, 0.4, 0.3))
	albedo.save_png(ProjectSettings.globalize_path("res://texset/Cliff_BaseColor.png"))
	var nrm := Image.create(32, 32, false, Image.FORMAT_RGB8)
	nrm.fill(Color8(128, 64, 255))
	nrm.save_png(ProjectSettings.globalize_path("res://texset/Cliff_Normal_DX.png"))
	var rough := Image.create(32, 32, false, Image.FORMAT_L8)
	rough.fill(Color(0.7, 0.7, 0.7))
	rough.save_png(ProjectSettings.globalize_path("res://texset/Cliff_Roughness.png"))
	var disp := Image.create(32, 32, false, Image.FORMAT_L8)
	for y in 32:
		for x in 32:
			disp.set_pixel(x, y, Color(x / 31.0, 0, 0))
	disp.save_png(ProjectSettings.globalize_path("res://texset/Cliff_Height.png"))
	var set_files := PackedStringArray(["res://texset/Cliff_BaseColor.png", "res://texset/Cliff_Normal_DX.png",
		"res://texset/Cliff_Roughness.png", "res://texset/Cliff_Height.png"])
	var texture_sets := GADSTextureSet.detect(set_files)
	_check(texture_sets.size() == 1 and texture_sets[0]["name"] == "cliff" and texture_sets[0]["normal_dx"], "the texture set is found, DirectX normal map and all")
	var made: PackedStringArray = await _sd_plugin.create_materials(texture_sets, [{"texture_size_m": 3.0, "height_m": 0.09, "mapping": GADSMaterials.Mapping.TRIPLANAR}])
	var cliff := load(made[0]) as ShaderMaterial if made.size() == 1 else null
	var cliff_info := GADSMaterials.parse(cliff.shader) if cliff != null else {}
	_check(made == PackedStringArray(["res://texset/cliff_gads.tres"]) and not cliff_info.is_empty() and cliff_info["mapping"] == GADSMaterials.Mapping.TRIPLANAR,
		"it saves a triplanar GADS material next to the textures (%s)" % [made])
	if cliff != null:
		var h := cliff.get_shader_parameter("height_texture") as Texture2D
		var o := cliff.get_shader_parameter("orm_texture") as Texture2D
		var n := cliff.get_shader_parameter("normal_texture") as Texture2D
		var a := cliff.get_shader_parameter("albedo_texture") as Texture2D
		_check(h != null and h.resource_path == "res://texset/cliff_gads_height.exr" and o != null and o.resource_path == "res://texset/cliff_gads_orm.png"
			and n != null and n.resource_path == "res://texset/cliff_gads_normal.png" and a != null and a.resource_path == "res://texset/Cliff_BaseColor.png",
			"with the converted height, the packed ORM, the flipped normal map and the albedo, all imported")
		_check(is_equal_approx(cliff.get_shader_parameter("height_m"), 0.09) and cliff.get_shader_parameter("texture_size_m") == Vector2(3, 3)
			and h != null and h.get_image().has_mipmaps(), "and the chosen depth and size; the height has mipmaps")

	# 11. A procedural material (Generate Procedural Material): maps written, imported, saved. (Right
	# after the texture set, whose own albedo the editor re-imports once a preview draws it in 3D:
	# the import has to wait for that one.)
	var generated: String = await _sd_plugin.generate_procedural_material("bricks", "res://procedural", "wall",
		{"size": 64, "tile_m": Vector2(2, 2), "mapping": GADSMaterials.Mapping.TRIPLANAR})
	var wall := load(generated) as ShaderMaterial if not generated.is_empty() else null
	_check(generated == "res://procedural/wall_gads.tres" and wall != null and GADSMaterials.parse(wall.shader).get("mapping", -1) == GADSMaterials.Mapping.TRIPLANAR,
		"a procedural brick material is generated and saved (%s)" % generated)
	if wall != null:
		var ok := true
		for role in ["height", "normal", "albedo", "orm"]:
			var t := wall.get_shader_parameter(role + "_texture") as Texture2D
			ok = ok and t != null and t.resource_path.begins_with("res://procedural/wall_") and t.get_image() != null and t.get_image().has_mipmaps()
		_check(ok and is_equal_approx(wall.get_shader_parameter("height_m"), 0.04) and wall.get_shader_parameter("texture_size_m") == Vector2(2, 2),
			"with its four maps imported (mipmaps) and the brick depth for a 2 m tile")

	# 12. The Sculpt tool: a stroke on the baked box (as the viewport's left-drag sends it) stores a
	# sculpt map next to the bakes and bakes again; undo and redo.
	var sculpted := root.get_node("HeightBox") as GADSMeshInstance3D
	if sculpted != null and sculpted.baked:
		var key_before := sculpted.bake_key
		GADSSculpt.tool_active = true
		GADSSculpt.tool_node = sculpted
		GADSSculpt.tool_mode = GADSSculpt.Mode.RAISE
		GADSSculpt.tool_radius = 0.3
		GADSSculpt.tool_strength = 0.02
		var top := sculpted.global_transform * sculpted.source_mesh.get_aabb().get_center() + Vector3(0, 3, 0)
		var hits := 0
		for i in 6:
			hits += 1 if _sd_plugin.sculpt_at(sculpted, top + Vector3(0.04 * i, 0, 0.02 * i), Vector3.DOWN) else 0
		_sd_plugin.end_sculpt_stroke()
		await _until_baked(sculpted)
		var map_path := sculpted.sculpt_map.resource_path if sculpted.sculpt_map != null else ""
		_check(hits == 6 and map_path.begins_with(sculpted.cache_directory) and FileAccess.file_exists(map_path) and sculpted.bake_key != key_before,
			"a Sculpt stroke saves the sculpt map next to the bakes (%s) and bakes again" % map_path)
		ur.undo()
		await _until_baked(sculpted)
		_check(sculpted.sculpt_map == null and sculpted.bake_key == key_before, "undo removes the stroke and its bake")
		ur.redo()
		await _until_baked(sculpted)
		_check(sculpted.sculpt_map != null and sculpted.bake_key != key_before, "redo brings it back")
		ur.undo()
		await _until_baked(sculpted)
		GADSSculpt.tool_active = false
		GADSSculpt.tool_node = null

	# 13. Clean Bake Cache: a stale bake nothing refers to is listed and removed; the bakes the open
	# scene uses (and its undo history holds) and files not named like bakes stay.
	DirAccess.make_dir_recursive_absolute("res://gads_baked")
	var stale_path := "res://gads_baked/stale_0123456789abcdef.mesh"
	var stale_mesh := ArrayMesh.new()
	stale_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
	ResourceSaver.save(stale_mesh, stale_path)
	var notes := FileAccess.open("res://gads_baked/notes.txt", FileAccess.WRITE)
	notes.store_string("not a bake")
	notes.close()
	var unused := GADSBakeCache.find_unused()
	var in_use := baked_box.mesh.resource_path if baked_box != null and baked_box.baked else ""
	_check(stale_path in unused and not in_use.is_empty() and not in_use in unused and not "res://gads_baked/notes.txt" in unused,
		"Clean Bake Cache lists the stale bake, not the one in use (%s) nor other files: %s" % [in_use, unused])
	_check(_sd_plugin.clean_bake_cache(PackedStringArray([stale_path])) == 1 and not FileAccess.file_exists(stale_path)
		and FileAccess.file_exists(in_use), "it removes the stale bake and keeps the one in use")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://gads_baked/notes.txt"))
	await _frames_wait(5)

	# 14. Terrain Sculpt / Paint: strokes as the viewport sends them, the edited maps saved next to
	# the scene, undo and redo (the first stroke's undo gives the original map back).
	var terrain := GADSTerrain3D.new()
	terrain.name = "Terrain"
	terrain.size = Vector2(16, 16)
	terrain.vertex_spacing = 0.5
	terrain.chunk_quads = 16
	terrain.height_scale = 10.0
	terrain.detail_field = false
	terrain.position = Vector3(40, 0, 0)
	root.add_child(terrain)
	terrain.owner = root
	await _frames_wait(2)
	var aim := Vector3(41, 0, 1)
	var h0 := terrain.get_height(aim)
	GADSSculpt.tool_active = true
	GADSSculpt.tool_node = terrain
	GADSSculpt.tool_mode = GADSSculpt.Mode.RAISE
	GADSSculpt.tool_paint = -1
	GADSSculpt.terrain_radius = 2.0
	GADSSculpt.terrain_strength = 0.5
	var dabs := 0
	for i in 4:
		dabs += 1 if _sd_plugin.sculpt_at(terrain, aim + Vector3(0.05 * i, 20, 0), Vector3.DOWN) else 0
	_sd_plugin.end_sculpt_stroke()
	var height_path := terrain.heightmap.resource_path if terrain.heightmap != null else ""
	_check(dabs == 4 and terrain.get_height(aim) > h0 + 1.0 and height_path.begins_with(terrain.data_directory) and FileAccess.file_exists(height_path),
		"a terrain Sculpt stroke raises the ground (%.2f m) and saves the heightmap (%s)" % [terrain.get_height(aim) - h0, height_path])
	ur.undo()
	await _frames_wait(2)
	_check(terrain.heightmap == null and absf(terrain.get_height(aim) - h0) < 1e-4, "undo puts the heights and the original (no) heightmap back")
	ur.redo()
	await _frames_wait(2)
	_check(terrain.heightmap != null and terrain.heightmap.resource_path == height_path and terrain.get_height(aim) > h0 + 1.0, "redo sculpts again")
	GADSSculpt.tool_paint = 1
	dabs = 0
	for i in 4:
		dabs += 1 if _sd_plugin.sculpt_at(terrain, aim + Vector3(0, 20, 0.05 * i), Vector3.DOWN) else 0
	_sd_plugin.end_sculpt_stroke()
	var splat_path := terrain.splatmap.resource_path if terrain.splatmap != null else ""
	_check(dabs == 4 and terrain.get_layer_weights(aim).x > 0.5 and splat_path.begins_with(terrain.data_directory) and FileAccess.file_exists(splat_path),
		"a Paint stroke paints the second layer and saves the splat map (%s)" % splat_path)
	ur.undo()
	await _frames_wait(2)
	_check(terrain.splatmap == null and terrain.get_layer_weights(aim).x < 0.01 and terrain.get_height(aim) > h0 + 1.0, "undo removes the paint, the sculpt stays")
	ur.redo()
	await _frames_wait(2)
	GADSSculpt.tool_active = false
	GADSSculpt.tool_node = null
	GADSSculpt.tool_paint = -1
	# Generate (the inspector's button): one undoable action.
	var sculpted_h := terrain.get_height(aim)
	_sd_plugin.edit_terrain_heights(terrain, "Generate GADS Terrain", func() -> void: terrain.generate_heights("ridged", {"seed": 2}))
	var generated_h := terrain.get_height(aim)
	ur.undo()
	await _frames_wait(2)
	var undone_h := terrain.get_height(aim)
	ur.redo()
	await _frames_wait(2)
	_check(absf(generated_h - sculpted_h) > 1e-3 and absf(undone_h - sculpted_h) < 1e-4 and absf(terrain.get_height(aim) - generated_h) < 1e-4,
		"Generate replaces the heights, undo and redo")
	# A road (GADSTerrainPath3D's Apply to Terrain, the editor's undo).
	var road := GADSTerrainPath3D.new()
	road.name = "Road"
	road.curve = Curve3D.new()
	road.curve.add_point(Vector3(-6, 0, -1))
	road.curve.add_point(Vector3(6, 0, 1))
	road.layer = 1
	terrain.add_child(road)
	road.owner = root
	var on_road := Vector3(40, 0, 0)
	var before_road := terrain.get_height(on_road)
	var road_rect := road.apply()
	var road_h := terrain.get_height(on_road)
	ur.undo()
	await _frames_wait(2)
	var undone_road := terrain.get_height(on_road)
	ur.redo()
	await _frames_wait(2)
	_check(road_rect.has_area() and absf(undone_road - before_road) < 1e-4 and absf(terrain.get_height(on_road) - road_h) < 1e-4
		and terrain.get_layer_weights(on_road).x > 0.9, "Apply to Terrain flattens and paints a road, undo and redo")

	# 9. What a save writes.
	EditorInterface.save_scene()
	await _frames_wait(5)
	var text := FileAccess.get_file_as_string("res://check_scene.tscn")
	_check(text.contains('path="%s"' % baked_path) and text.contains("source_mesh") and text.contains("instance_shader_parameters/gads_baked = 1.0"),
			"the baked box refers to its bake file, keeps its source mesh and the baked flag")
	_check(not text.contains("FieldMesh") and not text.contains("Pebbles"), "the field's internal mesh is not saved with the scene")
	_check(text.contains("gads_world_pom_ss.gdshader"), "the editor does not switch the saved material's variant")
	# The node's default preset (Medium) has no near-camera geometry; in the editor that must not
	# hide the field or change its saved properties.
	_check(field.visible and not text.contains("visible = false") and not text.contains("resolution = "),
			"the GADSManager node leaves the field's saved properties alone in the editor")
	_check(text.contains("check_scene_ground.res") and not text.contains("gads_ground_bake.gd"), "the field keeps its bake as a reference to the file (nothing embedded)")
	_check(text.contains("check_scene_terrain_height.res") and text.contains("check_scene_terrain_splat.res") and not text.contains("Chunk_"),
		"the edited terrain refers to its saved heightmap and splat map (its chunks are not saved)")
	_finish()


func _until_baked(node: GADSMeshInstance3D) -> void:
	for i in 600:
		await get_tree().process_frame
		if not node.is_baking() and i > 2:
			return


func _finish() -> void:
	print("EDITOR CHECK OK" if _failures.is_empty() else "EDITOR CHECK FAIL: %s" % ", ".join(_failures))
	if _sd_plugin != null:
		_sd_plugin.free()
	# Quitting while the field is still selected, right after undoing and redoing its bake, makes
	# the 4.7.2 editor report "Can't use get_node() with absolute paths from outside the active
	# scene tree" during shutdown (after the scene was saved; nothing is lost). The cause was not
	# found; with the selection cleared first it does not happen (README, Troubleshooting).
	EditorInterface.get_selection().clear()
	await _frames_wait(10)
	get_tree().quit(0 if _failures.is_empty() else 1)
