@tool
class_name GADSVertexPaint
extends RefCounted
## Painting a mesh's vertex colours, which the layered GADS materials take their layer masks from
## (layer 1 the red channel and layer 2 the green one by default; surface effects can read any
## channel): painting a channel places that layer, its relief included, by hand. The bake reads
## the same colours, so the baked geometry follows the paint.
##
## A mesh is painted on a copy ([method make_paintable]), so the asset it came from is never
## touched: the editor's Paint tool gives the node the copy and saves it next to the bakes
## ([code]<name>_painted.mesh[/code]); undo gives the node its old mesh back. From a script:
## [codeblock]
## var painted := GADSVertexPaint.make_paintable(node.mesh)
## node.mesh = painted
## var painter := GADSVertexPaint.new(painted)
## painter.dab(Vector3(0, 0, 0), 0.5, GADSVertexPaint.Mode.PAINT, 0, 1.0)  # mesh space
## [/codeblock]
## A painter keeps the colours as floats between dabs (they are stored with 8 bits) and updates
## the mesh on the GPU after each dab; [method get_colors] and [method set_colors] read and
## write them all (undo).

enum Mode { PAINT, ERASE, SMOOTH }

const MODE_NAMES := ["Paint", "Erase", "Smooth"]
const CHANNEL_NAMES := ["R (layer 1)", "G (layer 2)", "B", "A"]
## Metadata of a painted copy: the content hash of its colours (part of a bake's key) and the
## path of the mesh it was copied from.
const HASH_META := &"gads_paint_hash"
const SOURCE_META := &"gads_paint_source"

## The editor's Paint tool (the mesh inspectors set it, the plugin reads it): whether the viewport
## tool paints (else a GADSMeshInstance3D's Sculpt tool sculpts), the mode, the colour channel
## (0-3: R, G, B, A), the brush radius (m) and strength (0..1 of the way per dab at the centre).
static var tool_on := false
static var tool_mode := Mode.PAINT
static var tool_channel := 0
static var tool_radius := 0.25
static var tool_strength := 0.5

var mesh: ArrayMesh
var _colors: Array[PackedColorArray] = [] # per surface, as floats
var _positions: Array[PackedVector3Array] = []
var _attributes: Array[PackedByteArray] = [] # per surface, the attribute buffer as uploaded
var _offset: Array[int] = [] # per surface, the colour's byte offset in a vertex's attributes
var _stride: Array[int] = []
var _grid: Array[Dictionary] = [] # per surface: cell (Vector3i) -> PackedInt32Array of vertices
var _cell := 0.0


## A painter for [param painted] (a mesh from [method make_paintable], or any ArrayMesh whose
## surfaces all have vertex colours).
func _init(painted: ArrayMesh) -> void:
	mesh = painted
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if colors.size() != positions.size():
			colors = PackedColorArray()
			positions = PackedVector3Array()
		_colors.append(colors)
		_positions.append(positions)
		var fmt := mesh.surface_get_format(s)
		_offset.append(RenderingServer.mesh_surface_get_format_offset(fmt, positions.size(), Mesh.ARRAY_COLOR))
		_stride.append(RenderingServer.mesh_surface_get_format_attribute_stride(fmt, positions.size()))
		var data: Dictionary = RenderingServer.mesh_get_surface(mesh.get_rid(), s)
		_attributes.append(data.get("attribute_data", PackedByteArray()))
		_grid.append({})


## Whether every surface of [param m] has vertex colours to paint.
static func is_paintable(m: Mesh) -> bool:
	if not m is ArrayMesh or m.get_surface_count() == 0:
		return false
	for s in m.get_surface_count():
		if (m as ArrayMesh).surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR == 0:
			return false
	return true


## A copy of [param source] to paint on: an ArrayMesh with the same surfaces, materials, names,
## blend shapes, skin weights and LODs, plus vertex colours where it had none (white, which the
## layered materials read as "every layer everywhere", so the copy looks the same). Remembers
## [param source]'s path (the [constant SOURCE_META] metadata).
static func make_paintable(source: Mesh) -> ArrayMesh:
	var im := ImporterMesh.new()
	var shapes := 0
	if source is ArrayMesh:
		var am := source as ArrayMesh
		shapes = am.get_blend_shape_count()
		for b in shapes:
			im.add_blend_shape(am.get_blend_shape_name(b))
		im.set_blend_shape_mode(am.blend_shape_mode)
	var keep := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS | Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES
	for shift in [Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT]:
		keep |= Mesh.ARRAY_FORMAT_CUSTOM_MASK << shift
	for s in source.get_surface_count():
		var arrays := source.surface_get_arrays(s)
		var n := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if arrays[Mesh.ARRAY_COLOR] == null or (arrays[Mesh.ARRAY_COLOR] as PackedColorArray).size() != n:
			var white := PackedColorArray()
			white.resize(n)
			white.fill(Color.WHITE)
			arrays[Mesh.ARRAY_COLOR] = white
		var blend: Array[Array] = []
		if shapes > 0:
			blend = source.surface_get_blend_shape_arrays(s)
		var flags := 0
		var name := ""
		var primitive := GADSMeshBaker.surface_primitive(source, s)
		if source is ArrayMesh:
			flags = (source as ArrayMesh).surface_get_format(s) & keep
			name = (source as ArrayMesh).surface_get_name(s)
		im.add_surface(primitive, arrays, blend, {}, source.surface_get_material(s), name, flags)
	if source.get_surface_count() > 0 and GADSMeshBaker.surface_primitive(source, 0) == Mesh.PRIMITIVE_TRIANGLES:
		im.generate_lods(60.0, 0.0, [])
	var out := im.get_mesh()
	out.resource_name = source.resource_name
	out.set_meta(SOURCE_META, source.resource_path)
	update_hash(out)
	return out


