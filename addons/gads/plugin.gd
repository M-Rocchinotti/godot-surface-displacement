@tool
extends EditorPlugin
## GADS editor integration: registers the shader globals the materials read and
## adds Project > Tools entries: add the GADSManager node, add a GADSDisplacementField3D for
## the selected ground, convert materials (undoable), turn selected meshes into
## GADSMeshInstance3D and bake them (undoable), bake the ground of the selected field, prepare
## height maps selected in the FileSystem dock, create materials from texture sets selected
## there, and validate the setup. GADSMeshInstance3D gets
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
const MENUS: Array[String] = [MENU_ADD_NODE, MENU_ADD_FIELD, MENU_CONVERT, MENU_MESH_CONVERT, MENU_MESH_BAKE, MENU_BAKE,
	MENU_HEIGHT, MENU_TEXTURE_SET, MENU_VALIDATE]
const MeshInspector := preload("res://addons/gads/editor/gads_mesh_inspector.gd")
const ProfilerPanel := preload("res://addons/gads/editor/gads_profiler_panel.gd")
const ImportPlugin := preload("res://addons/gads/editor/gads_import_plugin.gd")

var _mesh_inspector: EditorInspectorPlugin
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
	var unknown_dir := false
	for s: Dictionary in sets:
		uses.append(GADSTextureSet.prepare(s))
		unknown_dir = unknown_dir or fs.get_filesystem_path(String(s["dir"])) == null
	# Files in a folder the editor has not scanned yet cannot be imported one by one: scan it (that
	# imports them too).
	if unknown_dir:
		while fs.is_scanning():
			await fs.filesystem_changed
		fs.scan()
		await fs.filesystem_changed
		while fs.is_scanning():
			await get_tree().process_frame
	for i in sets.size():
		var s: Dictionary = sets[i]
		var o: Dictionary = options[i] if i < options.size() else {}
		var use: Dictionary = uses[i]
		# Import what is new: the written files and source files the editor has not imported yet.
		var pending := PackedStringArray()
		for path: String in use.values():
			# The written files (*_gads_*) import afresh even when an older version was imported
			# (a scan has just imported them all).
			if (path.get_file().contains("_gads_") and not unknown_dir) or not ResourceLoader.exists(path):
				fs.update_file(path)
				pending.append(path)
		if not pending.is_empty():
			fs.reimport_files(pending)
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


func validate() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("GADS: open a scene first.")
		return
	GADSValidator.print_report(GADSValidator.validate(root))
