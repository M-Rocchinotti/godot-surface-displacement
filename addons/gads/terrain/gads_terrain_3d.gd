@tool
@icon("res://addons/gads/icons/gads_terrain_3d.svg")
class_name GADSTerrain3D
extends Node3D
## A heightmap terrain with GADS layers.
##
## - Geometry: a grid of chunks (internal MeshInstance3D children, built when the node enters the
##   tree), each with index LODs at every power of two of its quads, keyed by their largest height
##   error so the engine's mesh LOD picks the coarsest one that stays under a pixel. Skirts as deep
##   as that error hide the seams between chunks at different LODs.
## - Layers: up to three GADS materials (world-planar mapping, [code]height_center = 0[/code]),
##   combined into one layered material ([method GADSMaterials.combine_layers]): the first covers
##   everything, the second and third lie on top where [member splatmap] (R, G) puts them, or by
##   the slope and height rules below. The layers blend by height (the higher relief wins).
## - Collision: a HeightMapShape3D of the same grid.
## - Detail: a [GADSDisplacementField3D] (real displaced geometry from the layers' height maps
##   around the camera) on the terrain's own ground data, and the layers take the marks of a
##   [GADSDeformationField] in the scene (footprints, tracks; [method get_height] places
##   [GADSDeformer3D] contacts).
## - Streaming ([member stream_radius]): for terrains of kilometres, only the chunks around the
##   camera exist, built on worker threads as the camera moves, with collision per chunk and the
##   detail field's ground data in a window that follows the camera.
##
## The terrain is centred on the node, its size rounded to whole chunks. The detail field and
## deformation work in world space: keep the node unrotated and unscaled (moving it is fine; the
## ground data follows on the next rebuild).

signal rebuilt
## A streamed chunk was built and added (chunk coordinates).
signal chunk_loaded(chunk: Vector2i)

const MAX_LAYERS := 3
## Streamed chunks built on worker threads at once.
const MAX_STREAM_TASKS := 4

## Heights in the red channel, 0..1 over [member height_scale] (a 16-bit PNG or an EXR keeps them
## smooth). Empty: a flat terrain.
@export var heightmap: Texture2D:
	set(value):
		heightmap = value
		_queue_rebuild()
## Width and depth (m), rounded to whole chunks.
@export var size := Vector2(256, 256):
	set(value):
		size = value.max(Vector2(1, 1))
		_queue_rebuild()
## The height (m) a heightmap value of 1 rises to above [member height_offset].
@export_range(0.0, 2000.0, 0.1, "or_greater", "suffix:m") var height_scale := 40.0:
	set(value):
		height_scale = value
		_queue_rebuild()
@export_range(-1000.0, 1000.0, 0.1, "or_less", "or_greater", "suffix:m") var height_offset := 0.0:
	set(value):
		height_offset = value
		_queue_rebuild()

@export_group("Layers")
## Up to three GADS materials (world-planar, height_center 0): the first everywhere, the second
## and third on top of it (see the rules below). They are also the detail field's layers.
@export var layers: Array[ShaderMaterial] = []:
	set(value):
		layers = value
		_queue_rebuild()
## The terrain's material; empty: [member layers] combined into one layered GADS material.
@export var material: Material:
	set(value):
		material = value
		_queue_rebuild()
## Where the second (R) and third (G) layer lie, 0..1 over the terrain. Empty: the rules below.
@export var splatmap: Texture2D:
	set(value):
		splatmap = value
		_queue_rebuild()
## The layer (1 or 2; 0 = none) that covers slopes steeper than [member slope_range] (degrees,
## fading in over the range): rock on cliffs.
@export_range(0, 2) var slope_layer := 1:
	set(value):
		slope_layer = value
		_queue_rebuild()
@export var slope_range := Vector2(28.0, 40.0):
	set(value):
		slope_range = value
		_queue_rebuild()
## The layer (1 or 2; 0 = none) that covers the ground above [member height_band] (m, local,
## fading in over the band): snow on peaks.
@export_range(0, 2) var height_layer := 2:
	set(value):
		height_layer = value
		_queue_rebuild()
@export var height_band := Vector2(30.0, 34.0):
	set(value):
		height_band = value
		_queue_rebuild()

@export_group("Geometry")
## The distance between vertices of the finest LOD (m); the size divides into whole chunks.
@export_range(0.05, 16.0, 0.05, "or_greater", "suffix:m") var vertex_spacing := 1.0:
	set(value):
		vertex_spacing = maxf(value, 0.01)
		_queue_rebuild()
## Quads per chunk side (a power of two: its LODs halve it).
@export_enum("16:16", "32:32", "64:64", "128:128") var chunk_quads := 64:
	set(value):
		chunk_quads = value
		_queue_rebuild()
## The number of LODs per chunk (each halves the quads); at most log2(chunk_quads) + 1.
@export_range(1, 8) var lod_levels := 5:
	set(value):
		lod_levels = value
		_queue_rebuild()
