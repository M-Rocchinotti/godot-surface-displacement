@tool
extends EditorPlugin
## GADS editor integration: registers the shader globals the materials read and
## adds Project > Tools entries: add the GADSManager node, add a GADSDisplacementField3D for
## the selected ground, convert materials (undoable), turn selected meshes into
## GADSMeshInstance3D and bake them (undoable), bake the ground of the selected field, prepare
## height maps selected in the FileSystem dock, create materials from texture sets selected
## there, generate procedural materials, and validate the setup. GADSMeshInstance3D gets
## Bake / Rebuild / Clear buttons in the inspector; the GADS bottom panel profiles the scene; the
## scene import options get a GADS section (GADSImportTools).

const MENU_ADD_NODE := "GADS: Add GADSManager Node"
const MENU_ADD_FIELD := "GADS: Add GADSDisplacementField3D for Selected Ground"
const MENU_CONVERT := "GADS: Convert Materials (Selected)"
const MENU_BAKE := "GADS: Bake Ground of Selected Field"
const MENU_MESH_CONVERT := "GADS: Make Selected Meshes GADSMeshInstance3D"
const MENU_MESH_BAKE := "GADS: Bake Selected GADSMeshInstance3D"
const MENU_HEIGHT := "GADS: Prepare Height Maps (FileSystem Selection)"
const MENU_VALIDATE := "GADS: Validate Setup"
const MENU_TEXTURE_SET := "GADS: Create Material from Selected Textures"
const MENU_PROCEDURAL := "GADS: Generate Procedural Material..."
const MENUS: Array[String] = [MENU_ADD_NODE, MENU_ADD_FIELD, MENU_CONVERT, MENU_MESH_CONVERT, MENU_MESH_BAKE, MENU_BAKE,
	MENU_HEIGHT, MENU_TEXTURE_SET, MENU_PROCEDURAL, MENU_VALIDATE]
const MeshInspector := preload("res://addons/gads/editor/gads_mesh_inspector.gd")
const ProfilerPanel := preload("res://addons/gads/editor/gads_profiler_panel.gd")
const ImportPlugin := preload("res://addons/gads/editor/gads_import_plugin.gd")

var _mesh_inspector: EditorInspectorPlugin
var _stroke_node: GADSMeshInstance3D # the node of the stroke in progress (null: none)
var _stroke_before: Image # its sculpt map before the stroke (null: it had none)
var _pick_cache := {}
var _profiler_panel: Control
var _import_plugin: EditorScenePostImportPlugin


func _enable_plugin() -> void:
	GADSGlobals.ensure_registered(true)


func _enter_tree() -> void:
	GADSGlobals.ensure_registered(true)
	add_tool_menu_item(MENU_ADD_NODE, add_manager_node)
	add_tool_menu_item(MENU_ADD_FIELD, add_field_for_selection)
	add_tool_menu_item(MENU_CONVERT, convert_selection)
	add_tool_menu_item(MENU_MESH_CONVERT, convert_selected_meshes)
	add_tool_menu_item(MENU_MESH_BAKE, bake_selected_meshes)
	add_tool_menu_item(MENU_BAKE, bake_selected_field)
	add_tool_menu_item(MENU_HEIGHT, prepare_selected_height_maps)
	add_tool_menu_item(MENU_TEXTURE_SET, create_materials_from_selection)
	add_tool_menu_item(MENU_PROCEDURAL, generate_procedural_dialog)
	add_tool_menu_item(MENU_VALIDATE, validate)
	_mesh_inspector = MeshInspector.new()
	_mesh_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_mesh_inspector)
	_profiler_panel = ProfilerPanel.new()
	_profiler_panel.undo_redo = get_undo_redo()
	add_control_to_bottom_panel(_profiler_panel, "GADS")
	_import_plugin = ImportPlugin.new()
	add_scene_post_import_plugin(_import_plugin)


