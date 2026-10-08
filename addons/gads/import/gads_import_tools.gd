@tool
class_name GADSImportTools
extends RefCounted
## What the GADS scene import options do to an imported scene (the editor plugin's
## EditorScenePostImportPlugin calls [method process] with the options of the Advanced Import
## Settings; scripts can call it on any scene):
##
## - [code]convert_materials[/code]: BaseMaterial3D materials with a height map become GADS
##   materials ([GADSMaterialConverter], [code]metres_per_repeat[/code] sets the relief depth).
## - [code]meshes[/code] ([enum Meshes]): which MeshInstance3D nodes become [GADSMeshInstance3D]:
##   those whose name ends in [code]-gads[/code] (the suffix is removed, like Godot's
##   [code]-col[/code] hints), or every one drawing a GADS material.
## - [code]bake[/code]: bake them during the import with [code]quality[/code]; the baked meshes are
##   stored in the imported scene (no cache files), so they are ready when the scene is
##   instanced. Needs the native library; without it the nodes stay unbaked.

enum Meshes { NONE, SUFFIX, ALL_GADS }

const SUFFIX := "-gads"
const DEFAULTS := {
	"convert_materials": false,
	"metres_per_repeat": 1.0,
	"meshes": Meshes.SUFFIX,
	"bake": true,
	"quality": GADSMeshInstance3D.Quality.MEDIUM,
}


## Applies [param options] (see the class description; missing keys take [constant DEFAULTS]) to
## the scene under [param root]. Returns {"converted": materials converted, "meshes":
## GADSMeshInstance3D nodes made, "baked": how many of them were baked, "skipped": [reasons]}.
static func process(root: Node, options := {}) -> Dictionary:
	var o := DEFAULTS.duplicate()
	o.merge(options, true)
	var report := {"converted": 0, "meshes": 0, "baked": 0, "skipped": []}
	if o["convert_materials"]:
		var roots: Array[Node] = [root]
		var planned := GADSMaterialConverter.plan(roots, o["metres_per_repeat"])
		GADSMaterialConverter.apply(planned)
		report["converted"] = planned["converted"]
		for s: Dictionary in planned["skipped"]:
			if s["reason"] != "no height map (nothing to displace)":
				(report["skipped"] as Array).append("%s: %s" % [s["node"].name, s["reason"]])
	if o["meshes"] == Meshes.NONE:
		return report
	var candidates: Array[MeshInstance3D] = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node is GADSMeshInstance3D:
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var wanted := String(mi.name).to_lower().ends_with(SUFFIX) if o["meshes"] == Meshes.SUFFIX else _draws_gads(mi)
		if wanted:
			candidates.append(mi)
	if root is MeshInstance3D and not (root is GADSMeshInstance3D):
		(report["skipped"] as Array).append("%s: the scene's root stays as it is" % root.name)
	for mi in candidates:
		var node := _replace(mi, root)
		report["meshes"] += 1
		if o["bake"]:
			if _bake(node, root, o["quality"], report):
				report["baked"] += 1
	return report


static func _draws_gads(mi: MeshInstance3D) -> bool:
	for m in GADSMeshBaker.resolve_materials(mi, mi.mesh):
		if GADSMaterials.is_gads_material(m):
			return true
	return false


## A GADSMeshInstance3D in place of [param mi] (name without the suffix, same transform,
## materials, settings and children).
static func _replace(mi: MeshInstance3D, root: Node) -> GADSMeshInstance3D:
	var node := GADSMeshInstance3D.new()
	var base := String(mi.name)
	if base.to_lower().ends_with(SUFFIX):
		base = base.left(base.length() - SUFFIX.length())
	node.source_mesh = mi.mesh
	node.transform = mi.transform
	node.visible = mi.visible
	node.material_override = mi.material_override
	node.material_overlay = mi.material_overlay
	node.cast_shadow = mi.cast_shadow
	node.layers = mi.layers
	node.skeleton = mi.skeleton
	for s in mi.get_surface_override_material_count():
		node.set_surface_override_material(s, mi.get_surface_override_material(s))
	var parent := mi.get_parent()
	var index := mi.get_index()
	parent.remove_child(mi)
	node.name = base
	parent.add_child(node)
	parent.move_child(node, index)
	node.owner = root
	for child in mi.get_children():
		mi.remove_child(child)
		node.add_child(child)
		_set_owner(child, root)
	mi.free()
	return node


static func _set_owner(node: Node, root: Node) -> void:
	node.owner = root
	for child in node.get_children():
		_set_owner(child, root)


## The node's transform relative to [param root] (the imported scene is not in the tree).
static func _relative_transform(node: Node3D, root: Node) -> Transform3D:
	var xform := node.transform
	var p := node.get_parent()
	while p != null and p != root:
		if p is Node3D:
			xform = (p as Node3D).transform * xform
		p = p.get_parent()
	if root is Node3D:
		xform = (root as Node3D).transform * xform
	return xform


static func _bake(node: GADSMeshInstance3D, root: Node, quality: int, report: Dictionary) -> bool:
	node.quality = quality
	if node.get_relief_depth() <= 0.0:
		(report["skipped"] as Array).append("%s: no GADS material with a height map; not baked" % node.name)
		return false
	var materials := GADSMeshBaker.resolve_materials(node, node.source_mesh)
	var xform := _relative_transform(node, root)
	var settings := node.get_bake_settings()
	var baker := GADSMeshBaker.new()
	baker.setup(node.source_mesh, materials, xform, settings)
	if not baker.run():
		(report["skipped"] as Array).append("%s: bake failed: %s" % [node.name, baker.error])
		return false
	var stats := baker.stats.duplicate()
	stats["path"] = "embedded in the imported scene"
	node.set_bake_state({"baked": true, "mesh": baker.mesh, "bake_key": GADSMeshBaker.cache_key(node.source_mesh, materials, xform, settings),
		"bake_stats": stats, "collision_shape": baker.collision_shape})
	return true