@export var cast_shadows := true:
	set(value):
		cast_shadows = value
		for chunk in _chunks:
			chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if value else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Occlusion culling: each chunk gets an occluder (its grid at about [member occluder_quads]
## quads a side, lowered below the drawn surface by that grid's largest error, so it never hides
## what is visible), so hills hide what lies behind them. Needs Project Settings > Rendering >
## Occlusion Culling > Use Occlusion Culling.
@export var occluders := false:
	set(value):
		occluders = value
		_queue_rebuild()
@export_range(1, 64) var occluder_quads := 8:
	set(value):
		occluder_quads = value
		_queue_rebuild()

@export_group("Streaming")
## Build only the chunks within this distance (m) of the camera, on worker threads, and free those
## that fall behind; 0 = the whole terrain at once. For terrains of kilometres: collision comes per
## chunk, and the detail field's ground data in a window that follows the camera.
@export_range(0.0, 20000.0, 1.0, "or_greater", "suffix:m") var stream_radius := 0.0:
	set(value):
		stream_radius = maxf(value, 0.0)
		_queue_rebuild()
## The camera to stream around; empty: the viewport's (the editor's in the editor).
@export var stream_camera: NodePath

@export_group("Collision")
@export var collision := true:
	set(value):
		collision = value
		_queue_rebuild()
@export_flags_3d_physics var collision_layer := 1:
	set(value):
		collision_layer = value
		if _body != null:
			_body.collision_layer = value
@export_flags_3d_physics var collision_mask := 1:
	set(value):
		collision_mask = value
		if _body != null:
			_body.collision_mask = value

@export_group("Detail")
## Real displaced geometry from the layers' height maps around the camera (a
## GADSDisplacementField3D on the terrain's ground data; needs [member layers]).
@export var detail_field := true:
	set(value):
		detail_field = value
		_queue_rebuild()
## Texels of the ground data per vertex spacing (finer follows the triangles' creases more
## closely); fewer when the data would exceed 2048 texels a side.
@export_range(1, 4) var detail_subdivision := 2:
	set(value):
		detail_subdivision = value
		_queue_rebuild()

@export_tool_button("Rebuild", "Reload") var _rebuild_button := rebuild

var _nx := 0
var _nz := 0
var _spacing := 1.0
var _origin := Vector2.ZERO # local XZ of vertex (0, 0)
var _src := {} # the heightmap's red channel {"width", "height", "data"}; empty: flat
var _splat := {} # the splat map, RGBA float {"width", "height", "data"}; empty: rules
var _heights := PackedFloat32Array() # whole terrain only: local y per vertex, row-major (_nx per row)
var _w1 := PackedFloat32Array() # whole terrain only: the second layer's weight per vertex
var _w2 := PackedFloat32Array() # the third layer's
var _chunks: Array[MeshInstance3D] = []
var _chunk_nodes := {} # Vector2i -> MeshInstance3D
var _chunk_data := {} # Vector2i -> its arrays and LODs (kept for repainting)
var _paint := {} # vertex index -> painted Vector2 weights (overrides the splat map or rules)
var _paint_version := 0
var _pending_version := {} # Vector2i -> _paint_version when its build started
var _shapes := {} # Vector2i -> CollisionShape3D (streaming)
var _pending := {} # Vector2i -> WorkerThreadPool task (streaming)
var _results := {} # Vector2i -> chunk data from a finished task
var _mutex := Mutex.new()
var _window_task := -1
var _window_result := {}
var _window_center := Vector2.INF
var _window_side := Vector2(64, 64)
var _ground_offset_cache := Vector3.ZERO # the node's world position, for worker threads
var _body: StaticBody3D
var _field: GADSDisplacementField3D
var _material: Material
var _queued := false
var _build_ms := 0.0


func _ready() -> void:
	rebuild()


func _exit_tree() -> void:
	_wait_tasks()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_wait_tasks()


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if layers.size() > MAX_LAYERS:
		out.append("Only the first %d layers are used." % MAX_LAYERS)
	for i in mini(layers.size(), MAX_LAYERS):
		var info := GADSMaterials.parse(layers[i].shader) if layers[i] != null else {}
		if info.is_empty():
			out.append("Layer %d is not a GADS material." % i)
		elif info["mapping"] != GADSMaterials.Mapping.WORLD:
			out.append("Layer %d should use the world-planar mapping (a terrain has no UV layout for it)." % i)
	if not basis.is_equal_approx(Basis.IDENTITY) and detail_field:
		out.append("The detail field and deformation work in world space: keep the terrain unrotated and unscaled.")
	return out


func _queue_rebuild() -> void:
	if not is_inside_tree() or _queued:
		return
	_queued = true
	rebuild.call_deferred()


## Builds the heights, the chunks, the collision and the detail field again (after changing the
## layers' materials, say). The whole terrain on the calling thread; with [member stream_radius]
## the grid and the nodes, the chunks following around the camera.
func rebuild() -> void:
	_queued = false
	if not is_inside_tree():
		return
	var t0 := Time.get_ticks_usec()
	_wait_tasks()
	_free_chunks()
	_setup_grid()
	_src = _float_image(heightmap)
	_splat = _rgba_image(splatmap)
	_heights.clear()
	_w1.clear()
	_w2.clear()
	if not is_streaming():
		_build_heights()
		_build_weights()
	_material = material if material != null else GADSMaterials.combine_layers(layers.slice(0, MAX_LAYERS))
	if not is_streaming():
		var levels := _levels()
		for cz in (_nz - 1) / chunk_quads:
			for cx in (_nx - 1) / chunk_quads:
				_make_chunk(Vector2i(cx, cz), _chunk_arrays(cx, cz, levels))
	_build_collision()
	_build_field()
	_window_center = Vector2.INF
	set_process(is_streaming())
	_build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	update_configuration_warnings()
	rebuilt.emit()


func is_streaming() -> bool:
	return stream_radius > 0.0


# --- Queries ------------------------------------------------------------------------------------

## Width and depth (m) after rounding to whole chunks.
func get_extent() -> Vector2:
	return Vector2(_nx - 1, _nz - 1) * _spacing


## The vertices per side (x, z) of the finest grid.
func get_grid_size() -> Vector2i:
	return Vector2i(_nx, _nz)


func get_vertex_spacing() -> float:
	return _spacing


## Chunks per side (x, z).
func get_chunk_grid() -> Vector2i:
	return Vector2i((_nx - 1) / chunk_quads, (_nz - 1) / chunk_quads) if _nx > 1 else Vector2i.ZERO


## World height of the terrain's surface (as its finest LOD draws it) under [param world_position];
## NAN outside the terrain. A streamed terrain answers everywhere, built or not.
func get_height(world_position: Vector3) -> float:
	var local := to_local(world_position)
	var h := _height_local(Vector2(local.x, local.z))
	if is_nan(h):
		return NAN
	return to_global(Vector3(local.x, h, local.z)).y


## World height of the surface the terrain draws under [param world_position], with its relief:
## where the detail field displaces it, the field's relief there
## ([method GADSDisplacementField3D.get_surface_height]), elsewhere [method get_height]. For feet,
## decals and projectiles on the relief rather than on the triangles. NAN outside the terrain.
func get_surface_height(world_position: Vector3) -> float:
	var field := get_detail_field()
	if field != null and field.visible:
		var h := field.get_surface_height(world_position)
		if not is_nan(h):
			return h
	return get_height(world_position)


## World normal of the surface under [param world_position] (UP outside the terrain).
func get_normal(world_position: Vector3) -> Vector3:
	var local := to_local(world_position)
	var p := Vector2(local.x, local.z)
	var e := _spacing * 0.5
	var hx0 := _height_local(p - Vector2(e, 0))
	var hx1 := _height_local(p + Vector2(e, 0))
	var hz0 := _height_local(p - Vector2(0, e))
	var hz1 := _height_local(p + Vector2(0, e))
	if is_nan(hx0) or is_nan(hx1) or is_nan(hz0) or is_nan(hz1):
		return Vector3.UP
	var n := Vector3(-(hx1 - hx0) / (2.0 * e), 1.0, -(hz1 - hz0) / (2.0 * e)).normalized()
	return (global_basis * n).normalized()


## The weights (0..1) of the second and third layer under [param world_position].
func get_layer_weights(world_position: Vector3) -> Vector2:
	var local := to_local(world_position)
	var g := (Vector2(local.x, local.z) - _origin) / _spacing
	if _nx < 2 or g.x < 0.0 or g.y < 0.0 or g.x > _nx - 1 or g.y > _nz - 1:
		return Vector2.ZERO
	return _weights_at(g)


## The terrain's chunks (internal MeshInstance3D children; with streaming, those built now).
func get_chunks() -> Array[MeshInstance3D]:
	return _chunks


## The material the chunks draw with.
func get_material() -> Material:
	return _material


func get_detail_field() -> GADSDisplacementField3D:
	return _field


func get_collision_body() -> StaticBody3D:
	return _body


## Seconds the last rebuild took.
func get_build_seconds() -> float:
	return _build_ms / 1000.0


## Whether streamed chunks are being built on worker threads.
func is_streaming_busy() -> bool:
	return not _pending.is_empty() or _window_task >= 0


# --- Painting -------------------------------------------------------------------------------------

## Paints a layer onto the terrain while the game runs (or in the editor): within [param radius]
## metres of [param world_position], [param layer] (1: the second layer, 2: the third, 0: back to
## the first) takes over by [param strength] (0..1) in the middle, fading out over the outer
## [param falloff] of the radius. Updates the chunks' vertex colours and the detail field's ground
## data; [method get_painted_weights] keeps what was painted.
func paint_layer(world_position: Vector3, radius: float, layer: int, strength := 1.0, falloff := 0.5) -> void:
	if _nx < 2 or radius <= 0.0:
		return
	var local := to_local(world_position)
	var centre := Vector2(local.x, local.z)
	var g0 := Vector2i(((centre - Vector2.ONE * radius - _origin) / _spacing).floor()).clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	var g1 := Vector2i(((centre + Vector2.ONE * radius - _origin) / _spacing).ceil()).clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	var target := Vector2(1.0 if layer == 1 else 0.0, 1.0 if layer == 2 else 0.0)
	# Worker threads read the painted weights while they build chunks: paint into a copy then.
	var paint := _paint if _pending.is_empty() else _paint.duplicate()
	var inner := radius * (1.0 - clampf(falloff, 0.0, 1.0))
	var changed := false
	for gz in range(g0.y, g1.y + 1):
		for gx in range(g0.x, g1.x + 1):
			var d := centre.distance_to(_origin + Vector2(gx, gz) * _spacing)
			if d > radius:
				continue
			var amount := clampf(strength, 0.0, 1.0) * (1.0 - smoothstep(inner, radius, d) if radius > inner else 1.0)
			if amount <= 0.0:
				continue
			var w := _grid_weights(gx, gz)
			var painted := w.lerp(target, amount) if layer != 0 else w * (1.0 - amount)
			if layer == 1:
				painted.x = maxf(painted.x, w.x)
			elif layer == 2:
				painted.y = maxf(painted.y, w.y)
			paint[gz * _nx + gx] = painted
			changed = true
	if changed:
		_paint = paint
		_paint_version += 1
		_repaint(Rect2(_origin + Vector2(g0) * _spacing, Vector2(g1 - g0) * _spacing))


## The painted weights: {vertex index: Vector2 (second, third layer)}; give them back with
## [method set_painted_weights] (a save game, say) after the terrain is built.
func get_painted_weights() -> Dictionary:
	return _paint.duplicate()


func set_painted_weights(weights: Dictionary) -> void:
	_paint = weights.duplicate()
	_paint_version += 1
	_repaint(Rect2(_origin, get_extent()))


## Clears what was painted.
func clear_paint() -> void:
	_paint = {}
	_paint_version += 1
	_repaint(Rect2(_origin, get_extent()))


## Refreshes the vertex colours of the chunks within local [param rect] and the field's ground
## data there.
func _repaint(rect: Rect2) -> void:
	var cq := chunk_quads
	for key: Vector2i in _chunk_data.keys():
		var r := _chunk_rect(key).grow(_spacing)
		if not r.intersects(rect, true):
			continue
		var data: Dictionary = _chunk_data[key]
		var arrays: Array = data["arrays"]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var n := cq + 1
		for z in n:
			for x in n:
				var wts := _grid_weights(key.x * cq + x, key.y * cq + z)
				colors[z * n + x] = Color(wts.x, wts.y, 0.0, 1.0)
		var ring := _ring(cq)
		for i in ring.size():
			colors[n * n + i] = colors[ring[i].y * n + ring[i].x]
		arrays[Mesh.ARRAY_COLOR] = colors
		var mesh := (_chunk_nodes[key] as MeshInstance3D).mesh as ArrayMesh
		mesh.clear_surfaces()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], data["lods"])
	_repaint_ground(rect)