func _exit_tree() -> void:
	for item in MENUS:
		remove_tool_menu_item(item)
	remove_inspector_plugin(_mesh_inspector)
	_mesh_inspector = null
	remove_control_from_bottom_panel(_profiler_panel)
	_profiler_panel.queue_free()
	_profiler_panel = null
	remove_scene_post_import_plugin(_import_plugin)
	_import_plugin = null


## The GADS bottom panel (profiler, recommendations, Optimize for Target).
func get_profiler_panel() -> Control:
	return _profiler_panel


func _add_node_undoable(parent: Node, node: Node, action: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var ur := get_undo_redo()
	ur.create_action(action)
	ur.add_do_method(parent, "add_child", node, true)
	ur.add_do_method(self, "_set_owner_recursive", node, root)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)


func _set_owner_recursive(node: Node, owner_node: Node) -> void:
	node.owner = owner_node
	for child in node.get_children():
		_set_owner_recursive(child, owner_node)


func add_manager_node() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("GADS: open a 3D scene first.")
		return
	if not root.find_children("*", "GADSManager", true, false).is_empty():
		push_warning("GADS: this scene already has a GADSManager node.")
		return
	var node := GADSManager.new()
	node.name = "GADSManager"
	_add_node_undoable(root, node, "Add GADSManager node")


## A GADSDisplacementField3D whose layers are the world-planar GADS materials of the selected meshes;
## the meshes join the ground group (undoable as one action).
func add_field_for_selection() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var layers: Array[ShaderMaterial] = []
	var meshes: Array[MeshInstance3D] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		var candidates: Array = [node] + node.find_children("*", "MeshInstance3D", true, false)
		for c in candidates:
			var mi := c as MeshInstance3D
			if mi == null or mi.mesh == null:
				continue
			meshes.append(mi)
			for s in mi.mesh.get_surface_count():
				var m := GADSGroundBake.surface_material(mi, s) as ShaderMaterial
				var info := GADSMaterials.parse(m.shader) if m != null else {}
				if not info.is_empty() and info["mapping"] == GADSMaterials.Mapping.WORLD and not layers.has(m) and layers.size() < GADSDisplacementField3D.MAX_LAYERS:
					layers.append(m)
	if layers.is_empty():
		push_warning("GADS: select ground meshes that use world-planar GADS materials.")
		return
	var field := GADSDisplacementField3D.new()
	field.name = "GADSDisplacementField3D"
	field.layers = layers
	var ur := get_undo_redo()
	ur.create_action("Add GADSDisplacementField3D")
	ur.add_do_method(root, "add_child", field, true)
	ur.add_do_property(field, "owner", root)
	ur.add_do_reference(field)
	ur.add_undo_method(root, "remove_child", field)
	for mi in meshes:
		if not mi.is_in_group(field.ground_group):
			ur.add_do_method(mi, "add_to_group", field.ground_group, true)
			ur.add_undo_method(mi, "remove_from_group", field.ground_group)
	ur.commit_action()


## Converts the BaseMaterial3D height-map materials under the selection (or the whole scene when
## nothing is selected) into GADS materials, as one undoable action.
func convert_selection() -> void:
	var roots: Array[Node] = []
	roots.append_array(EditorInterface.get_selection().get_selected_nodes())
	if roots.is_empty() and EditorInterface.get_edited_scene_root() != null:
		roots.append(EditorInterface.get_edited_scene_root())
	var planned := GADSMaterialConverter.plan(roots)
	var assignments: Array = planned["assignments"]
	for s: Dictionary in planned["skipped"]:
		print("GADS: not converted %s on %s: %s" % [s["material"].resource_name, s["node"].name, s["reason"]])
	if assignments.is_empty():
		print("GADS: no convertible materials.")
		return
	var ur := get_undo_redo()
	ur.create_action("Convert materials to GADS")
	for a: Dictionary in assignments:
		if a["surface"] < 0:
			var property := GADSMaterialConverter.slot_property(a["surface"])
			ur.add_do_property(a["node"], property, a["to"])
			ur.add_undo_property(a["node"], property, a["previous"])
		else:
			ur.add_do_method(a["node"], "set_surface_override_material", a["surface"], a["to"])
			ur.add_undo_method(a["node"], "set_surface_override_material", a["surface"], a["previous"])
		ur.add_do_reference(a["to"])
	ur.commit_action()
	print("GADS: converted %d material(s) on %d surface(s); check height_m of each." % [planned["converted"], assignments.size()])


