@tool
extends EditorPlugin
## GADS editor integration: registers the shader globals the materials read and
## adds Project > Tools entries: add the GADSManager node, add a GADSDisplacementField3D for
## the selected ground, convert materials (undoable), bake the ground of the selected field,
## prepare height maps selected in the FileSystem dock, and validate the setup.

const MENU_ADD_NODE := "GADS: Add GADSManager Node"
const MENU_ADD_FIELD := "GADS: Add GADSDisplacementField3D for Selected Ground"
const MENU_CONVERT := "GADS: Convert Materials (Selected)"
const MENU_BAKE := "GADS: Bake Ground of Selected Field"
const MENU_HEIGHT := "GADS: Prepare Height Maps (FileSystem Selection)"
const MENU_VALIDATE := "GADS: Validate Setup"
const MENUS: Array[String] = [MENU_ADD_NODE, MENU_ADD_FIELD, MENU_CONVERT, MENU_BAKE, MENU_HEIGHT, MENU_VALIDATE]


func _enable_plugin() -> void:
	GADSGlobals.ensure_registered(true)


func _enter_tree() -> void:
	GADSGlobals.ensure_registered(true)
	add_tool_menu_item(MENU_ADD_NODE, add_manager_node)
	add_tool_menu_item(MENU_ADD_FIELD, add_field_for_selection)
	add_tool_menu_item(MENU_CONVERT, convert_selection)
	add_tool_menu_item(MENU_BAKE, bake_selected_field)
	add_tool_menu_item(MENU_HEIGHT, prepare_selected_height_maps)
	add_tool_menu_item(MENU_VALIDATE, validate)


func _exit_tree() -> void:
	for item in MENUS:
		remove_tool_menu_item(item)


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


func validate() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("GADS: open a scene first.")
		return
	GADSValidator.print_report(GADSValidator.validate(root))