## Rewrites the layer codes of the field's ground data within local [param rect].
func _repaint_ground(rect: Rect2) -> void:
	if _field == null or _field.ground_bake == null:
		return
	var bake := _field.ground_bake
	var gp := _ground_offset_cache
	var size := bake.get_size()
	var texel := bake.texel_size
	var world := Rect2(rect.position + Vector2(gp.x, gp.z), rect.size).grow(texel)
	var t0 := Vector2i(((world.position - bake.origin) / texel).floor()).clamp(Vector2i.ZERO, size - Vector2i.ONE)
	var t1 := Vector2i(((world.end - bake.origin) / texel).ceil()).clamp(Vector2i.ZERO, size - Vector2i.ONE)
	for ty in range(t0.y, t1.y + 1):
		for tx in range(t0.x, t1.x + 1):
			var p := bake.origin + (Vector2(tx, ty) + Vector2(0.5, 0.5)) * texel - Vector2(gp.x, gp.z)
			var g := ((p - _origin) / _spacing).clamp(Vector2.ZERO, Vector2(_nx - 1, _nz - 1))
			var wts := _weights_at(g)
			var layer := 2 if wts.y >= 0.5 else (1 if wts.x >= 0.5 else 0)
			var code := layer if layer < layers.size() else -1
			var c := bake.data.get_pixel(tx, ty)
			if c.a > 0.5:
				c.b = (code + 1) / 8.0
				bake.data.set_pixel(tx, ty, c)
	_field.ground_bake = bake # uploads it again