## The selected MeshInstance3D nodes (and those under them) that are not GADSMeshInstance3D yet,
## or that are when [param baked_type] is true.
func _selected_meshes(baked_type: bool) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		var candidates: Array = [node] + node.find_children("*", "MeshInstance3D", true, false)
		for c in candidates:
			if c is MeshInstance3D and (c is GADSMeshInstance3D) == baked_type and not out.has(c):
				out.append(c)
	return out


## Gives the selected MeshInstance3D nodes the GADSMeshInstance3D script (their mesh becomes the
## source mesh), as one undoable action. Nodes with a script of their own are left alone.
func convert_selected_meshes() -> void:
	var meshes := _selected_meshes(false).filter(func(mi: MeshInstance3D) -> bool: return mi.get_script() == null and mi.mesh != null)
	if meshes.is_empty():
		push_warning("GADS: select MeshInstance3D nodes that have a mesh and no script.")
		return
	var script: Script = load("res://addons/gads/geometry/gads_mesh_instance_3d.gd")
	var ur := get_undo_redo()
	ur.create_action("Make meshes GADSMeshInstance3D")
	for mi: MeshInstance3D in meshes:
		ur.add_do_method(mi, "set_script", script)
		ur.add_do_property(mi, "source_mesh", mi.mesh)
		ur.add_undo_method(mi, "set_script", null)
		ur.add_undo_property(mi, "mesh", mi.mesh)
	ur.commit_action()
	print("GADS: %d mesh(es) are GADSMeshInstance3D now; bake them from the inspector or Project > Tools." % meshes.size())


## Bakes the selected GADSMeshInstance3D nodes one after the other (blocking), as one undoable
## action.
func bake_selected_meshes() -> void:
	var meshes := _selected_meshes(true)
	if meshes.is_empty():
		push_warning("GADS: select GADSMeshInstance3D nodes.")
		return
	var before := {}
	var after := {}
	for mi: GADSMeshInstance3D in meshes:
		var state := mi.get_bake_state()
		if mi.bake() == OK:
			before[mi] = state
			after[mi] = mi.get_bake_state()
			print("GADS: baked %s: %s" % [mi.name, mi.get_bake_summary().replace("\n", " ")])
	if after.is_empty():
		return
	var ur := get_undo_redo()
	ur.create_action("Bake GADS meshes")
	for mi: GADSMeshInstance3D in after:
		ur.add_do_method(mi, "set_bake_state", after[mi])
		ur.add_undo_method(mi, "set_bake_state", before[mi])
	ur.commit_action(false)


