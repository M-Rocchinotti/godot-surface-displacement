@tool
@icon("res://addons/gads/icons/gads_displacement_field_3d.svg")
class_name GADSDeformationField
extends Node3D
## Runtime deformation of the ground: footprints, tyre tracks, craters, ruts in snow, sand and mud.
## A depth map over a square window of the world (metres pressed down; negative = raised) that
## gameplay writes with [method stamp], [method stroke] and [method stamp_image] (or
## [GADSDeformer3D] nodes on feet and wheels), and that the GADS shaders read:
## [GADSDisplacementField3D] moves its geometry, world-planar materials and the tops of triplanar
## ones press their parallax relief down (by the depth under each pixel), UV-mapped ones as far as
## they face up. [method get_depth] gives the same depth to scripts (foot placement, physics).
##
## The window follows [member follow] (the player or camera) in whole texels; a mark keeps its
## place while it stays inside the window and is cleared once it leaves. Marks recover at
## [member recovery_rate] (snow filling in), computed in the shaders from each mark's time, so
## recovery costs nothing per frame. [method get_state] / [method set_state] and
## [method save_to] / [method load_from] keep deformation across sessions.
##
## One field drives the shader globals at a time (the last one that entered the tree).

enum Combine {
	DEEPEN, ## The deeper of what is there and the stamp (snow: stepping twice does not dig).
	ADD, ## Adds to what is there (digging, repeated impacts), clamped to max_depth.
	SET, ## Replaces what is there (a level patch, a repair).
}

## Side of the window (m).
@export_range(1.0, 2000.0, 0.5, "or_greater", "suffix:m") var size_m := 16.0:
	set(value):
		size_m = value
		_rebuild()
## Texels per side (texel = size_m / resolution: 3 cm at the defaults).
@export_range(64, 4096, 64) var resolution := 512:
	set(value):
		resolution = value
		_rebuild()
## The deepest deformation (m): stamps are clamped to it and the field's parallax slab reaches
## down to it.
@export_range(0.001, 10.0, 0.001, "or_greater", "suffix:m") var max_depth := 0.3
## Depth refilled per second (m/s); 0 = marks stay. Recovery counts from each mark's stamp time,
## so a rate set later applies to the time already passed too.
@export_range(0.0, 1.0, 0.0001, "or_greater", "suffix:m/s") var recovery_rate := 0.0
## The node the window centres on; empty = this node.
@export var follow: NodePath

var _data := PackedFloat32Array() # per texel: depth when stamped, stamp time
var _image: Image
var _texture: ImageTexture
var _dirty := false
var _time := 0.0
var _cell := Vector2i(1 << 30, 1 << 30) # world texel of the window's corner


func _enter_tree() -> void:
	_ensure_ready()
	_update_window()
	_upload()
	_publish()


func _exit_tree() -> void:
	if GADSGlobals.get_value(GADSGlobals.DEFORM_PARAMS) is Vector4 and _owns_globals():
		GADSGlobals.set_value(GADSGlobals.DEFORM_PARAMS, Vector4(0, 0, 1, 0))


func _process(delta: float) -> void:
	_time += delta
	_update_window()
	if _dirty:
		_upload()
	_publish()


## Metres per texel.
func get_texel_size() -> float:
	return size_m / resolution


## The window: Rect2 of world XZ it covers now.
func get_window_rect() -> Rect2:
	var t := get_texel_size()
	return Rect2(Vector2(_cell) * t, Vector2(size_m, size_m))


## The field's clock (s), the time marks are stamped with.
func get_time() -> float:
	return _time


## The texture the shaders read (r = depth when stamped, g = stamp time).
func get_texture() -> ImageTexture:
	return _texture


## Presses a round mark at [param world_position] (its XZ): [param depth] metres in the middle,
## smoothly to 0 at [param radius]; with [param rim] metres of ground pushed up around it (out to
## 1.5 x radius), as soil around a crater or snow around a step.
func stamp(world_position: Vector3, radius: float, depth: float, rim := 0.0, combine := Combine.DEEPEN) -> void:
	var reach := radius * (1.5 if rim != 0.0 else 1.0)
	_paint(Vector2(world_position.x, world_position.z), reach, combine, func(p: Vector2) -> float:
		var r := p.length() / maxf(radius, 1e-6)
		if r < 1.0:
			return depth * (1.0 - smoothstep(0.55, 1.0, r))
		if rim != 0.0 and r < 1.5:
			return -rim * sin((r - 1.0) / 0.5 * PI)
		return INF)