## The texel of the ground data (m): the vertex spacing divided by [member detail_subdivision],
## or multiplied by powers of two while the data would exceed 2048 texels a side (with streaming:
## its window). Texel centres lie on the vertices, so the field's bilinear heights follow the
## triangles.
func get_ground_texel() -> float:
	var extent := _window_side if is_streaming() else get_extent()
	var texel := _spacing / maxi(detail_subdivision, 1)
	while maxf(extent.x, extent.y) / texel + 1.0 > 2048.0:
		texel *= 2.0
	return texel


## The terrain's ground data for a GADSDisplacementField3D (world space): height of the finest
## LOD and the dominant layer per texel, texel centres on the vertices (see
## [method get_ground_texel]). [param rect]: the local XZ part to cover (empty: all of it).
## Reads no node: a worker thread may call it.
func make_ground_bake(rect := Rect2()) -> GADSGroundBake:
	if _nx < 2:
		return null
	var extent := get_extent()
	var all := Rect2(_origin, extent)
	rect = all if not rect.has_area() else rect.intersection(all)
	if not rect.has_area():
		return null
	var texel := get_ground_texel()
	# Snap to the texel grid (which has a texel centre on vertex (0, 0)).
	var i0 := Vector2i(((rect.position - _origin) / texel).floor())
	var i1 := Vector2i(((rect.end - _origin) / texel).ceil())
	var w := i1.x - i0.x + 1
	var d := i1.y - i0.y + 1
	if OS.get_thread_caller_id() == OS.get_main_thread_id() and is_inside_tree():
		_ground_offset_cache = global_position
	var gp := _ground_offset_cache
	var heights := PackedFloat32Array()
	heights.resize(w * d)
	var codes := PackedInt32Array()
	codes.resize(w * d)
	for z in d:
		for x in w:
			var p := _origin + Vector2(i0.x + x, i0.y + z) * texel
			var i := z * w + x
			heights[i] = _height_local(p.clamp(_origin, _origin + extent)) + gp.y
			var g := ((p - _origin) / _spacing).clamp(Vector2.ZERO, Vector2(_nx - 1, _nz - 1))
			var wts := _weights_at(g)
			var layer := 2 if wts.y >= 0.5 else (1 if wts.x >= 0.5 else 0)
			codes[i] = layer if layer < layers.size() else -1
	return GADSGroundBake.from_arrays(Vector2i(w, d), heights, codes,
		_origin + Vector2(i0) * texel - Vector2(texel, texel) * 0.5 + Vector2(gp.x, gp.z), texel)


## How far the field's bilinear heights can fall from the triangles on ground it displaces (m):
## a texel cell that a quad's diagonal crosses differs by up to a quarter of the quad's crease
## (h00 + h11 - h10 - h01) times the texel over the spacing, halved; quads steeper than the
## field's step limit are left out (the field does not displace them). [param rect]: the local XZ
## part to look at (empty: all).
func ground_data_error(rect := Rect2()) -> float:
	if _nx < 2:
		return 0.0
	var ratio := get_ground_texel() / _spacing
	var factor := 0.125 if ratio < 0.75 else 0.25 * ratio
	var steep := GADSGroundBake.STEP_SLOPE * _spacing
	var g0 := Vector2i.ZERO
	var g1 := Vector2i(_nx - 1, _nz - 1)
	if rect.has_area():
		g0 = Vector2i(((rect.position - _origin) / _spacing).floor()).clamp(Vector2i.ZERO, g1)
		g1 = Vector2i(((rect.end - _origin) / _spacing).ceil()).clamp(Vector2i.ZERO, g1)
	var worst := 0.0
	for z in range(g0.y, g1.y):
		for x in range(g0.x, g1.x):
			var h00 := _grid_h(x, z)
			var h10 := _grid_h(x + 1, z)
			var h01 := _grid_h(x, z + 1)
			var h11 := _grid_h(x + 1, z + 1)
			if maxf(maxf(absf(h10 - h00), absf(h01 - h00)), maxf(absf(h11 - h10), absf(h11 - h01))) > steep:
				continue
			worst = maxf(worst, absf(h00 + h11 - h10 - h01))
	return worst * factor


# --- The grid -----------------------------------------------------------------------------------

func _setup_grid() -> void:
	var cq := chunk_quads
	var qx := maxi(cq, roundi(size.x / vertex_spacing / cq) * cq)
	_spacing = size.x / qx
	var qz := maxi(cq, roundi(size.y / _spacing / cq) * cq)
	_nx = qx + 1
	_nz = qz + 1
	_origin = -Vector2(qx, qz) * _spacing * 0.5


