@tool
@icon("res://addons/gads/icons/gads_terrain_3d.svg")
class_name GADSReliefCollider3D
extends Node3D
## Collision on the relief around one character: a small height-field (HeightMapShape3D) that
## follows [member target] and samples the relief the ground draws there
## ([method GADSTerrain3D.get_surface_height] or [method GADSDisplacementField3D.get_surface_height]),
## so feet stand on the stones instead of sinking to the smooth ground collision. Its cost does not
## depend on the render triangles: [member resolution] x [member resolution] samples, of which only
## the new rows and columns are sampled as the target moves (a teleport samples all of them).
## Put it anywhere in the scene; it does nothing in the editor.
## [codeblock]
## var feet := GADSReliefCollider3D.new()
## feet.target = $Player.get_path()
## add_child(feet)
## [/codeblock]

## The node it follows (empty: the viewport's camera).
@export var target: NodePath
## What draws the relief: a GADSTerrain3D or GADSDisplacementField3D, or any node with
## get_surface_height(Vector3) (empty: the first GADSTerrain3D in the scene, else the first
## GADSDisplacementField3D).
@export var source: NodePath
## Samples along each side (the patch covers (resolution - 1) x spacing metres).
@export_range(3, 129, 1) var resolution := 33:
	set(value):
		resolution = value
		_reset()
## Metres between samples. Finer than the relief's features to stand on them (stones: 5-10 cm).
@export_range(0.01, 2.0, 0.01, "suffix:m") var spacing := 0.08:
	set(value):
		spacing = value
		_reset()
## Sample everything again this often (s; 0: only when the target moves), for relief that changes
## at runtime (deformation, sculpting). [method refresh] does it once.
@export_range(0.0, 10.0, 0.1, "suffix:s") var refresh_interval := 0.0
@export_flags_3d_physics var collision_layer := 1:
	set(value):
		collision_layer = value
		if _body != null:
			_body.collision_layer = value
@export_flags_3d_physics var collision_mask := 0:
	set(value):
		collision_mask = value
		if _body != null:
			_body.collision_mask = value

## Samples taken by the last update (for the profiler and tests).
var last_sampled := 0

var _body: StaticBody3D
var _shape_node: CollisionShape3D
var _shape: HeightMapShape3D
var _heights := PackedFloat32Array()
var _cell := Vector2i(1 << 30, 1 << 30)
var _source_node: Node
var _since_refresh := 0.0


func _ready() -> void:
	set_physics_process(not Engine.is_editor_hint())


func _exit_tree() -> void:
	_reset()


## Samples the whole patch again at the next physics frame.
func refresh() -> void:
	_cell = Vector2i(1 << 30, 1 << 30)


## The physics body carrying the shape (null before the first update).
func get_body() -> StaticBody3D:
	return _body


## World rectangle (XZ) the patch covers, or an empty one before the first update.
func get_rect() -> Rect2:
	if _heights.is_empty():
		return Rect2()
	var side := (resolution - 1) * spacing
	return Rect2(Vector2(_cell) * spacing, Vector2(side, side))


func _physics_process(delta: float) -> void:
	var t := _target_position()
	if not t.is_finite():
		return
	var src := _find_source()
	if src == null:
		return
	if refresh_interval > 0.0:
		_since_refresh += delta
		if _since_refresh >= refresh_interval:
			_since_refresh = 0.0
			refresh()
	# The patch's first sample, snapped to the spacing grid so samples keep their place.
	var half := (resolution - 1) / 2
	var cell := Vector2i(roundi(t.x / spacing) - half, roundi(t.z / spacing) - half)
	if cell != _cell:
		_update(src, cell)


func _update(src: Node, cell: Vector2i) -> void:
	var n := resolution
	var old := _heights
	var old_cell := _cell
	var reuse := old.size() == n * n and absi(cell.x - old_cell.x) < n and absi(cell.y - old_cell.y) < n
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var sampled := 0
	var lowest := INF
	for j in n:
		for i in n:
			var h := NAN
			if reuse:
				var oi := cell.x + i - old_cell.x
				var oj := cell.y + j - old_cell.y
				if oi >= 0 and oi < n and oj >= 0 and oj < n:
					h = old[oj * n + oi]
			if is_nan(h):
				h = float(src.call(&"get_surface_height", Vector3((cell.x + i) * spacing, 0.0, (cell.y + j) * spacing)))
				sampled += 1
			heights[j * n + i] = h
			if not is_nan(h):
				lowest = minf(lowest, h)
	last_sampled = sampled
	_cell = cell
	_heights = heights
	if lowest == INF:
		if _shape_node != null:
			_shape_node.disabled = true
		return
	_ensure_body()
	# Outside the relief's data: a metre below the lowest sample, out of the way of the ground's
	# own collision.
	var data := PackedFloat32Array()
	data.resize(n * n)
	for k in n * n:
		var h := heights[k]
		data[k] = (lowest - 1.0 if is_nan(h) else h) / spacing
	_shape.map_width = n
	_shape.map_depth = n
	_shape.map_data = data
	# A HeightMapShape3D is centred on its node with one unit between samples: a uniform scale
	# of the spacing (heights divided by it above) puts the samples in place.
	var centre := (Vector2(cell) + Vector2(n - 1, n - 1) * 0.5) * spacing
	_shape_node.transform = Transform3D(Basis.from_scale(Vector3(spacing, spacing, spacing)), Vector3(centre.x, 0.0, centre.y))
	_shape_node.disabled = false


func _ensure_body() -> void:
	if _body != null:
		return
	_body = StaticBody3D.new()
	_body.name = "ReliefBody"
	_body.top_level = true
	_body.collision_layer = collision_layer
	_body.collision_mask = collision_mask
	_shape_node = CollisionShape3D.new()
	_shape = HeightMapShape3D.new()
	_shape_node.shape = _shape
	_body.add_child(_shape_node)
	add_child(_body, false, Node.INTERNAL_MODE_BACK)
	_body.global_transform = Transform3D.IDENTITY


func _reset() -> void:
	_heights = PackedFloat32Array()
	_cell = Vector2i(1 << 30, 1 << 30)
	if _body != null:
		_body.queue_free()
		_body = null
		_shape_node = null
		_shape = null


func _target_position() -> Vector3:
	var node: Node3D = null
	if not target.is_empty():
		node = get_node_or_null(target) as Node3D
	elif get_viewport() != null:
		node = get_viewport().get_camera_3d()
	return node.global_position if node != null and node.is_inside_tree() else Vector3.INF


func _find_source() -> Node:
	if _source_node != null and is_instance_valid(_source_node) and _source_node.is_inside_tree():
		return _source_node
	_source_node = null
	if not source.is_empty():
		_source_node = get_node_or_null(source)
	else:
		var root := get_tree().root
		var found := root.find_children("*", "GADSTerrain3D", true, false)
		if found.is_empty():
			found = root.find_children("*", "GADSDisplacementField3D", true, false)
		if not found.is_empty():
			_source_node = found[0]
	if _source_node != null and not _source_node.has_method(&"get_surface_height"):
		_source_node = null
	return _source_node