## Presses a track from [param from] to [param to]: [param width] wide, [param depth] deep in its
## middle, with rounded ends (tyre tracks, dragged objects).
func stroke(from: Vector3, to: Vector3, width: float, depth: float, combine := Combine.DEEPEN) -> void:
	var a := Vector2(from.x, from.z)
	var b := Vector2(to.x, to.z)
	var half := width * 0.5
	var center := (a + b) * 0.5
	_paint(center, (b - a).length() * 0.5 + half, combine, func(p: Vector2) -> float:
		var q := center + p
		var ab := b - a
		var t := clampf((q - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
		var r := q.distance_to(a + ab * t) / maxf(half, 1e-6)
		return depth * (1.0 - smoothstep(0.55, 1.0, r)) if r < 1.0 else INF)


## Presses the shape of [param image] (red channel: 1 = full [param depth], 0 = untouched) at
## [param world_position], [param size] metres wide and long, its top row pointing along the
## heading [param rotation] (radians from +Z towards +X): footprints, tyre treads.
func stamp_image(world_position: Vector3, image: Image, size: Vector2, rotation: float, depth: float, combine := Combine.DEEPEN) -> void:
	var img := image.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RF)
	var w := img.get_width()
	var h := img.get_height()
	var c := cos(rotation)
	var s := sin(rotation)
	_paint(Vector2(world_position.x, world_position.z), size.length() * 0.5, combine, func(p: Vector2) -> float:
		# Into the image's frame: x across, y along the heading (rotation 0 = +Z); the image's top
		# row is the front.
		var q := Vector2(c * p.x - s * p.y, s * p.x + c * p.y)
		var u := q.x / size.x + 0.5
		var v := 0.5 - q.y / size.y
		if u < 0.0 or v < 0.0 or u >= 1.0 or v >= 1.0:
			return INF
		var value := img.get_pixel(clampi(int(u * w), 0, w - 1), clampi(int(v * h), 0, h - 1)).r
		return depth * value if value > 0.0 else INF)


## How far the ground is pressed down at [param world_position] (m, negative = raised), as the
## shaders see it (bilinear, recovery applied).
func get_depth(world_position: Vector3) -> float:
	_ensure_ready()
	var xz := Vector2(world_position.x, world_position.z)
	if not get_window_rect().has_point(xz):
		return 0.0
	var f := xz / get_texel_size() - Vector2(0.5, 0.5)
	var cell := f.floor()
	var t := f - cell
	var c := Vector2i(cell)
	var a := _effective(_index(c))
	var b := _effective(_index(c + Vector2i(1, 0)))
	var d := _effective(_index(c + Vector2i(0, 1)))
	var e := _effective(_index(c + Vector2i(1, 1)))
	return lerpf(lerpf(a, b, t.x), lerpf(d, e, t.x), t.y)


## Removes every mark.
func clear() -> void:
	_data.fill(0.0)
	_dirty = true


## Everything needed to restore the marks later: {"resolution", "size_m", "cell", "time", "data"}.
func get_state() -> Dictionary:
	return {"resolution": resolution, "size_m": size_m, "cell": _cell, "time": _time, "data": _data.duplicate()}


## Restores marks from [method get_state] (same resolution and size; else nothing happens and
## false is returned).
func set_state(state: Dictionary) -> bool:
	if int(state.get("resolution", -1)) != resolution or not is_equal_approx(float(state.get("size_m", -1.0)), size_m):
		return false
	_data = (state["data"] as PackedFloat32Array).duplicate()
	_cell = state["cell"]
	_time = state["time"]
	_dirty = true
	if is_inside_tree():
		_update_window()
		_upload()
	return true


func save_to(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(get_state())
	return OK


func load_from(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var state: Variant = f.get_var()
	return OK if state is Dictionary and set_state(state) else ERR_INVALID_DATA


# --- Internals ---------------------------------------------------------------------------------

func _rebuild() -> void:
	_data = PackedFloat32Array()
	_data.resize(resolution * resolution * 2)
	_image = Image.create_empty(resolution, resolution, false, Image.FORMAT_RGF)
	_texture = ImageTexture.create_from_image(_image)
	_cell = Vector2i(1 << 30, 1 << 30)
	_dirty = true
	if is_inside_tree():
		_update_window()
		_upload()
		_publish()


func _index(world_cell: Vector2i) -> int:
	return (posmod(world_cell.y, resolution) * resolution + posmod(world_cell.x, resolution)) * 2


func _effective(i: int) -> float:
	var depth := _data[i]
	var recovered := maxf(absf(depth) - recovery_rate * maxf(_time - _data[i + 1], 0.0), 0.0)
	return signf(depth) * recovered


## Moves the window to centre on the followed node, clearing the cells that left it.
func _update_window() -> void:
	var target := get_node_or_null(follow) as Node3D if not follow.is_empty() else null
	var center := (target if target != null else self).global_position if is_inside_tree() else position
	var t := get_texel_size()
	var cell := Vector2i(floori(center.x / t) - resolution / 2, floori(center.z / t) - resolution / 2)
	if cell == _cell:
		return
	var old := _cell
	_cell = cell
	if absi(cell.x - old.x) >= resolution or absi(cell.y - old.y) >= resolution:
		_data.fill(0.0)
	else:
		# Columns and rows of world cells that left the window: their texels now hold new cells.
		for x in range(old.x, cell.x) if cell.x > old.x else range(cell.x + resolution, old.x + resolution):
			for y in resolution:
				var i := _index(Vector2i(x, y))
				_data[i] = 0.0
				_data[i + 1] = 0.0
		for y in range(old.y, cell.y) if cell.y > old.y else range(cell.y + resolution, old.y + resolution):
			for x in resolution:
				var i := _index(Vector2i(x, y))
				_data[i] = 0.0
				_data[i + 1] = 0.0
	_dirty = true


## The buffers and the window, also before the node first enters the tree.
func _ensure_ready() -> void:
	if _data.size() != resolution * resolution * 2:
		_rebuild()
	if _cell == Vector2i(1 << 30, 1 << 30):
		_update_window()


## Applies profile(offset from centre) -> depth (INF = untouched) to the texels within reach.
func _paint(center: Vector2, reach: float, combine: Combine, profile: Callable) -> void:
	_ensure_ready()
	var t := get_texel_size()
	var window := get_window_rect()
	var lo := Vector2i(((center - Vector2(reach, reach)) / t).floor())
	var hi := Vector2i(((center + Vector2(reach, reach)) / t).ceil())
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var p := (Vector2(cx, cy) + Vector2(0.5, 0.5)) * t
			if not window.has_point(p):
				continue
			var depth: float = profile.call(p - center)
			if depth == INF:
				continue
			var i := _index(Vector2i(cx, cy))
			var current := _effective(i)
			var value := depth
			match combine:
				Combine.DEEPEN:
					value = maxf(current, depth) if depth >= 0.0 else (minf(current, depth) if current <= 0.0 else current)
				Combine.ADD:
					value = current + depth
			_data[i] = clampf(value, -max_depth, max_depth)
			_data[i + 1] = _time
	_dirty = true


func _upload() -> void:
	if _texture == null:
		return
	_image.set_data(resolution, resolution, false, Image.FORMAT_RGF, _data.to_byte_array())
	_texture.update(_image)
	_dirty = false


func _owns_globals() -> bool:
	var current: Variant = GADSGlobals.get_value(GADSGlobals.DEFORM)
	return current is Texture2D and current == _texture


func _publish() -> void:
	if _texture == null:
		return
	if not _owns_globals():
		GADSGlobals.set_value(GADSGlobals.DEFORM, _texture)
	var origin := get_window_rect().position
	GADSGlobals.set_value(GADSGlobals.DEFORM_PARAMS, Vector4(origin.x, origin.y, size_m, max_depth))
	GADSGlobals.set_value(GADSGlobals.DEFORM_TIME, Vector4(_time, recovery_rate, 0, 0))