func _levels() -> int:
	return clampi(lod_levels, 1, int(log(chunk_quads) / log(2.0) + 0.5) + 1)


## Height of grid vertex (gx, gz) (clamped to the grid): from the whole-terrain array, or sampled
## from the heightmap (streaming). Thread-safe.
func _grid_h(gx: int, gz: int) -> float:
	gx = clampi(gx, 0, _nx - 1)
	gz = clampi(gz, 0, _nz - 1)
	if not _heights.is_empty():
		return _heights[gz * _nx + gx]
	return _sample_source(gx, gz)


## The heightmap, bilinear, at grid vertex (gx, gz).
func _sample_source(gx: int, gz: int) -> float:
	if _src.is_empty():
		return height_offset
	var w: int = _src["width"]
	var h: int = _src["height"]
	var data: PackedFloat32Array = _src["data"]
	var py := float(gz) / (_nz - 1) * (h - 1)
	var y0 := mini(floori(py), h - 2) if h > 1 else 0
	var fy := py - y0 if h > 1 else 0.0
	var px := float(gx) / (_nx - 1) * (w - 1)
	var x0 := mini(floori(px), w - 2) if w > 1 else 0
	var fx := px - x0 if w > 1 else 0.0
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var top := lerpf(data[y0 * w + x0], data[y0 * w + x1], fx)
	var bottom := lerpf(data[y1 * w + x0], data[y1 * w + x1], fx)
	return height_offset + height_scale * lerpf(top, bottom, fy)


func _build_heights() -> void:
	_heights.resize(_nx * _nz)
	for z in _nz:
		for x in _nx:
			_heights[z * _nx + x] = _sample_source(x, z)


## {"width", "height", "data": PackedFloat32Array of the red channel} of a texture, or {}.
static func _float_image(tex: Texture2D) -> Dictionary:
	if tex == null:
		return {}
	var img := tex.get_image()
	if img == null or img.is_empty():
		return {}
	img = img.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RF)
	return {"width": img.get_width(), "height": img.get_height(), "data": img.get_data().to_float32_array()}


## {"width", "height", "data": PackedFloat32Array RGBA} of a texture, or {}.
static func _rgba_image(tex: Texture2D) -> Dictionary:
	if tex == null:
		return {}
	var img := tex.get_image()
	if img == null or img.is_empty():
		return {}
	img = img.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBAF)
	return {"width": img.get_width(), "height": img.get_height(), "data": img.get_data().to_float32_array()}


## The second and third layers' weights at grid vertex (gx, gz): the splat map's nearest pixel, or
## the slope and height rules. Thread-safe.
func _compute_weights(gx: int, gz: int) -> Vector2:
	if not _splat.is_empty():
		var w: int = _splat["width"]
		var h: int = _splat["height"]
		var data: PackedFloat32Array = _splat["data"]
		var px := clampi(roundi(float(gx) / (_nx - 1) * (w - 1)), 0, w - 1)
		var py := clampi(roundi(float(gz) / (_nz - 1) * (h - 1)), 0, h - 1)
		var k := (py * w + px) * 4
		return Vector2(data[k], data[k + 1])
	var out := Vector2.ZERO
	var nrm := _grid_normal(gx, gz)
	var slope := smoothstep(slope_range.x, maxf(slope_range.y, slope_range.x + 0.001), rad_to_deg(acos(clampf(nrm.y, -1.0, 1.0))))
	var high := smoothstep(height_band.x, maxf(height_band.y, height_band.x + 0.001), _grid_h(gx, gz))
	for rule in [[slope_layer, slope], [height_layer, high]]:
		if rule[0] == 1:
			out.x = maxf(out.x, rule[1])
		elif rule[0] == 2:
			out.y = maxf(out.y, rule[1])
	return out


func _grid_weights(gx: int, gz: int) -> Vector2:
	gx = clampi(gx, 0, _nx - 1)
	gz = clampi(gz, 0, _nz - 1)
	if not _paint.is_empty():
		var painted: Variant = _paint.get(gz * _nx + gx)
		if painted != null:
			return painted
	if not _w1.is_empty():
		var i := gz * _nx + gx
		return Vector2(_w1[i], _w2[i])
	return _compute_weights(gx, gz)


func _build_weights() -> void:
	var n := _nx * _nz
	_w1.resize(n)
	_w2.resize(n)
	for z in _nz:
		for x in _nx:
			var wts := _compute_weights(x, z)
			_w1[z * _nx + x] = wts.x
			_w2[z * _nx + x] = wts.y


func _grid_normal(x: int, z: int) -> Vector3:
	var xa := maxi(x - 1, 0)
	var xb := mini(x + 1, _nx - 1)
	var za := maxi(z - 1, 0)
	var zb := mini(z + 1, _nz - 1)
	var dhdx := (_grid_h(xb, z) - _grid_h(xa, z)) / ((xb - xa) * _spacing)
	var dhdz := (_grid_h(x, zb) - _grid_h(x, za)) / ((zb - za) * _spacing)
	return Vector3(-dhdx, 1.0, -dhdz).normalized()


## Layer weights at grid position [param g] (fractional), bilinear between the vertices.
func _weights_at(g: Vector2) -> Vector2:
	var x0 := mini(floori(g.x), _nx - 2)
	var z0 := mini(floori(g.y), _nz - 2)
	var fx := g.x - x0
	var fz := g.y - z0
	var top := _grid_weights(x0, z0).lerp(_grid_weights(x0 + 1, z0), fx)
	var bottom := _grid_weights(x0, z0 + 1).lerp(_grid_weights(x0 + 1, z0 + 1), fx)
	return top.lerp(bottom, fz)


