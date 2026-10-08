class_name GADSImpact
extends RefCounted
## One call that dents whatever the relief is on, for impacts, explosions and damage: the runtime
## deformation ([GADSDeformationField]) where it covers the point (it recovers, as footprints do),
## else a [GADSTerrain3D]'s heights, or a [GADSMeshInstance3D]'s sculpt map, which bakes again in
## the background (a prop shows its dent once that bake is done).
## [codeblock]
## # A projectile from `from` along `dir` hits something:
## var hit := GADSImpact.dent_ray(get_world_3d(), from, dir, 0.4, 0.08)
## if hit["kind"] != "":
##     spawn_debris(hit["position"])
## [/codeblock]

## Dents [param target] (a GADSTerrain3D, a GADSMeshInstance3D, or any node standing on ground the
## deformation field covers) where the ray from [param origin] along [param direction] (world)
## meets it: a bowl [param radius] wide and [param depth] deep (m). With [param permanent] a
## terrain's heights change even where the deformation field covers the point. Returns
## {"kind": "deformation" | "terrain" | "mesh" | "", "position": the hit (or Vector3.INF), "node"}.
static func dent_node(target: Node, origin: Vector3, direction: Vector3, radius: float, depth: float, permanent := false) -> Dictionary:
	var none := {"kind": "", "position": Vector3.INF, "node": null}
	if target == null or not target.is_inside_tree() or radius <= 0.0 or direction.is_zero_approx():
		return none
	var dir := direction.normalized()
	if target is GADSMeshInstance3D:
		return _dent_mesh(target as GADSMeshInstance3D, origin, dir, radius, depth)
	var hit := Vector3.INF
	if target is GADSTerrain3D:
		hit = (target as GADSTerrain3D).intersect_ray(origin, dir)
	elif target is Node3D:
		# Something standing on ground: its position along the ray.
		var t := (target as Node3D).global_position
		hit = origin + dir * maxf(dir.dot(t - origin), 0.0)
	if not hit.is_finite():
		return none
	var field := GADSDeformationField.find_active(target.get_tree())
	if field != null and not (permanent and target is GADSTerrain3D) and field.get_window_rect().has_point(Vector2(hit.x, hit.z)):
		field.stamp(hit, radius, depth)
		return {"kind": "deformation", "position": hit, "node": field}
	if target is GADSTerrain3D:
		(target as GADSTerrain3D).sculpt(hit, radius, GADSSculpt.Mode.LOWER, depth)
		return {"kind": "terrain", "position": hit, "node": target}
	return none


## [method dent_node] on whatever the physics ray from [param origin] along [param direction]
## (at most [param max_distance] m) hits in [param world]: the GADSTerrain3D or GADSMeshInstance3D
## owning the collider (a baked mesh needs its collision on), else the ground under the deformation
## field at the hit.
static func dent_ray(world: World3D, origin: Vector3, direction: Vector3, radius: float, depth: float, permanent := false,
		max_distance := 1000.0) -> Dictionary:
	var none := {"kind": "", "position": Vector3.INF, "node": null}
	if world == null or direction.is_zero_approx():
		return none
	var dir := direction.normalized()
	var hit := world.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin, origin + dir * max_distance))
	if hit.is_empty():
		return none
	var node := hit["collider"] as Node
	while node != null and not (node is GADSTerrain3D or node is GADSMeshInstance3D):
		node = node.get_parent()
	if node != null:
		return dent_node(node, origin, dir, radius, depth, permanent)
	var p: Vector3 = hit["position"]
	var collider := hit["collider"] as Node
	var field := GADSDeformationField.find_active(collider.get_tree()) if collider != null else null
	if field != null and field.get_window_rect().has_point(Vector2(p.x, p.z)):
		field.stamp(p, radius, depth)
		return {"kind": "deformation", "position": p, "node": field}
	return none


static func _dent_mesh(node: GADSMeshInstance3D, origin: Vector3, dir: Vector3, radius: float, depth: float) -> Dictionary:
	var to_local := node.global_transform.affine_inverse()
	var shown := node.mesh if node.mesh != null else node.source_mesh
	var at := GADSSculpt.pick(shown, to_local * origin, (to_local.basis * dir).normalized())
	if at.is_empty():
		return {"kind": "", "position": Vector3.INF, "node": null}
	var scale := node.global_transform.basis.get_scale()
	var radius_uv := radius / maxf((scale.x + scale.y + scale.z) / 3.0, 1e-6) * float(at["uv_per_m"])
	GADSSculpt.dab(node.get_sculpt_image(), at["uv"], radius_uv, GADSSculpt.Mode.LOWER, depth)
	node.sculpt_changed()
	return {"kind": "mesh", "position": node.global_transform * (at["position"] as Vector3), "node": node}
