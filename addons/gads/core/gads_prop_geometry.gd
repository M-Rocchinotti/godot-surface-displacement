class_name GADSPropGeometry
extends RefCounted
## Real geometry near the camera for props that only have parallax: the MeshInstance3D nodes
## nearest the camera that draw a UV-mapped or triplanar GADS material with relief get a runtime,
## view-dependent tessellation (an internal GADSMeshInstance3D drawing in their place) while the
## camera is within range; further away the parallax shows again. GADSManager runs it
## ([member GADSManager.prop_geometry]); nothing is baked or saved.
##
## Not for: GADSMeshInstance3D nodes (they bake or tessellate themselves), world-planar materials
## (ground: the near-camera field's job), skinned meshes, meshes in the group
## [code]gads_no_prop_geometry[/code], and the editor.

const OPT_OUT_GROUP := &"gads_no_prop_geometry"
## Range factor before a prop goes back to parallax (so a camera on the boundary does not flip it).
const RELEASE_FACTOR := 1.25

var range_m := 6.0
var max_props := 4
var pixel_error := 1.0

var _candidates := {} # instance id -> WeakRef(MeshInstance3D)
var _active := {} # instance id -> {"node": WeakRef(MeshInstance3D), "proxy": GADSMeshInstance3D, "ready": bool}


## Whether [param mi] can get prop geometry: a visible MeshInstance3D (not a GADSMeshInstance3D or
## one of its internal children, not skinned, not opted out) with a triangle mesh drawing at least
## one UV-mapped or triplanar GADS material with relief.
static func is_candidate(mi: MeshInstance3D) -> bool:
	if mi == null or mi is GADSMeshInstance3D or mi.get_parent() is GADSMeshInstance3D or mi.mesh == null:
		return false
	if mi.is_in_group(OPT_OUT_GROUP) or mi.skin != null:
		return false
	if mi.mesh is ArrayMesh and mi.mesh.get_surface_count() > 0 and ((mi.mesh as ArrayMesh).surface_get_format(0) & Mesh.ARRAY_FORMAT_BONES) != 0:
		return false
	if not GADSMeshBaker.check_mesh(mi.mesh).is_empty():
		return false
	var relief := false
	for m in GADSMeshBaker.resolve_materials(mi, mi.mesh):
		if not GADSMaterials.is_gads_material(m):
			continue
		var info := GADSMaterials.parse((m as ShaderMaterial).shader)
		if info["mapping"] == GADSMaterials.Mapping.WORLD:
			return false
		var d := GADSMeshBaker.displacement_of(m)
		if not d.is_empty() and float(d["height_m"]) > 0.0:
			relief = true
	return relief


## Remembers [param mi] if it is a candidate (GADSManager calls this for every node it registers).
func consider(mi: MeshInstance3D) -> void:
	if is_candidate(mi):
		_candidates[mi.get_instance_id()] = weakref(mi)


## The nodes that draw with prop geometry now (their tessellation is ready).
func get_nodes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for entry: Dictionary in _active.values():
		var mi := (entry["node"] as WeakRef).get_ref() as MeshInstance3D
		if mi != null and entry["ready"]:
			out.append(mi)
	return out


## The internal node that tessellates [param mi] (null when it has none).
func get_proxy(mi: MeshInstance3D) -> GADSMeshInstance3D:
	var entry: Dictionary = _active.get(mi.get_instance_id(), {})
	return entry.get("proxy")


## Picks the props within range of [param camera] (the nearest [member max_props]), starts their
## tessellation and lets the others go back to parallax.
func update(camera: Camera3D) -> void:
	if camera == null or not GADSMeshBaker.is_available():
		release_all()
		return
	var eye := camera.global_position
	var near := []
	for id: int in _candidates.keys():
		var mi := (_candidates[id] as WeakRef).get_ref() as MeshInstance3D
		if mi == null or not mi.is_inside_tree():
			_candidates.erase(id)
			continue
		if not mi.is_visible_in_tree():
			continue
		var aabb := mi.global_transform * mi.mesh.get_aabb()
		var d := eye.distance_to(eye.clamp(aabb.position, aabb.end))
		var limit := range_m * (RELEASE_FACTOR if _active.has(id) else 1.0)
		if d <= limit:
			near.append([d, id, mi])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var wanted := {}
	for i in mini(near.size(), max_props):
		wanted[near[i][1]] = near[i][2]
	for id: int in _active.keys():
		if not wanted.has(id):
			_release(id)
	for id: int in wanted:
		var mi: MeshInstance3D = wanted[id]
		if not _active.has(id):
			_start(mi)
		else:
			var entry: Dictionary = _active[id]
			(entry["proxy"] as GADSMeshInstance3D).pixel_error = pixel_error
			if entry["ready"]:
				# The node may have been shown again (its visibility toggled): keep it hidden.
				RenderingServer.instance_set_visible(mi.get_instance(), false)


## Lets every prop go back to parallax.
func release_all() -> void:
	for id: int in _active.keys():
		_release(id)


func _start(mi: MeshInstance3D) -> void:
	var proxy := GADSMeshInstance3D.new()
	proxy.name = "GADSPropGeometry"
	proxy.source_mesh = mi.mesh
	proxy.material_override = mi.material_override
	proxy.material_overlay = mi.material_overlay
	for s in mi.get_surface_override_material_count():
		proxy.set_surface_override_material(s, mi.get_surface_override_material(s))
	proxy.cast_shadow = mi.cast_shadow
	proxy.layers = mi.layers
	proxy.gi_mode = mi.gi_mode
	GADSMaterials.copy_variation(mi, proxy)
	proxy.pixel_error = pixel_error
	proxy.view_dependent = true
	# Hidden until its first tessellation is ready: the node keeps drawing its parallax meanwhile.
	proxy.visible = false
	var id := mi.get_instance_id()
	_active[id] = {"node": weakref(mi), "proxy": proxy, "ready": false}
	proxy.view_tessellated.connect(_on_ready.bind(id), CONNECT_ONE_SHOT)
	mi.add_child(proxy, false, Node.INTERNAL_MODE_BACK)


func _on_ready(_stats: Dictionary, id: int) -> void:
	var entry: Dictionary = _active.get(id, {})
	if entry.is_empty():
		return
	var mi := (entry["node"] as WeakRef).get_ref() as MeshInstance3D
	if mi == null:
		return
	entry["ready"] = true
	(entry["proxy"] as GADSMeshInstance3D).visible = true
	RenderingServer.instance_set_visible(mi.get_instance(), false)


func _release(id: int) -> void:
	var entry: Dictionary = _active.get(id, {})
	_active.erase(id)
	if entry.is_empty():
		return
	var proxy: GADSMeshInstance3D = entry["proxy"]
	if is_instance_valid(proxy):
		proxy.queue_free()
	var mi := (entry["node"] as WeakRef).get_ref() as MeshInstance3D
	if mi != null and mi.is_inside_tree():
		RenderingServer.instance_set_visible(mi.get_instance(), mi.is_visible_in_tree())