## Bakes the selected field's ground and saves it next to the scene as <scene>_ground.res.
func bake_selected_field() -> void:
	var field: GADSDisplacementField3D = null
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is GADSDisplacementField3D:
			field = node
	var root := EditorInterface.get_edited_scene_root()
	if field == null or root == null:
		push_warning("GADS: select a GADSDisplacementField3D.")
		return
	var meshes := GADSGroundBake.collect_ground(field.get_tree(), field.ground_group)
	var bake := await GADSGroundBake.bake(meshes, field.layers, field.bake_texel_size)
	if bake == null:
		return
	if not is_instance_valid(field) or not is_instance_valid(root) or EditorInterface.get_edited_scene_root() != root:
		push_warning("GADS: the scene changed during the bake; nothing was saved.")
		return
	var scene_path := root.scene_file_path
	var path := (scene_path.get_basename() if not scene_path.is_empty() else "res://" + root.name.to_snake_case()) + "_ground.res"
	var err := ResourceSaver.save(bake, path)
	if err != OK:
		push_error("GADS: cannot save %s (%s)" % [path, error_string(err)])
		return
	# Load it back through the cache so the scene refers to the file. A re-bake overwrites the file,
	# and a plain load() would return the previous bake from the cache while it is in use:
	# CACHE_MODE_REPLACE refreshes that instance with the new data instead (undo cannot bring the
	# old bake back; its file is overwritten).
	bake = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	var ur := get_undo_redo()
	ur.create_action("Bake GADSDisplacementField3D ground")
	ur.add_do_property(field, "ground_bake", bake)
	ur.add_undo_property(field, "ground_bake", field.ground_bake)
	ur.commit_action()
	print("GADS: baked %s (%d x %d texels of %.2f m)." % [path, bake.get_size().x, bake.get_size().y, bake.texel_size])


## For each image selected in the FileSystem dock writes <name>_gads_height.exr next to it.
func prepare_selected_height_maps() -> void:
	var done := 0
	for path in EditorInterface.get_selected_paths():
		if not path.get_extension().to_lower() in ["png", "jpg", "jpeg", "exr", "webp", "tga", "bmp", "hdr"]:
			continue
		var dst := path.get_basename() + "_gads_height.exr"
		var stats := GADSHeightTools.convert_to_half_exr(path, dst)
		if not stats.is_empty():
			done += 1
			print("GADS: %s -> %s (source 1st / 99th percentile %.3f / %.3f, %d distinct levels)" % [path, dst, stats["p1"], stats["p99"], stats["levels"]])
	if done == 0:
		push_warning("GADS: select height map images in the FileSystem dock.")
	else:
		EditorInterface.get_resource_filesystem().scan()