## Local height of the finest LOD's triangles at local [param p] (the grid's diagonal split); NAN
## outside.
func _height_local(p: Vector2) -> float:
	if _nx < 2:
		return NAN
	var g := (p - _origin) / _spacing
	if g.x < -1e-4 or g.y < -1e-4 or g.x > _nx - 1 + 1e-4 or g.y > _nz - 1 + 1e-4:
		return NAN
	g = g.clamp(Vector2.ZERO, Vector2(_nx - 1, _nz - 1))
	var x0 := mini(floori(g.x), _nx - 2)
	var z0 := mini(floori(g.y), _nz - 2)
	return _tri_interp(_grid_h(x0, z0), _grid_h(x0 + 1, z0), _grid_h(x0, z0 + 1), _grid_h(x0 + 1, z0 + 1), g.x - x0, g.y - z0)


## Height in a quad split along its (1, 0)-(0, 1) diagonal, as the chunks triangulate it.
static func _tri_interp(h00: float, h10: float, h01: float, h11: float, fx: float, fz: float) -> float:
	if fx + fz <= 1.0:
		return h00 + fx * (h10 - h00) + fz * (h01 - h00)
	return h11 + (1.0 - fx) * (h01 - h11) + (1.0 - fz) * (h10 - h11)


# --- Chunks -------------------------------------------------------------------------------------

func _free_chunks() -> void:
	for chunk in _chunks:
		chunk.queue_free()
	_chunks.clear()
	_chunk_nodes.clear()
	_chunk_data.clear()
	for shape: CollisionShape3D in _shapes.values():
		shape.queue_free()
	_shapes.clear()


## The vertices of a chunk's border, once around: -Z side, +X side, +Z side, -X side.
static func _ring(cq: int) -> Array[Vector2i]:
	var ring: Array[Vector2i] = []
	for x in cq:
		ring.append(Vector2i(x, 0))
	for z in cq:
		ring.append(Vector2i(cq, z))
	for x in range(cq, 0, -1):
		ring.append(Vector2i(x, cq))
	for z in range(cq, 0, -1):
		ring.append(Vector2i(0, z))
	return ring


## A chunk's mesh arrays and LODs: {"arrays", "lods", "heights" (its vertices' heights, for its
## collision)}. Reads no node: runs on worker threads while streaming.
func _chunk_arrays(cx: int, cz: int, levels: int) -> Dictionary:
	var cq := chunk_quads
	var n := cq + 1
	var gx0 := cx * cq
	var gz0 := cz * cq
	var ring := _ring(cq)
	var count := n * n + ring.size()
	var verts := PackedVector3Array()
	verts.resize(count)
	var normals := PackedVector3Array()
	normals.resize(count)
	var tangents := PackedFloat32Array()
	tangents.resize(count * 4)
	var colors := PackedColorArray()
	colors.resize(count)
	var uvs := PackedVector2Array()
	uvs.resize(count)
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var extent := get_extent()
	for z in n:
		for x in n:
			var i := z * n + x
			var gx := gx0 + x
			var gz := gz0 + z
			var nrm := _grid_normal(gx, gz)
			heights[i] = _grid_h(gx, gz)
			verts[i] = Vector3(_origin.x + gx * _spacing, heights[i], _origin.y + gz * _spacing)
			normals[i] = nrm
			var t := Vector3(1, 0, 0)
			t = (t - nrm * nrm.dot(t)).normalized()
			tangents[i * 4] = t.x
			tangents[i * 4 + 1] = t.y
			tangents[i * 4 + 2] = t.z
			tangents[i * 4 + 3] = 1.0
			var wts := _grid_weights(gx, gz)
			colors[i] = Color(wts.x, wts.y, 0.0, 1.0)
			uvs[i] = Vector2(float(gx) * _spacing / extent.x, float(gz) * _spacing / extent.y)
	# The height error of each LOD: the finest grid against the LOD's triangles.
	var errors := PackedFloat32Array()
	errors.resize(levels)
	for k in range(1, levels):
		var s := 1 << k
		var worst := 0.0
		for z in n:
			for x in n:
				var x0 := mini((x / s) * s, cq - s)
				var z0 := mini((z / s) * s, cq - s)
				var hc := _tri_interp(heights[z0 * n + x0], heights[z0 * n + x0 + s], heights[(z0 + s) * n + x0],
					heights[(z0 + s) * n + x0 + s], float(x - x0) / s, float(z - z0) / s)
				worst = maxf(worst, absf(heights[z * n + x] - hc))
		errors[k] = worst
	# Skirts hang below the border by the widest gap a neighbour at another LOD can leave: both
	# interpolate the same border heights, each within its LOD's error of them (and a border's error
	# at a LOD is at most the chunk's), so the gap is under twice the largest error.
	var largest := 0.0
	for e in errors:
		largest = maxf(largest, e)
	var skirt := 2.0 * largest + _spacing * 0.05 + 0.01
	for r in ring.size():
		var src := ring[r].y * n + ring[r].x
		var i := n * n + r
		verts[i] = verts[src] - Vector3(0, skirt, 0)
		normals[i] = normals[src]
		for c in 4:
			tangents[i * 4 + c] = tangents[src * 4 + c]
		colors[i] = colors[src]
		uvs[i] = uvs[src]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _chunk_indices(cq, 1, ring.size())
	var lods := {}
	var key := 0.0
	for k in range(1, levels):
		# Keys: the LOD's error in metres (the engine uses the coarsest LOD whose key covers less than
		# its mesh LOD threshold on screen), strictly increasing.
		key = maxf(errors[k], key + 1e-5)
		lods[key] = _chunk_indices(cq, 1 << k, ring.size())
	var out := {"arrays": arrays, "lods": lods, "heights": heights}
	if occluders:
		out["occluder"] = _occluder_arrays(heights, verts, cq, occluder_quads)
	return out