## Stores the content hash of [param m]'s colours in its [constant HASH_META] metadata (a bake's
## key reads it: a saved file's time changes only once a second).
static func update_hash(m: ArrayMesh) -> void:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for s in m.get_surface_count():
		var colors = m.surface_get_arrays(s)[Mesh.ARRAY_COLOR]
		if colors != null:
			ctx.update((colors as PackedColorArray).to_byte_array())
	m.set_meta(HASH_META, ctx.finish().hex_encode().left(16))


## One brush dab: every vertex within [param radius] of [param centre] (both in the mesh's space)
## moves its [param channel] (0-3: R, G, B, A) towards 1 (PAINT), 0 (ERASE) or the average
## around it (SMOOTH) by up to [param strength] (0..1) of the way, with a smooth falloff (all of
## it at the centre, none at the radius). Returns how many vertices changed.
func dab(centre: Vector3, radius: float, mode: Mode, channel: int, strength: float) -> int:
	if radius <= 0.0:
		return 0
	if not is_equal_approx(_cell, radius):
		_build_grid(radius)
	var changed := 0
	var k := clampi(channel, 0, 3)
	var amount := clampf(strength, 0.0, 1.0)
	var c0 := Vector3i((centre / _cell).floor())
	for s in _colors.size():
		var colors := _colors[s]
		if colors.is_empty():
			continue
		var positions := _positions[s]
		var near := PackedInt32Array()
		var falloff := PackedFloat32Array()
		var grid := _grid[s]
		for dz in range(-1, 2):
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var cell: PackedInt32Array = grid.get(c0 + Vector3i(dx, dy, dz), PackedInt32Array())
					for i in cell:
						var d := positions[i].distance_to(centre) / radius
						if d < 1.0:
							var f := 1.0 - d * d
							near.append(i)
							falloff.append(f * f)
		if near.is_empty():
			continue
		var target := 1.0 if mode == Mode.PAINT else 0.0
		if mode == Mode.SMOOTH:
			var sum := 0.0
			var weight := 0.0
			for j in near.size():
				sum += colors[near[j]][k] * falloff[j]
				weight += falloff[j]
			target = sum / weight
		for j in near.size():
			var i := near[j]
			var c := colors[i]
			c[k] = lerpf(c[k], target, amount * falloff[j])
			colors[i] = c
		_colors[s] = colors
		_upload(s, near)
		changed += near.size()
	return changed


## Sets [param channel] of every vertex to [param value] (0..1).
func fill(channel: int, value: float) -> void:
	var k := clampi(channel, 0, 3)
	for s in _colors.size():
		var colors := _colors[s]
		for i in colors.size():
			var c := colors[i]
			c[k] = clampf(value, 0.0, 1.0)
			colors[i] = c
		_colors[s] = colors
		_upload(s, PackedInt32Array())


## Every surface's vertex colours (copies).
func get_colors() -> Array[PackedColorArray]:
	var out: Array[PackedColorArray] = []
	for c in _colors:
		out.append(c.duplicate())
	return out


## Sets every surface's vertex colours ([param colors] as [method get_colors] gives them).
func set_colors(colors: Array) -> void:
	for s in mini(colors.size(), _colors.size()):
		var c: PackedColorArray = colors[s]
		if c.size() == _colors[s].size():
			_colors[s] = c.duplicate()
			_upload(s, PackedInt32Array())


## Writes surface [param s]'s colours of [param vertices] (all when empty) into its attribute
## buffer and uploads it.
func _upload(s: int, vertices: PackedInt32Array) -> void:
	var bytes := _attributes[s]
	var colors := _colors[s]
	if bytes.is_empty() or colors.is_empty():
		return
	var off := _offset[s]
	var stride := _stride[s]
	if vertices.is_empty():
		for i in colors.size():
			_write_color(bytes, off + i * stride, colors[i])
	else:
		for i in vertices:
			_write_color(bytes, off + i * stride, colors[i])
	_attributes[s] = bytes
	mesh.surface_update_attribute_region(s, 0, bytes)


static func _write_color(bytes: PackedByteArray, at: int, c: Color) -> void:
	bytes[at] = clampi(int(c.r * 255.0), 0, 255)
	bytes[at + 1] = clampi(int(c.g * 255.0), 0, 255)
	bytes[at + 2] = clampi(int(c.b * 255.0), 0, 255)
	bytes[at + 3] = clampi(int(c.a * 255.0), 0, 255)


func _build_grid(cell: float) -> void:
	_cell = cell
	for s in _positions.size():
		var grid := {}
		var positions := _positions[s]
		for i in positions.size():
			var key := Vector3i((positions[i] / cell).floor())
			var list: PackedInt32Array = grid.get(key, PackedInt32Array())
			list.append(i)
			grid[key] = list
		_grid[s] = grid


## Where the ray from [param origin] along [param direction] (both in the mesh's space) first hits
## [param m]: {"position", "normal"}, or {} when it misses. [param cache] (a Dictionary kept between
## calls) holds the mesh's ray structure.
static func pick(m: Mesh, origin: Vector3, direction: Vector3, cache: Dictionary = {}) -> Dictionary:
	if m == null:
		return {}
	var key := "paint:%d" % m.get_instance_id()
	var tm: TriangleMesh = cache.get(key)
	if tm == null:
		if cache.size() > 4:
			cache.clear()
		tm = m.generate_triangle_mesh()
		cache[key] = tm
	if tm == null:
		return {}
	var hit := tm.intersect_ray(origin, direction)
	return {"position": hit["position"], "normal": hit["normal"]} if not hit.is_empty() else {}