## Creates a GADS material for every texture set among the files selected in the FileSystem dock
## (see GADSTextureSet): a dialog shows each set's files and the proposed size, depth and mapping.
func create_materials_from_selection() -> void:
	var sets := GADSTextureSet.detect(EditorInterface.get_selected_paths())
	if sets.is_empty():
		push_warning("GADS: select the images of a texture set (BaseColor, Normal, Roughness, Height, ...) in the FileSystem dock.")
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Create GADS Materials"
	dialog.ok_button_text = "Create"
	var box := VBoxContainer.new()
	dialog.add_child(box)
	var rows := []
	for s: Dictionary in sets:
		var rec := GADSTextureSet.recommend(s)
		var label := Label.new()
		var roles: Array = (s["files"] as Dictionary).keys()
		label.text = "%s  (%s%s)" % [s["name"], ", ".join(roles), ", DirectX normal" if s["normal_dx"] else ""]
		box.add_child(label)
		for note: String in rec["notes"]:
			var n := Label.new()
			n.text = "    " + note
			n.modulate = Color(1, 1, 1, 0.7)
			box.add_child(n)
		var grid := GridContainer.new()
		grid.columns = 6
		box.add_child(grid)
		var size := _spin(grid, "Texture size (m)", 0.05, 100.0, 0.05, rec["texture_size_m"].x)
		var depth := _spin(grid, "Relief depth (cm)", 0.1, 100.0, 0.1, rec["height_m"] * 100.0)
		var mapping_label := Label.new()
		mapping_label.text = "Mapping"
		grid.add_child(mapping_label)
		var mapping := OptionButton.new()
		for m in ["UV", "World-planar (ground)", "Triplanar"]:
			mapping.add_item(m)
		grid.add_child(mapping)
		# The depth follows the texture size until it is edited.
		size.value_changed.connect(func(v: float) -> void: depth.value = snappedf(GADSTextureSet.DEPTH_PER_METRE * v * 100.0, 0.1))
		rows.append({"set": s, "size": size, "depth": depth, "mapping": mapping})
	dialog.confirmed.connect(func() -> void:
		var options := []
		for r: Dictionary in rows:
			options.append({"texture_size_m": (r["size"] as SpinBox).value, "height_m": (r["depth"] as SpinBox).value / 100.0,
				"mapping": (r["mapping"] as OptionButton).selected})
		create_materials(sets, options)
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered(Vector2i(640, 0))


static func _spin(parent: Control, text: String, lo: float, hi: float, step: float, value: float) -> SpinBox:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.step = step
	spin.value = value
	parent.add_child(spin)
	return spin


## Creates the materials of [param sets] (GADSTextureSet.detect()) with [param options] (per set:
## {"texture_size_m", "height_m", "mapping"}): writes the prepared textures, imports them and saves
## "<name>_gads.tres" next to each set. Returns the material paths.
func create_materials(sets: Array, options: Array) -> PackedStringArray:
	var fs := EditorInterface.get_resource_filesystem()
	var created := PackedStringArray()
	var uses := []
	for s: Dictionary in sets:
		uses.append(GADSTextureSet.prepare(s))
	# Import what is new: the written files (*_gads_*, afresh even when an older version was
	# imported) and source files the editor has not imported yet.
	var pending := PackedStringArray()
	for use: Dictionary in uses:
		for path: String in use.values():
			if (path.get_file().contains("_gads_") or not is_imported(path)) and not pending.has(path):
				pending.append(path)
	await import_files(pending)
	for i in sets.size():
		var s: Dictionary = sets[i]
		var o: Dictionary = options[i] if i < options.size() else {}
		var use: Dictionary = uses[i]
		var size := float(o.get("texture_size_m", 2.0))
		var params := {"texture_size_m": Vector2(size, size), "height_m": float(o.get("height_m", GADSTextureSet.DEPTH_PER_METRE * size))}
		var path := String(s["dir"]).path_join("%s_gads.tres" % s["name"])
		var material := GADSTextureSet.create_material(use, params, int(o.get("mapping", GADSMaterials.Mapping.UV)), GADSMaterials.Quality.POM_SELF_SHADOW, path)
		if material != null and FileAccess.file_exists(path):
			fs.update_file(path)
			created.append(path)
			print("GADS: created %s (%s)" % [path, ", ".join(use.keys())])
	if not created.is_empty():
		EditorInterface.select_file(created[0])
	return created


## Asks for a procedural kind, its size, seed, scale, tile, depth, mapping, name and folder, then
## runs [method generate_procedural_material].
func generate_procedural_dialog() -> void:
	if not GADSProcedural.is_available():
		push_warning("GADS: procedural materials need the GADS native library, which is not loaded on this platform.")
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Generate Procedural GADS Material"
	dialog.ok_button_text = "Generate"
	var grid := GridContainer.new()
	grid.columns = 2
	dialog.add_child(grid)
	var add_row := func(text: String, control: Control) -> void:
		var label := Label.new()
		label.text = text
		grid.add_child(label)
		grid.add_child(control)
	var kinds := GADSProcedural.get_kinds()
	var kind := OptionButton.new()
	for k in kinds:
		kind.add_item(k.capitalize())
	add_row.call("Kind", kind)
	var size := OptionButton.new()
	for px in [256, 512, 1024, 2048]:
		size.add_item("%d px" % px)
	size.select(1)
	add_row.call("Size", size)
	var make_spin := func(lo: float, hi: float, step: float, value: float) -> SpinBox:
		var spin := SpinBox.new()
		spin.min_value = lo
		spin.max_value = hi
		spin.step = step
		spin.value = value
		return spin
	var seed_spin: SpinBox = make_spin.call(0, 99999, 1, 1)
	add_row.call("Seed", seed_spin)
	var scale: SpinBox = make_spin.call(1, 64, 1, 4)
	add_row.call("Features per tile", scale)
	var tile: SpinBox = make_spin.call(0.1, 50.0, 0.1, 1.0)
	add_row.call("Tile size (m)", tile)
	var depth: SpinBox = make_spin.call(0.1, 100.0, 0.1, 3.0)
	add_row.call("Relief depth (cm)", depth)
	var mapping := OptionButton.new()
	for m in ["UV", "World-planar (ground)", "Triplanar"]:
		mapping.add_item(m)
	add_row.call("Mapping", mapping)
	var name_edit := LineEdit.new()
	add_row.call("Name", name_edit)
	var dir_edit := LineEdit.new()
	var selected := EditorInterface.get_selected_paths()
	dir_edit.text = "res://gads_procedural"
	if not selected.is_empty():
		dir_edit.text = selected[0] if DirAccess.dir_exists_absolute(selected[0]) else selected[0].get_base_dir()
	add_row.call("Folder", dir_edit)
	# The kind's defaults; the depth follows the tile size.
	var apply_kind := func(index: int) -> void:
		var preset: Dictionary = GADSProcedural.PRESETS[kinds[index]]
		scale.value = float((preset["params"] as Dictionary).get("scale", 4))
		depth.value = snappedf(float(preset["depth_m"]) * tile.value * 100.0, 0.1)
		name_edit.text = kinds[index]
	kind.item_selected.connect(apply_kind)
	tile.value_changed.connect(func(_v: float) -> void: apply_kind.call(kind.selected))
	apply_kind.call(0)
	dialog.confirmed.connect(func() -> void:
		var options := {
			"size": [256, 512, 1024, 2048][size.selected],
			"params": {"seed": int(seed_spin.value), "scale": scale.value},
			"tile_m": Vector2(tile.value, tile.value),
			"depth_m": depth.value / 100.0,
			"mapping": mapping.selected,
		}
		var file_name := name_edit.text.strip_edges().validate_filename()
		generate_procedural_material(kinds[kind.selected], dir_edit.text.strip_edges(), file_name if not file_name.is_empty() else kinds[kind.selected], options)
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered(Vector2i(420, 0))


## Writes the maps of a procedural [param kind] into [param dir] as "<name>_height.exr",
## "_normal.png", "_albedo.png" and "_orm.png" (GADSProcedural.write_texture_set with
## [param options]), imports them and saves the GADS material "<name>_gads.tres" there. Returns
## its path ("" on failure).
func generate_procedural_material(kind: String, dir: String, name: String, options := {}) -> String:
	var fs := EditorInterface.get_resource_filesystem()
	var written := GADSProcedural.write_texture_set(kind, dir, name, options)
	if written.is_empty():
		return ""
	await import_files(PackedStringArray(written.values()))
	var tile: Vector2 = options.get("tile_m", Vector2.ONE)
	var mapping: int = options.get("mapping", GADSMaterials.Mapping.UV)
	var path := dir.path_join("%s_gads.tres" % name)
	var material := GADSTextureSet.create_material(written, {"height_m": GADSProcedural.depth_of(kind, options), "texture_size_m": tile}, mapping,
		GADSMaterials.Quality.POM_SELF_SHADOW, path)
	if material == null or not FileAccess.file_exists(path):
		return ""
	fs.update_file(path)
	print("GADS: generated %s (%s, %d px)" % [path, kind, int(options.get("size", 512))])
	EditorInterface.select_file(path)
	return path


## Imports [param paths] (files just written or changed) and returns once each one is imported:
## registered and re-imported at once in folders the editor knows, found by a scan (which imports
## them) in folders it does not. First waits for any scan or import the editor is running (an
## import cannot start inside another), and never starts one from inside a signal.
func import_files(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var fs := EditorInterface.get_resource_filesystem()
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	for i in 1200:
		if not fs.is_scanning() and not fs.is_importing():
			break
		await tree.process_frame
	var known := PackedStringArray()
	var unknown := PackedStringArray()
	for path in paths:
		if fs.get_filesystem_path(path.get_base_dir()) != null:
			known.append(path)
		else:
			unknown.append(path)
	if not known.is_empty():
		# Registered and imported in the same frame (the editor would otherwise start importing
		# the new files itself in between).
		for path in known:
			fs.update_file(path)
		fs.reimport_files(known)
	if not unknown.is_empty():
		# A scan registers the folders and imports their files; one that finds the editor busy
		# importing something else may leave them, so scan again (up to three times) until all are.
		var scans := 0
		var next_scan := 0
		for i in 1800:
			if not fs.is_scanning() and not fs.is_importing():
				var left := 0
				for path in unknown:
					left += 0 if is_imported(path) else 1
				if left == 0:
					break
				if i >= next_scan and scans < 3:
					fs.scan()
					scans += 1
					next_scan = i + 120
			await tree.process_frame


## Whether the editor has imported [param path] (its .import file lists the imported files and
## they exist).
static func is_imported(path: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path + ".import") != OK:
		return false
	var dest: Array = cfg.get_value("deps", "dest_files", [])
	for d: String in dest:
		if not FileAccess.file_exists(d):
			return false
	return not dest.is_empty()


func _handles(object: Object) -> bool:
	return object is GADSMeshInstance3D


## The Sculpt tool (switched on in a GADSMeshInstance3D's inspector): left-drag in the 3D viewport
## paints the node's sculpt map; the stroke is one undoable action and bakes again when it ends.
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	var node := GADSSculpt.tool_node
	if node == null or not is_instance_valid(node) or not node.is_inside_tree() or not GADSSculpt.tool_active:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			if sculpt_at(node, camera.project_ray_origin(button.position), camera.project_ray_normal(button.position)):
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		if _stroke_node != null:
			end_sculpt_stroke()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	var motion := event as InputEventMouseMotion
	if motion != null and _stroke_node != null and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		sculpt_at(node, camera.project_ray_origin(motion.position), camera.project_ray_normal(motion.position))
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


## One dab of the Sculpt tool's brush where the world ray from [param origin] along
## [param direction] meets [param node]'s mesh (starting a stroke if none is in progress). Returns
## whether it hit.
func sculpt_at(node: GADSMeshInstance3D, origin: Vector3, direction: Vector3) -> bool:
	var to_local := node.global_transform.affine_inverse()
	var hit := GADSSculpt.pick(node.mesh, to_local * origin, (to_local.basis * direction).normalized(), _pick_cache)
	if hit.is_empty():
		return false
	if _stroke_node == null:
		_stroke_node = node
		_stroke_before = node.get_sculpt_image().duplicate() if node.sculpt_map != null else null
	# The brush radius is in metres: in uv units through the hit triangle's texel density (and the
	# node's scale).
	var scale := node.global_transform.basis.get_scale()
	var radius_uv := GADSSculpt.tool_radius / maxf((scale.x + scale.y + scale.z) / 3.0, 1e-6) * float(hit["uv_per_m"])
	var amount := GADSSculpt.tool_strength if GADSSculpt.tool_mode in [GADSSculpt.Mode.RAISE, GADSSculpt.Mode.LOWER] else 0.25
	GADSSculpt.dab(node.get_sculpt_image(), hit["uv"], radius_uv, GADSSculpt.tool_mode, amount)
	return true


## Ends the stroke in progress: one undoable action, and the node bakes again.
func end_sculpt_stroke() -> void:
	if _stroke_node == null or not is_instance_valid(_stroke_node):
		_stroke_node = null
		_stroke_before = null
		return
	var node := _stroke_node
	var after := node.get_sculpt_image().duplicate() as Image
	var undo := get_undo_redo()
	undo.create_action("GADS Sculpt", UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(node, "set_sculpt_image", after)
	undo.add_undo_method(node, "set_sculpt_image", _stroke_before)
	_stroke_before = null
	_stroke_node = null
	undo.commit_action()


func validate() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("GADS: open a scene first.")
		return
	GADSValidator.print_report(GADSValidator.validate(root))