## A conservative occluder of a chunk: its grid at a coarser stride (about [member occluder_quads]
## quads a side), lowered by that stride's largest height error plus a centimetre, so it lies
## below the drawn surface everywhere (the difference between the finest triangles and the coarse
## ones is linear on each fine triangle: its extremes are at grid vertices, where it is measured).
static func _occluder_arrays(heights: PackedFloat32Array, verts: PackedVector3Array, cq: int, quads := -1) -> Dictionary:
	var n := cq + 1
	var s := 1
	while s * 2 <= cq and cq / (s * 2) >= maxi(quads, 1):
		s *= 2
	var worst := 0.0
	for z in n:
		for x in n:
			var x0 := mini((x / s) * s, cq - s)
			var z0 := mini((z / s) * s, cq - s)
			var hc := _tri_interp(heights[z0 * n + x0], heights[z0 * n + x0 + s], heights[(z0 + s) * n + x0],
				heights[(z0 + s) * n + x0 + s], float(x - x0) / s, float(z - z0) / s)
			worst = maxf(worst, hc - heights[z * n + x])
	var drop := worst + 0.01
	var points := PackedVector3Array()
	var m := cq / s + 1
	for z in range(0, n, s):
		for x in range(0, n, s):
			points.append(verts[z * n + x] - Vector3(0, drop, 0))
	var idx := PackedInt32Array()
	for z in m - 1:
		for x in m - 1:
			var a := z * m + x
			var b := a + 1
			var c := a + m
			var d := c + 1
			idx.append_array([a, b, c, b, d, c])
	return {"vertices": points, "indices": idx, "drop": drop}


## Adds chunk [param key] from its arrays (main thread).
func _make_chunk(key: Vector2i, data: Dictionary) -> void:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data["arrays"], [], data["lods"])
	var mi := MeshInstance3D.new()
	mi.name = "Chunk_%d_%d" % [key.x, key.y]
	mi.mesh = mesh
	mi.material_override = _material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi, false, Node.INTERNAL_MODE_BACK)
	if data.has("occluder"):
		var occ := ArrayOccluder3D.new()
		occ.set_arrays(data["occluder"]["vertices"], data["occluder"]["indices"])
		var oi := OccluderInstance3D.new()
		oi.name = "Occluder"
		oi.occluder = occ
		mi.add_child(oi, false, Node.INTERNAL_MODE_BACK)
	_chunks.append(mi)
	_chunk_nodes[key] = mi
	_chunk_data[key] = data
	if is_streaming() and _body != null:
		_add_chunk_shape(key, data["heights"])


## Triangles of a chunk's grid at stride [param s] and its skirts. Front faces wind clockwise seen
## from outside (Godot's convention): from above for the grid, from outside the chunk for skirts.
static func _chunk_indices(cq: int, s: int, ring_size: int) -> PackedInt32Array:
	var n := cq + 1
	var idx := PackedInt32Array()
	for z in range(0, cq, s):
		for x in range(0, cq, s):
			var a := z * n + x
			var b := a + s
			var c := a + s * n
			var d := c + s
			idx.append_array([a, b, c, b, d, c])
	var ring := _ring(cq)
	for r in range(0, ring_size, s):
		var r2 := (r + s) % ring_size
		var top_a := ring[r].y * n + ring[r].x
		var top_b := ring[r2].y * n + ring[r2].x
		var low_a := n * n + r
		var low_b := n * n + r2
		# The ring runs counter-clockwise seen from above (-Z side towards +X first), so seen from
		# outside a segment runs right to left: (a, low_a, b), (b, low_a, low_b) wind clockwise.
		idx.append_array([top_a, low_a, top_b, top_b, low_a, low_b])
	return idx


# --- Streaming ----------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not is_streaming() or _nx < 2:
		set_process(false)
		return
	_collect_tasks()
	var cam := _stream_camera_node()
	if cam == null:
		return
	var p := to_local(cam.global_position)
	var xz := Vector2(p.x, p.z)
	_update_stream(xz)
	_update_ground_window(xz)


func _stream_camera_node() -> Camera3D:
	if not stream_camera.is_empty():
		return get_node_or_null(stream_camera) as Camera3D
	if Engine.is_editor_hint():
		var editor := Engine.get_singleton(&"EditorInterface")
		if editor != null:
			var vp: SubViewport = editor.get_editor_viewport_3d(0)
			return vp.get_camera_3d() if vp != null else null
		return null
	return get_viewport().get_camera_3d() if get_viewport() != null else null


## Local XZ rectangle of chunk [param key].
func _chunk_rect(key: Vector2i) -> Rect2:
	var side := chunk_quads * _spacing
	return Rect2(_origin + Vector2(key) * side, Vector2(side, side))


static func _rect_distance(r: Rect2, p: Vector2) -> float:
	return p.distance_to(p.clamp(r.position, r.end))


## Starts the missing chunks within the radius, nearest first, and frees those well beyond it.
func _update_stream(xz: Vector2) -> void:
	var grid := get_chunk_grid()
	var side := chunk_quads * _spacing
	var lo := Vector2i(((xz - Vector2.ONE * stream_radius - _origin) / side).floor()).clamp(Vector2i.ZERO, grid - Vector2i.ONE)
	var hi := Vector2i(((xz + Vector2.ONE * stream_radius - _origin) / side).floor()).clamp(Vector2i.ZERO, grid - Vector2i.ONE)
	var wanted := []
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var key := Vector2i(cx, cz)
			if _chunk_nodes.has(key) or _pending.has(key):
				continue
			var d := _rect_distance(_chunk_rect(key), xz)
			if d <= stream_radius:
				wanted.append([d, key])
	wanted.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var levels := _levels()
	for item: Array in wanted:
		if _pending.size() >= MAX_STREAM_TASKS:
			break
		var key: Vector2i = item[1]
		_pending[key] = WorkerThreadPool.add_task(_build_task.bind(key, levels), false, "GADS terrain chunk")
		_pending_version[key] = _paint_version
	# Hysteresis: a chunk goes only once well beyond the radius, so a camera on the edge does not
	# rebuild it back and forth.
	var drop := stream_radius * 1.25 + side
	for key: Vector2i in _chunk_nodes.keys():
		if _rect_distance(_chunk_rect(key), xz) > drop:
			var mi: MeshInstance3D = _chunk_nodes[key]
			_chunks.erase(mi)
			_chunk_nodes.erase(key)
			_chunk_data.erase(key)
			mi.queue_free()
			if _shapes.has(key):
				(_shapes[key] as Node).queue_free()
				_shapes.erase(key)


