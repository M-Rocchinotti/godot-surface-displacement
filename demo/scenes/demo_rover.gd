extends Node3D
## The terrain demo's rover: drives a loop over the terrain, sits on its surface, leaves two
## continuous tracks in the scene's GADSDeformationField (its GADSDeformer3D children) and paints
## a trail of the terrain's third layer behind it (GADSTerrain3D.paint_layer()).

## The terrain it drives on (its get_height() places the rover and tells the deformers the ground).
var terrain: GADSTerrain3D
var center := Vector2.ZERO
var radius := 9.0
## Metres per second.
var speed := 2.5
## Paints the terrain's third layer this wide (m) every trail_step metres; 0: no trail.
var trail_width := 2.2
var trail_step := 0.6

var _angle := 0.0
var _last_paint := Vector3.INF


func _ready() -> void:
	for d in find_children("*", "GADSDeformer3D", true, false):
		(d as GADSDeformer3D).ground_height = func(p: Vector3) -> float: return _ground(p)
	_place()


func _physics_process(delta: float) -> void:
	_angle += speed * delta / radius
	_place()
	if trail_width > 0.0 and terrain != null and terrain.is_inside_tree() and global_position.distance_to(_last_paint) >= trail_step:
		_last_paint = global_position
		terrain.paint_layer(global_position, trail_width * 0.5, 2, 0.35, 0.6)


func _ground(p: Vector3) -> float:
	if terrain == null or not terrain.is_inside_tree():
		return 0.0
	var h := terrain.get_height(p)
	return 0.0 if is_nan(h) else h


func _place() -> void:
	var xz := center + Vector2(cos(_angle), sin(_angle)) * radius
	var ahead := center + Vector2(cos(_angle + 0.05), sin(_angle + 0.05)) * radius
	var p := Vector3(xz.x, 0.0, xz.y)
	p.y = _ground(p)
	var q := Vector3(ahead.x, 0.0, ahead.y)
	q.y = _ground(q)
	if p.is_equal_approx(q):
		return
	global_transform = Transform3D(Basis.looking_at(q - p, Vector3.UP), p)
