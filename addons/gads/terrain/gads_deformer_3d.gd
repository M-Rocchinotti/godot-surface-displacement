@tool
@icon("res://addons/gads/icons/gads_pebble_scatter_3d.svg")
class_name GADSDeformer3D
extends Node3D
## Leaves marks in the scene's [GADSDeformationField] while it moves: put one on each foot, wheel
## or sled runner. Every [member spacing] metres it presses a round mark, a track segment
## (wheels: [member continuous]) or [member image] (footprints, treads, turned to the direction of
## travel). [member active] (or [method set_contact]) says when it touches the ground; a deformer
## more than [member contact_height] above the ground under it leaves nothing.

@export var active := true
## Radius of a round mark, or half the width of a track (m).
@export_range(0.005, 5.0, 0.005, "or_greater", "suffix:m") var radius := 0.08
@export_range(0.0, 2.0, 0.001, "or_greater", "suffix:m") var depth := 0.04
## Ground pushed up around a round mark (m).
@export_range(0.0, 1.0, 0.001, "suffix:m") var rim := 0.0
## Distance between marks (m); 0 = a mark every frame it moves.
@export_range(0.0, 10.0, 0.01, "suffix:m") var spacing := 0.1
## A track joining each mark to the last instead of separate marks (wheels, runners).
@export var continuous := false
## A footprint or tread (red channel: 1 = full depth), [member image_size] metres, turned so its
## image "up" points along the direction of travel. Replaces the round mark.
@export var image: Texture2D
@export var image_size := Vector2(0.12, 0.28)
@export var combine := GADSDeformationField.Combine.DEEPEN
## Marks only while the deformer is at most this high above the ground (m), when
## [member ground_height] tells the ground's height (else it is always in contact).
@export_range(0.0, 2.0, 0.01, "suffix:m") var contact_height := 0.1
## Optional Callable(world_position: Vector3) -> float giving the ground height under the deformer.
var ground_height: Callable
## The field to write into; empty = the first GADSDeformationField in the scene tree.
@export var field: NodePath

var _last := Vector3.INF
var _contact := true


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not active:
		_last = Vector3.INF
		return
	var f := _find_field()
	if f == null:
		return
	var p := global_position
	var touching := _contact
	if ground_height.is_valid():
		touching = touching and p.y - float(ground_height.call(p)) <= contact_height
	if not touching:
		_last = Vector3.INF
		return
	if _last == Vector3.INF:
		_mark(f, p, p)
		_last = p
		return
	var moved := Vector2(p.x - _last.x, p.z - _last.z).length()
	if moved >= maxf(spacing, 1e-4):
		_mark(f, _last, p)
		_last = p


## For scripts that know when a foot is down (animation events, a raycast): marks are left only
## while [param touching].
func set_contact(touching: bool) -> void:
	_contact = touching
	if not touching:
		_last = Vector3.INF


func _mark(f: GADSDeformationField, from: Vector3, to: Vector3) -> void:
	if continuous and from != to:
		f.stroke(from, to, radius * 2.0, depth, combine)
	elif image != null:
		var dir := Vector2(to.x - from.x, to.z - from.z)
		var heading := atan2(dir.x, dir.y) if dir.length() > 1e-5 else -global_rotation.y
		f.stamp_image(to, image.get_image(), image_size, heading, depth, combine)
	else:
		f.stamp(to, radius, depth, rim, combine)


func _find_field() -> GADSDeformationField:
	if not field.is_empty():
		return get_node_or_null(field) as GADSDeformationField
	var found := get_tree().root.find_children("*", "GADSDeformationField", true, false)
	return found[0] as GADSDeformationField if not found.is_empty() else null