## Worker thread: one chunk's arrays.
func _build_task(key: Vector2i, levels: int) -> void:
	var data := _chunk_arrays(key.x, key.y, levels)
	_mutex.lock()
	_results[key] = data
	_mutex.unlock()


## Adds the chunks whose tasks finished (at most two per frame: creating meshes costs the main
## thread).
func _collect_tasks() -> void:
	var added := 0
	for key: Vector2i in _pending.keys():
		if added >= 2:
			break
		var task: int = _pending[key]
		if not WorkerThreadPool.is_task_completed(task):
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		_pending.erase(key)
		var painted_since: bool = _pending_version.get(key, _paint_version) != _paint_version
		_pending_version.erase(key)
		_mutex.lock()
		var data: Dictionary = _results.get(key, {})
		_results.erase(key)
		_mutex.unlock()
		if not data.is_empty():
			_make_chunk(key, data)
			if painted_since:
				_repaint(_chunk_rect(key)) # painted while it was being built
			chunk_loaded.emit(key)
			added += 1
	if _window_task >= 0 and WorkerThreadPool.is_task_completed(_window_task):
		WorkerThreadPool.wait_for_task_completion(_window_task)
		_window_task = -1
		_mutex.lock()
		var result := _window_result
		_window_result = {}
		_mutex.unlock()
		if _field != null and result.get("bake") != null:
			_field.lift = result["lift"]
			_field.ground_bake = result["bake"]
			_field.visible = true


func _wait_tasks() -> void:
	for task: int in _pending.values():
		WorkerThreadPool.wait_for_task_completion(task)
	_pending.clear()
	_pending_version.clear()
	_results.clear()
	if _window_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_window_task)
		_window_task = -1
	_window_result = {}


## The side (m) of the detail field's ground data around the camera when streaming.
func _ground_window_size() -> Vector2:
	var reach := _field.get_reach() if _field != null else 8.0
	var side := clampf(4.0 * reach + 16.0, 32.0, 512.0)
	return Vector2(side, side)


## Rebuilds the detail field's ground data around the camera once it moved a quarter of the
## window from its centre (on a worker thread).
func _update_ground_window(xz: Vector2) -> void:
	if _field == null or _window_task >= 0:
		return
	var side := _ground_window_size()
	_window_side = side
	if _window_center != Vector2.INF and xz.distance_to(_window_center) < side.x * 0.25:
		return
	_window_center = xz
	_ground_offset_cache = global_position
	var rect := Rect2(xz - side * 0.5, side)
	_window_task = WorkerThreadPool.add_task(_window_job.bind(rect), false, "GADS terrain ground data")


func _window_job(rect: Rect2) -> void:
	var bake := make_ground_bake(rect)
	var lift := clampf(ground_data_error(rect) + 0.002, 0.002, 0.1)
	_mutex.lock()
	_window_result = {"bake": bake, "lift": lift}
	_mutex.unlock()


# --- Collision and detail -----------------------------------------------------------------------

func _build_collision() -> void:
	if not collision or _nx < 2:
		if _body != null:
			_body.queue_free()
			_body = null
		return
	if _body == null:
		_body = StaticBody3D.new()
		_body.name = "GADSTerrainCollision"
		add_child(_body, false, Node.INTERNAL_MODE_BACK)
	_body.collision_layer = collision_layer
	_body.collision_mask = collision_mask
	for child in _body.get_children():
		child.queue_free()
	if is_streaming():
		return # one shape per streamed chunk, as it loads
	# A HeightMapShape3D has one unit between samples and is centred: scale it by the spacing
	# (uniformly, with the heights divided by it), offset to the grid's centre.
	var data := PackedFloat32Array()
	data.resize(_heights.size())
	for i in _heights.size():
		data[i] = _heights[i] / _spacing
	_body.add_child(_height_shape(_nx, _nz, data, _origin + Vector2(_nx - 1, _nz - 1) * _spacing * 0.5))


func _height_shape(w: int, d: int, data: PackedFloat32Array, centre: Vector2) -> CollisionShape3D:
	var shape := HeightMapShape3D.new()
	shape.map_width = w
	shape.map_depth = d
	shape.map_data = data
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = Transform3D(Basis.from_scale(Vector3.ONE * _spacing), Vector3(centre.x, 0.0, centre.y))
	return cs


func _add_chunk_shape(key: Vector2i, heights: PackedFloat32Array) -> void:
	var n := chunk_quads + 1
	var data := PackedFloat32Array()
	data.resize(heights.size())
	for i in heights.size():
		data[i] = heights[i] / _spacing
	var cs := _height_shape(n, n, data, _chunk_rect(key).get_center())
	cs.name = "Chunk_%d_%d" % [key.x, key.y]
	_body.add_child(cs)
	_shapes[key] = cs


func _build_field() -> void:
	var want := detail_field and not layers.is_empty() and _nx >= 2
	if not want:
		if _field != null:
			_field.queue_free()
			_field = null
		return
	if _field == null:
		_field = GADSDisplacementField3D.new()
		_field.name = "GADSTerrainDetail"
		_field.bake_on_ready = false
		add_child(_field, false, Node.INTERNAL_MODE_BACK)
	var field_layers: Array[ShaderMaterial] = []
	for i in mini(layers.size(), MAX_LAYERS):
		field_layers.append(layers[i])
	_field.layers = field_layers
	_ground_offset_cache = global_position
	if is_streaming():
		# The ground data comes in a window around the camera; until the first one the field would
		# draw a flat sheet.
		_field.ground_bake = null
		_field.visible = false
		return
	_field.visible = true
	# Lifted by what its ground data can fall short of the triangles, so the terrain stays under it.
	_field.lift = clampf(ground_data_error() + 0.002, 0.002, 0.1)
	_field.ground_bake = make_ground_bake()
