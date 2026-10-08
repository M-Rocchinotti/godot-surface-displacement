@tool
class_name GADSProfile
extends Resource
## A named set of displacement settings for a kind of asset, applied in one go: on import (the
## scene import option "GADS > Profile", or per mesh by name: [code]Rock-gads-rock[/code]), from
## scripts ([method apply]) or saved as a .tres of your own. Built in ([method builtin]):
## [br]- [b]prop[/b]: the defaults (Medium, LODs).
## [br]- [b]rock[/b]: High quality, rounded from low-poly sources ([member smooth_shape]), trimesh
## collision of the relief.
## [br]- [b]wall[/b]: modular kit pieces: borders locked so neighbouring pieces still meet (seam
## protection), sharp edges kept.
## [br]- [b]terrain[/b]: ground pieces: borders locked, displaced along +Y, trimesh collision.
## [br]- [b]character[/b]: skinned or deforming surfaces: not baked, the GADS material's
## parallax only (the node stays a MeshInstance3D).

## The GADS material to give the mesh (its material override); null keeps the mesh's own.
@export var material: Material
## Whether the mesh becomes a GADSMeshInstance3D at all (false: it keeps drawing its material,
## parallax only).
@export var geometry := true
## Bake it (on import: during the import; needs a GADS material with a height map).
@export var bake := true
@export var quality := GADSMeshInstance3D.Quality.MEDIUM
@export var lock_borders := false
@export_range(0.0, 1.0, 0.05) var smooth_shape := 0.0
@export_range(0.0, 180.0, 0.1, "degrees") var hard_angle := 30.0
@export var direction := GADSMeshInstance3D.Direction.AUTO
@export var generate_lods := true
@export var collision := GADSMeshBaker.Collision.NONE
@export_range(0, 1000000, 1000, "or_greater") var cluster_triangles := 0
@export var stream_bake := false
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var geometry_range := 0.0

## The built-in profiles' ids, in menu order.
const BUILTIN_IDS: PackedStringArray = ["prop", "rock", "wall", "terrain", "character"]


## A new copy of the built-in profile [param id] (see the class description), or null.
static func builtin(id: String) -> GADSProfile:
	var p := GADSProfile.new()
	match id.to_lower():
		"prop":
			pass
		"rock":
			p.quality = GADSMeshInstance3D.Quality.HIGH
			p.smooth_shape = 0.5
			p.collision = GADSMeshBaker.Collision.TRIMESH
		"wall":
			p.lock_borders = true
			p.hard_angle = 20.0
		"terrain":
			p.lock_borders = true
			p.direction = GADSMeshInstance3D.Direction.AXIS
			p.collision = GADSMeshBaker.Collision.TRIMESH
		"character":
			p.geometry = false
			p.bake = false
		_:
			return null
	p.resource_name = id.to_lower()
	return p


## Gives [param node] this profile's settings (and [member material] when set).
func apply(node: GADSMeshInstance3D) -> void:
	var values := settings()
	for key: String in values:
		node.set(key, values[key])


## The GADSMeshInstance3D properties this profile sets, with their values (what [method apply]
## and the inspector's Profile menu, undoably, set).
func settings() -> Dictionary:
	var out := {
		"quality": quality, "lock_borders": lock_borders, "smooth_shape": smooth_shape, "hard_angle": hard_angle,
		"direction": direction, "generate_lods": generate_lods, "collision": collision,
		"cluster_triangles": cluster_triangles, "stream_bake": stream_bake, "geometry_range": geometry_range,
	}
	if direction == GADSMeshInstance3D.Direction.AXIS:
		out["direction_axis"] = Vector3.UP
	if material != null:
		out["material_override"] = material
	return out
