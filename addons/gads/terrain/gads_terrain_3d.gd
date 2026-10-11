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
## - Layers: up to four GADS materials (world-planar mapping, [code]height_center = 0[/code]),
##   combined into one layered material ([method GADSMaterials.combine_layers]): the first covers
##   everything, the rest lie on top where their mask channel (R, G, B by order) puts them, or by
##   the slope and height rules below. The built-in sculpt/splat tools paint the second and third
##   layers ([member splatmap] R, G). A [member splatmap] finer than the vertex grid also drives a
##   per-texel control map (R, G, B = the second, third and fourth material's weight) that the chunks
##   and the detail field sample per fragment, so boundaries stay crisp between the vertices and all
##   three extra layers can be painted. The layers blend by height (the higher relief wins).
## - Collision: a HeightMapShape3D of the same grid.
## - Detail: a [GADSDisplacementField3D] (real displaced geometry from the layers' height maps
##   around the camera) on the terrain's own ground data, and the layers take the marks of a
##   [GADSDeformationField] in the scene (footprints, tracks; [method get_height] places
##   [GADSDeformer3D] contacts).
## - Streaming ([member stream_radius]): for terrains of kilometres, only the chunks around the
##   camera exist, built on worker threads as the camera moves, with collision per chunk and the
##   detail field's ground data in a window that follows the camera.
## - Editing ([method sculpt], [method paint_splatmap]; the inspector's Sculpt tool in the editor):
##   raise, lower, smooth and flatten the heights and paint the layers with a brush, in the editor
##   (undoable, saved into [member data_directory]) or while the game runs (craters, digging). The
##   heightmap and splat map become editable maps of one texel per vertex; only what a stroke
##   touches is rebuilt.
##
## The terrain is centred on the node, its size rounded to whole chunks. The detail field and
## deformation work in world space: keep the node unrotated and unscaled (moving it is fine; the
## ground data follows on the next rebuild).

signal rebuilt
## A streamed chunk was built and added (chunk coordinates).
signal chunk_loaded(chunk: Vector2i)
## Heights or layers changed by an edit ([method sculpt], [method paint_splatmap], a region set
## back by undo); [param rect] in grid vertices.
signal edited(rect: Rect2i)

const MAX_LAYERS := 4
## The native chunk builder (when the GADS library is loaded; else the GDScript one).
const MESHER := &"GADSTerrainMesher"
## Streamed chunks built on worker threads at once.
const MAX_STREAM_TASKS := 4

## Heights in the red channel, 0..1 over [member height_scale] (a 16-bit PNG or an EXR keeps them
## smooth). Empty: a flat terrain.
@export var heightmap: Texture2D:
	set(value):
		heightmap = value
		if not _swapping_edit_map:
			_queue_rebuild()
## Holes (cave and tunnel entrances): where the map's red channel is over 0.5, sampled at each
## vertex, the terrain has no surface. A triangle with a vertex in a hole is left out of the chunks
## (at coarser LODs also one whose middle vertex is), of the collision shape and of the near-camera
## ground data, and [method intersect_ray] passes through. The editor's Cut / Fill Holes brushes
## and [method cut_holes] edit it (one texel per vertex, saved next to the other edited maps).
@export var holes: Texture2D:
	set(value):
		holes = value
		if not _swapping_edit_map:
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
		if not _swapping_edit_map:
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

@export_group("Editing")
## Where the editor saves the terrain's edited heightmap, splat map and holes
## ([code]<scene>_<node>_height.res[/code], [code]_splat.res[/code], [code]_holes.res[/code])
## after each stroke.
@export_dir var data_directory := "res://gads_terrain"

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
var _holes := PackedByteArray() # 1 per vertex in a hole (row-major, _nx per row); empty: none
var _hole_count := 0
var _holes_texture: Texture2D # the hole map _holes was read from
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
var _control_texture: Texture2D # per-texel control map built from _splat (null = none bound)
var _control_rect := Vector4.ZERO # world->control-uv: origin.x, origin.z, 1/extent.x, 1/extent.y
var _queued := false
var _build_ms := 0.0
var _src_texture: Texture2D # the heightmap _src was read from
var _splat_texture: Texture2D # the splat map _splat was read from
var _swapping_edit_map := false
var _whole_shape: CollisionShape3D # the whole terrain's height shape (not streaming)
var _edit_dirty := Rect2i() # grid vertices whose ground data and map textures wait for flush_edits()
var _edit_maps_dirty := {}
var _edit_queued := false


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
	_rebuild_if_queued.call_deferred()


func _rebuild_if_queued() -> void:
	if _queued:
		rebuild()


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
	_src_texture = heightmap
	_splat_texture = splatmap
	_build_holes()
	_edit_dirty = Rect2i()
	_edit_maps_dirty = {}
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
	_update_control_map()
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
	_repaint_chunks(rect)
	_repaint_ground(rect)
	_update_control_map()


## Whether a per-texel control map earns its keep: only when the splat map is finer than the vertex
## grid (otherwise the per-vertex vertex colours already carry the layers crisply enough and the
## field agrees via its ground-bake codes -- so the rule / low-res-splat path stays byte-identical).
## Runtime vertex painting ([method paint_layer], [member _paint]) is an alternative authoritative
## source, so it switches the control map off and the vertex colours take over.
func _should_control_map() -> bool:
	return _paint.is_empty() and not _splat.is_empty() and _nx >= 2 \
		and (int(_splat["width"]) > _nx or int(_splat["height"]) > _nz)


## A per-texel control map from the splat map (one RGB texel per splat texel, at the splat's own
## resolution, so a splat finer than the mesh gives layer boundaries crisper than the per-vertex
## vertex colours can): R, G, B = the second, third and fourth material's weight (0..1). Sampled
## with [member _control_rect] (filter_linear in the shaders) by both the chunks' layered material
## and the detail field, so the two agree at a boundary.
func _build_control_texture() -> Texture2D:
	var w: int = _splat["width"]
	var h: int = _splat["height"]
	var data: PackedFloat32Array = _splat["data"]
	# _splat holds four floats a texel (RGBA); keep R, G, B (the three extra layers) as an RGB map.
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, data.to_byte_array())
	img.convert(Image.FORMAT_RGB8)
	return ImageTexture.create_from_image(img)


## Rebuilds and binds (or clears) the control map on the chunks' material and the detail field, so
## painting and rebuilds keep it current. Cheap when no control map is wanted (no texture is built).
func _update_control_map() -> void:
	var tex: Texture2D = null
	var rect := Vector4.ZERO
	if _should_control_map():
		tex = _build_control_texture()
		var gp := global_position if is_inside_tree() else Vector3.ZERO
		var corner := _origin + Vector2(gp.x, gp.z)
		var ext := get_extent()
		rect = Vector4(corner.x, corner.y, 1.0 / maxf(ext.x, 1e-6), 1.0 / maxf(ext.y, 1e-6))
	_control_texture = tex
	_control_rect = rect
	if _material is ShaderMaterial and GADSMaterials.parse((_material as ShaderMaterial).shader).get("layered", false):
		(_material as ShaderMaterial).set_shader_parameter("control_map", _control_texture)
		(_material as ShaderMaterial).set_shader_parameter("control_rect", _control_rect)
	if _field != null:
		_field.set_control_map(_control_texture, _control_rect)


func _repaint_chunks(rect: Rect2) -> void:
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
	var part := _ground_arrays(rect)
	if part.is_empty():
		return null
	var texel: float = part["texel"]
	var gp := _ground_offset_cache
	return GADSGroundBake.from_arrays(part["size"], part["heights"], part["codes"],
		_origin + Vector2(part["first"]) * texel - Vector2(texel, texel) * 0.5 + Vector2(gp.x, gp.z), texel)


## The ground data's texels within local [param rect] (all: empty): {"first" (the first texel's
## index on the terrain's texel grid), "size", "heights" (world), "codes", "texel"}, or {}.
func _ground_arrays(rect := Rect2()) -> Dictionary:
	if _nx < 2:
		return {}
	var extent := get_extent()
	var all := Rect2(_origin, extent)
	rect = all if not rect.has_area() else rect.intersection(all)
	var texel := get_ground_texel()
	# Snap to the texel grid (which has a texel centre on vertex (0, 0)).
	var i0 := Vector2i(((rect.position - _origin) / texel).floor())
	var i1 := Vector2i(((rect.end - _origin) / texel).ceil())
	if not rect.has_area():
		return {}
	var w := i1.x - i0.x + 1
	var d := i1.y - i0.y + 1
	if OS.get_thread_caller_id() == OS.get_main_thread_id() and is_inside_tree():
		_ground_offset_cache = global_position
	var gp := _ground_offset_cache
	if ClassDB.class_exists(MESHER) and _paint.is_empty():
		var part: Dictionary = ClassDB.class_call_static(MESHER, &"ground_arrays", _grid_state(1), i0, Vector2i(w, d), texel, gp.y, layers.size())
		part.merge({"first": i0, "size": Vector2i(w, d), "texel": texel})
		if _hole_count > 0:
			_cut_ground_holes(part)
		return part
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
	var out := {"first": i0, "size": Vector2i(w, d), "heights": heights, "codes": codes, "texel": texel}
	if _hole_count > 0:
		_cut_ground_holes(out)
	return out


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
	if ClassDB.class_exists(MESHER):
		return float(ClassDB.class_call_static(MESHER, &"ground_error", _grid_state(1), Rect2i(g0, g1 - g0), steep)) * factor
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


# --- Editing ------------------------------------------------------------------------------------

## Sculpts the heights within [param radius] metres of [param world_position] with GADSSculpt's
## brush: RAISE / LOWER by up to [param strength] metres in the middle, SMOOTH / FLATTEN by up to
## [param strength] (0..1) of the way, with a smooth falloff; FLATTEN levels to the world height
## [param flatten_to] (NAN: the height in the middle). Persistent: the heightmap becomes an
## editable map of one texel per vertex ([method make_heights_editable]). The chunks, collision,
## slope and height rules and (next frame) the detail field's ground data follow. Returns the grid
## vertices it changed. Needs [member height_scale] above 0.
func sculpt(world_position: Vector3, radius: float, mode: GADSSculpt.Mode, strength: float, flatten_to := NAN) -> Rect2i:
	if _nx < 2 or radius <= 0.0 or height_scale <= 0.0:
		return Rect2i()
	make_heights_editable()
	_wait_tasks()
	var local := to_local(world_position)
	var centre := (Vector2(local.x, local.z) - _origin) / _spacing + Vector2(0.5, 0.5)
	var amount := strength / height_scale if mode == GADSSculpt.Mode.RAISE or mode == GADSSculpt.Mode.LOWER else strength
	var target := NAN
	if not is_nan(flatten_to):
		target = (to_local(Vector3(world_position.x, flatten_to, world_position.z)).y - height_offset) / height_scale
	var rect := GADSSculpt.dab_values(_src["data"], _nx, _nz, centre, Vector2.ONE * radius / _spacing, mode, amount, target)
	_heights_changed(rect)
	return rect


## Paints [param layer] (1: the second layer, 2: the third, 0: back to the first) into the splat
## map within [param radius] metres of [param world_position], by up to [param strength] (0..1) in
## the middle with GADSSculpt's falloff. Persistent: the splat map becomes an editable map of one
## texel per vertex ([method make_splat_editable]; the slope and height rules and what
## [method paint_layer] painted are kept in it). Returns the grid vertices it changed.
func paint_splatmap(world_position: Vector3, radius: float, layer: int, strength := 1.0) -> Rect2i:
	if _nx < 2 or radius <= 0.0:
		return Rect2i()
	make_splat_editable()
	_wait_tasks()
	var local := to_local(world_position)
	var c := (Vector2(local.x, local.z) - _origin) / _spacing
	var r := radius / _spacing
	var g0 := Vector2i((c - Vector2.ONE * r).floor()).clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	var g1 := Vector2i((c + Vector2.ONE * r).ceil()).clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	var target := Vector2(1.0 if layer == 1 else 0.0, 1.0 if layer == 2 else 0.0)
	var data: PackedFloat32Array = _splat["data"]
	for gz in range(g0.y, g1.y + 1):
		for gx in range(g0.x, g1.x + 1):
			var d := (Vector2(gx, gz) - c).length() / r
			if d >= 1.0:
				continue
			var f := 1.0 - d * d
			var k := (gz * _nx + gx) * 4
			var w := Vector2(data[k], data[k + 1])
			var painted := w.lerp(target, clampf(strength, 0.0, 1.0) * f * f)
			if layer == 1:
				painted.x = maxf(painted.x, w.x)
			elif layer == 2:
				painted.y = maxf(painted.y, w.y)
			# Stored as 8 bits a channel: kept quantized, so a saved map reads back the same.
			data[k] = roundf(clampf(painted.x, 0.0, 1.0) * 255.0) / 255.0
			data[k + 1] = roundf(clampf(painted.y, 0.0, 1.0) * 255.0) / 255.0
	var rect := Rect2i(g0, g1 - g0 + Vector2i.ONE)
	_weights_changed(rect)
	return rect


## Flattens a road along [param points] (world positions, in order): within [param width] / 2 of
## the line (in XZ) the ground takes the line's height there (interpolated along it), fading back
## to its own over [param falloff] metres beyond; [param layer] >= 0 also paints that layer (1, 2;
## 0: the first) under the road, fading the same way. [param strength] (0..1): how far the heights
## move. Persistent like [method sculpt]. Returns the grid vertices it changed.
## [GADSTerrainPath3D] makes the points from a curve.
func flatten_path(points: PackedVector3Array, width: float, falloff := 2.0, layer := -1, strength := 1.0) -> Rect2i:
	if _nx < 2 or points.size() < 2 or height_scale <= 0.0 or width <= 0.0:
		return Rect2i()
	make_heights_editable()
	if layer >= 0:
		make_splat_editable()
	_wait_tasks()
	# The line in grid units, its heights as the map stores them.
	var line := PackedVector2Array()
	var ys := PackedFloat32Array()
	for p in points:
		var l := to_local(p)
		line.append((Vector2(l.x, l.z) - _origin) / _spacing)
		ys.append((l.y - height_offset) / height_scale)
	var half := width * 0.5 / _spacing
	var reach := half + maxf(falloff, 0.0) / _spacing
	var lo := Vector2(INF, INF)
	var hi := -lo
	for q in line:
		lo = lo.min(q)
		hi = hi.max(q)
	var g0 := Vector2i((lo - Vector2.ONE * reach).floor()).clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	var g1 := Vector2i((hi + Vector2.ONE * reach).ceil()).clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	var box := Rect2i(g0, g1 - g0 + Vector2i.ONE)
	if not box.has_area():
		return Rect2i()
	# Per vertex of the box: the distance to the nearest point of the line and the line's height
	# there, segment by segment over each segment's own neighbourhood.
	var best := PackedFloat32Array()
	best.resize(box.size.x * box.size.y)
	best.fill(INF)
	var target := PackedFloat32Array()
	target.resize(best.size())
	for i in line.size() - 1:
		var a := line[i]
		var ab := line[i + 1] - a
		var len2 := ab.length_squared()
		var s0 := Vector2i((a.min(line[i + 1]) - Vector2.ONE * reach).floor()).clamp(g0, g1)
		var s1 := Vector2i((a.max(line[i + 1]) + Vector2.ONE * reach).ceil()).clamp(g0, g1)
		for gz in range(s0.y, s1.y + 1):
			for gx in range(s0.x, s1.x + 1):
				var q := Vector2(gx, gz)
				var t := clampf((q - a).dot(ab) / len2, 0.0, 1.0) if len2 > 0.0 else 0.0
				var d := q.distance_to(a + ab * t)
				var k := (gz - g0.y) * box.size.x + (gx - g0.x)
				if d < best[k]:
					best[k] = d
					target[k] = lerpf(ys[i], ys[i + 1], t)
	var data: PackedFloat32Array = _src["data"]
	var splat: PackedFloat32Array = _splat["data"] if layer >= 0 else PackedFloat32Array()
	var paint := Vector2(1.0 if layer == 1 else 0.0, 1.0 if layer == 2 else 0.0)
	var amount := clampf(strength, 0.0, 1.0)
	for gz in range(g0.y, g1.y + 1):
		for gx in range(g0.x, g1.x + 1):
			var k := (gz - g0.y) * box.size.x + (gx - g0.x)
			if best[k] >= reach:
				continue
			var w := 1.0 if best[k] <= half else 1.0 - smoothstep(half, reach, best[k])
			var i := gz * _nx + gx
			data[i] = lerpf(data[i], target[k], w * amount)
			if layer >= 0:
				var c := Vector2(splat[i * 4], splat[i * 4 + 1]).lerp(paint, w)
				splat[i * 4] = roundf(clampf(c.x, 0.0, 1.0) * 255.0) / 255.0
				splat[i * 4 + 1] = roundf(clampf(c.y, 0.0, 1.0) * 255.0) / 255.0
	_heights_changed(box)
	if layer >= 0:
		_weights_changed(box)
	return box


## Erodes the heights (without the native library in GDScript, much slower): water droplets that carve gullies and fill
## valleys, then material sliding off slopes steeper than a talus angle, at the terrain's own
## scale (the vertex spacing and [member height_scale] make the slopes physical).
## [param params] as [method GADSProcedural.erode_image]; by default one droplet per two vertices
## and 20 iterations of sliding at 38 degrees. Persistent like [method sculpt]. Returns the grid
## rectangle it changed (empty: nothing).
func erode(params := {}) -> Rect2i:
	if _nx < 2 or height_scale <= 0.0:
		return Rect2i()
	return apply_heights(GADSProcedural.erode_image(get_height_image(), erosion_params(params)))


## The parameters [method erode] gives GADSProcedural.erode_image() for [param params]: the
## defaults merged with them, at the terrain's scale. With [method get_height_image] and
## [method apply_heights], erosion can run on a worker thread (the editor does without the native
## library).
func erosion_params(params := {}) -> Dictionary:
	var p := {"droplets": _nx * _nz / 2, "thermal_iterations": 20, "talus_deg": 38.0}
	p.merge(params, true)
	p["cell_m"] = _spacing
	p["height_m"] = height_scale
	return p


## Replaces all heights by [param img] (one texel per vertex, as [method get_height_image]
## gives): persistent like [method sculpt]. Returns the grid rectangle it changed (empty: none).
func apply_heights(img: Image) -> Rect2i:
	if img == null or _nx < 2:
		return Rect2i()
	set_height_region(Vector2i.ZERO, img)
	return Rect2i(0, 0, _nx, _nz)


## Replaces the heights by a generated field: a GADSProcedural kind ("noise", "ridged", "billow",
## "craters"...) with [param params] as [method GADSProcedural.height_image] ("seed", "scale" =
## features across the terrain, "octaves", "warp"...), 0..1 over [member height_scale] (without the
## native library slower, by GADSProceduralGD). Persistent like [method sculpt]. Returns the grid
## rectangle it changed.
func generate_heights(kind: String, params := {}) -> Rect2i:
	if _nx < 2:
		return Rect2i()
	var n := clampi(maxi(_nx, _nz), 4, 8192)
	var img := GADSProcedural.height_image(kind, n, params)
	if img == null:
		return Rect2i()
	set_height_region(Vector2i.ZERO, img.get_region(Rect2i(0, 0, mini(_nx, n), mini(_nz, n))))
	return Rect2i(0, 0, _nx, _nz)


## Writes the heights (one texel per vertex, 0..1 over [member height_scale], as
## [method get_height_image] has them) to [param path] as a one-channel float EXR, for other
## tools. Returns the error.
func export_heightmap(path: String) -> Error:
	var img := get_height_image()
	if img == null:
		return ERR_UNCONFIGURED
	return img.save_exr(path if path.get_extension() == "exr" else path + ".exr", true)


## Whether [member heightmap] is an editable map (an ImageTexture of one float texel per vertex).
func is_height_editable() -> bool:
	var tex := heightmap as ImageTexture
	return tex != null and _nx >= 2 and tex.get_width() == _nx and tex.get_height() == _nz and tex.get_format() == Image.FORMAT_RF


## Whether [member splatmap] is an editable map (an ImageTexture of one RG8 texel per vertex).
func is_splat_editable() -> bool:
	var tex := splatmap as ImageTexture
	return tex != null and _nx >= 2 and tex.get_width() == _nx and tex.get_height() == _nz and tex.get_format() == Image.FORMAT_RG8


## Replaces [member heightmap] by an editable map with the same heights at every vertex (0..1 over
## [member height_scale], FORMAT_RF, one texel per vertex), unless it is one.
func make_heights_editable() -> void:
	_sync_maps()
	if _nx < 2 or is_height_editable():
		return
	_wait_tasks()
	var data := PackedFloat32Array()
	data.resize(_nx * _nz)
	var inv := 1.0 / height_scale if height_scale > 0.0 else 0.0
	for i in _nx * _nz:
		data[i] = ((_heights[i] if not _heights.is_empty() else _grid_h(i % _nx, i / _nx)) - height_offset) * inv
	_src = {"width": _nx, "height": _nz, "data": data}
	_swapping_edit_map = true
	heightmap = ImageTexture.create_from_image(_height_image())
	_swapping_edit_map = false
	_src_texture = heightmap


## Replaces [member splatmap] by an editable map with the same layer weights at every vertex (R:
## the second layer, G: the third, FORMAT_RG8, one texel per vertex), unless it is one. The rules
## and the painted weights are kept in it.
func make_splat_editable() -> void:
	_sync_maps()
	if _nx < 2 or is_splat_editable():
		return
	_wait_tasks()
	var data := PackedFloat32Array()
	data.resize(_nx * _nz * 4)
	for z in _nz:
		for x in _nx:
			var w := _grid_weights(x, z)
			var k := (z * _nx + x) * 4
			data[k] = roundf(clampf(w.x, 0.0, 1.0) * 255.0) / 255.0
			data[k + 1] = roundf(clampf(w.y, 0.0, 1.0) * 255.0) / 255.0
			data[k + 3] = 1.0
	_splat = {"width": _nx, "height": _nz, "data": data}
	_paint = {}
	_paint_version += 1
	if not _w1.is_empty():
		_build_weights()
	_swapping_edit_map = true
	splatmap = ImageTexture.create_from_image(_splat_image())
	_swapping_edit_map = false
	_splat_texture = splatmap


## The editable heights (FORMAT_RF, 0..1 over [member height_scale], one texel per vertex), a copy.
func get_height_image() -> Image:
	make_heights_editable()
	return _height_image() if not _src.is_empty() else null


func _height_image() -> Image:
	return Image.create_from_data(_nx, _nz, false, Image.FORMAT_RF, (_src["data"] as PackedFloat32Array).to_byte_array())


## The editable splat map (FORMAT_RG8, one texel per vertex), a copy.
func get_splat_image() -> Image:
	make_splat_editable()
	return _splat_image() if not _splat.is_empty() else null


func _splat_image() -> Image:
	var img := Image.create_from_data(_nx, _nz, false, Image.FORMAT_RGBAF, (_splat["data"] as PackedFloat32Array).to_byte_array())
	img.convert(Image.FORMAT_RG8)
	return img


## Writes [param region] (heights as [method get_height_image] has them) into the editable
## heightmap with its top-left texel at grid vertex [param position], and updates the terrain
## there (the map's texture at once). The Sculpt tool's undo and redo.
func set_height_region(position: Vector2i, region: Image) -> void:
	make_heights_editable()
	if _src.is_empty() or region == null:
		return
	_wait_tasks()
	var img := region.duplicate() as Image
	img.convert(Image.FORMAT_RF)
	var rect: Rect2i
	if position == Vector2i.ZERO and img.get_size() == Vector2i(_nx, _nz):
		_src["data"] = img.get_data().to_float32_array()
		rect = Rect2i(0, 0, _nx, _nz)
	else:
		rect = _blit(_src["data"], 1, img.get_data().to_float32_array(), img.get_size(), position)
	_heights_changed(rect)
	flush_edits()


## Writes [param region] (FORMAT_RG8, as [method get_splat_image] has it) into the editable splat
## map at grid vertex [param position] and updates the terrain there. The Paint tool's undo and
## redo.
func set_splat_region(position: Vector2i, region: Image) -> void:
	make_splat_editable()
	if _splat.is_empty() or region == null:
		return
	_wait_tasks()
	var img := region.duplicate() as Image
	img.convert(Image.FORMAT_RGBAF)
	var rect := _blit(_splat["data"], 4, img.get_data().to_float32_array(), img.get_size(), position)
	_weights_changed(rect)
	flush_edits()


## Copies [param src] ([param size], [param channels] floats a texel) into the grid-sized
## [param dst] at [param position]; returns the grid rectangle written.
func _blit(dst: PackedFloat32Array, channels: int, src: PackedFloat32Array, size: Vector2i, position: Vector2i) -> Rect2i:
	var rect := Rect2i(position, size).intersection(Rect2i(0, 0, _nx, _nz))
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var s := ((y - position.y) * size.x + (x - position.x)) * channels
			var d := (y * _nx + x) * channels
			for c in channels:
				dst[d + c] = src[s + c]
	return rect


## Applies what edits left for later: the map textures and the detail field's ground data in the
## edited rectangle. Runs by itself once a frame after edits; call it to have them at once.
func flush_edits() -> void:
	_edit_queued = false
	if not _edit_dirty.has_area():
		return
	var rect := _edit_dirty
	_edit_dirty = Rect2i()
	if _edit_maps_dirty.get("height", false) and is_height_editable() and heightmap == _src_texture:
		(heightmap as ImageTexture).update(_height_image())
	if _edit_maps_dirty.get("splat", false) and is_splat_editable() and splatmap == _splat_texture:
		(splatmap as ImageTexture).update(_splat_image())
	if _edit_maps_dirty.get("holes", false) and is_holes_editable() and holes == _holes_texture:
		(holes as ImageTexture).update(_hole_image())
	_edit_maps_dirty = {}
	_update_ground_region(rect)


## Saves the edited heightmap and splat map into [member data_directory] (or where they were saved
## before), so the scene refers to the files. Editor only; the Sculpt tool calls it after each
## stroke and after undo and redo.
func save_edited_maps() -> void:
	if not Engine.is_editor_hint():
		return
	flush_edits()
	for entry in [["heightmap", "height", is_height_editable()], ["splatmap", "splat", is_splat_editable()], ["holes", "holes", is_holes_editable()]]:
		var tex := get(entry[0]) as ImageTexture
		if tex == null or not entry[2]:
			continue
		var path := tex.resource_path
		if path.is_empty() or path.contains("::"):
			path = data_directory.path_join("%s_%s.res" % [_edit_stem(), entry[1]])
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
		if ResourceSaver.save(tex, path) != OK:
			push_warning("GADS: %s: cannot save %s." % [name, path])
			continue
		tex.take_over_path(path)
		if Engine.has_singleton("EditorInterface"):
			var fs: Object = Engine.get_singleton("EditorInterface").call("get_resource_filesystem")
			fs.call("update_file", path)


func _edit_stem() -> String:
	var scene := owner.scene_file_path if owner != null else scene_file_path
	var stem := scene.get_file().get_basename()
	stem = (stem + "_" if not stem.is_empty() else "") + String(name).to_snake_case()
	return stem.validate_filename().replace(" ", "_")


## Where the ray from [param origin] along [param direction] (world space) first comes down onto
## the terrain's surface (its finest LOD), or Vector3.INF. Steps along the grid at half the vertex
## spacing within the terrain's bounds, then bisects to about a millimetre. The Sculpt tool picks
## with it; a game can too (no physics needed). It passes through [member holes] unless
## [param through_holes] is off.
func intersect_ray(origin: Vector3, direction: Vector3, max_distance := 1e6, through_holes := true) -> Vector3:
	if _nx < 2 or direction.is_zero_approx():
		return Vector3.INF
	var o := to_local(origin)
	var d := (global_basis.inverse() * direction.normalized())
	var scale := d.length()
	d /= scale
	var t_max := max_distance * scale
	var lo := Vector3(_origin.x, 0.0, _origin.y)
	var hi := Vector3(_origin.x + get_extent().x, 0.0, _origin.y + get_extent().y)
	# The ray's span over the terrain's rectangle (slabs in x and z).
	var t0 := 0.0
	var t1 := t_max
	for a in [0, 2]:
		if absf(d[a]) < 1e-12:
			if o[a] < lo[a] or o[a] > hi[a]:
				return Vector3.INF
			continue
		var ta := (lo[a] - o[a]) / d[a]
		var tb := (hi[a] - o[a]) / d[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t0 > t1:
		return Vector3.INF
	var above := func(t: float) -> float:
		var p := o + d * t
		var h := _height_local(Vector2(p.x, p.z))
		return p.y - h if not is_nan(h) else 1.0
	var step := _spacing * 0.5
	var prev_t := t0
	var prev_f: float = above.call(t0)
	var t := t0
	while t < t1:
		t = minf(t + step, t1)
		var f: float = above.call(t)
		if f <= 0.0 and prev_f > 0.0:
			var a := prev_t
			var b := t
			for i in 30:
				var m := (a + b) * 0.5
				if above.call(m) > 0.0:
					a = m
				else:
					b = m
				if b - a < 1e-4:
					break
			var hit := o + d * b
			if not through_holes or not _is_hole_local(Vector2(hit.x, hit.z)):
				return to_global(hit)
		prev_t = t
		prev_f = f
	return Vector3.INF


## Reads the maps again if a property set them since (undo and redo swap them).
func _sync_maps() -> void:
	if _nx >= 2 and (heightmap != _src_texture or splatmap != _splat_texture or holes != _holes_texture):
		rebuild()


## After the heights of grid [param rect] changed in _src: the height array, the rules' weights,
## the chunks, collision; the ground data and the texture with the next flush.
func _heights_changed(rect: Rect2i) -> void:
	if not rect.has_area():
		return
	var data: PackedFloat32Array = _src["data"]
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if not _heights.is_empty():
				_heights[z * _nx + x] = height_offset + height_scale * data[z * _nx + x]
	# Normals, so the rules' weights, change a vertex around the edit too.
	var grown := rect.grow(1).intersection(Rect2i(0, 0, _nx, _nz))
	if _splat.is_empty() and not _w1.is_empty():
		for z in range(grown.position.y, grown.end.y):
			for x in range(grown.position.x, grown.end.x):
				var w := _compute_weights(x, z)
				_w1[z * _nx + x] = w.x
				_w2[z * _nx + x] = w.y
	_rebuild_chunks(grown)
	if _whole_shape != null and is_instance_valid(_whole_shape) and not _heights.is_empty():
		var shape := _whole_shape.shape as HeightMapShape3D
		var map := shape.map_data
		for z in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				map[z * _nx + x] = _heights[z * _nx + x] / _spacing
		shape.map_data = map
	_queue_edit_flush(grown, "height")


## After the splat weights of grid [param rect] changed in _splat.
func _weights_changed(rect: Rect2i) -> void:
	if not rect.has_area():
		return
	if not _w1.is_empty():
		_build_weights_rect(rect)
	_paint_version += 1
	var local := Rect2(_origin + Vector2(rect.position) * _spacing, Vector2(rect.size - Vector2i.ONE) * _spacing)
	_repaint_chunks(local)
	_update_control_map()
	_queue_edit_flush(rect, "splat")


func _build_weights_rect(rect: Rect2i) -> void:
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var w := _compute_weights(x, z)
			_w1[z * _nx + x] = w.x
			_w2[z * _nx + x] = w.y


func _queue_edit_flush(rect: Rect2i, map: String) -> void:
	_edit_dirty = rect if not _edit_dirty.has_area() else _edit_dirty.merge(rect)
	_edit_maps_dirty[map] = true
	edited.emit(rect)
	if not _edit_queued:
		_edit_queued = true
		flush_edits.call_deferred()


## Rebuilds the built chunks that grid [param rect] touches (meshes, occluders, streamed chunks'
## collision).
func _rebuild_chunks(rect: Rect2i) -> void:
	var cq := chunk_quads
	var levels := _levels()
	for key: Vector2i in _chunk_nodes.keys():
		var r := Rect2i(key * cq, Vector2i(cq + 1, cq + 1))
		if not r.intersects(rect):
			continue
		var data := _chunk_arrays(key.x, key.y, levels)
		var mi: MeshInstance3D = _chunk_nodes[key]
		var mesh := mi.mesh as ArrayMesh
		mesh.clear_surfaces()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data["arrays"], [], data["lods"])
		_chunk_data[key] = data
		_set_occluder(mi, data)
		if _shapes.has(key):
			var old := _shapes[key] as Node
			_body.remove_child(old)
			old.queue_free()
			_shapes.erase(key)
			_add_chunk_shape(key, data)


## The detail field's ground data within grid [param rect]: rewritten in place, or made again when
## the edit left the range its heights are stored in; a streamed terrain's window is made again.
func _update_ground_region(rect: Rect2i) -> void:
	if _field == null:
		return
	if is_streaming():
		_window_center = Vector2.INF
		return
	var bake := _field.ground_bake
	if bake == null:
		return
	var local := Rect2(_origin + Vector2(rect.position) * _spacing, Vector2(rect.size - Vector2i.ONE) * _spacing).grow(_spacing)
	var part := _ground_arrays(local)
	if part.is_empty():
		return
	var heights: PackedFloat32Array = part["heights"]
	var codes: PackedInt32Array = part["codes"]
	var size: Vector2i = part["size"]
	var first: Vector2i = part["first"]
	var fits := true
	for h in heights:
		if h < bake.height_min or h > bake.height_min + bake.height_range:
			fits = false
			break
	_field.lift = maxf(_field.lift, clampf(ground_data_error(local) + 0.002, 0.002, 0.1))
	if not fits:
		_field.ground_bake = make_ground_bake()
		return
	var bake_size := bake.get_size()
	for y in size.y:
		for x in size.x:
			var t := first + Vector2i(x, y)
			if t.x < 0 or t.y < 0 or t.x >= bake_size.x or t.y >= bake_size.y:
				continue
			bake.data.set_pixel(t.x, t.y, bake.encode(heights[y * size.x + x], codes[y * size.x + x]))
	_field.ground_bake = bake # uploads it again


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
	if ClassDB.class_exists(MESHER):
		_heights = PackedFloat32Array()
		_heights = ClassDB.class_call_static(MESHER, &"grid_heights", _grid_state(1))
		return
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
	if ClassDB.class_exists(MESHER):
		var w: Dictionary = ClassDB.class_call_static(MESHER, &"grid_weights", _grid_state(1))
		_w1 = w["w1"]
		_w2 = w["w2"]
		return
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
## collision)} (and "occluder"). Natively when the library is loaded (the same arrays as
## [method _chunk_arrays_gd], about thirty times faster). Reads no node: runs on worker threads
## while streaming.
func _chunk_arrays(cx: int, cz: int, levels: int) -> Dictionary:
	var out: Dictionary
	if not ClassDB.class_exists(MESHER):
		out = _chunk_arrays_gd(cx, cz, levels)
	else:
		out = ClassDB.class_call_static(MESHER, &"build_chunk", _grid_state(levels), cx, cz)
		if not _paint.is_empty():
			_paint_chunk_colors(out, cx, cz)
	if _hole_count > 0 and _chunk_has_holes(cx, cz):
		_cut_chunk_holes(out, cx, cz)
	return out


# --- Holes --------------------------------------------------------------------------------------

func _build_holes() -> void:
	_holes_texture = holes
	_holes = PackedByteArray()
	_hole_count = 0
	if holes == null or _nx < 2:
		return
	var img := holes.get_image()
	if img == null or img.is_empty():
		return
	img = img.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_L8)
	if img.get_size() != Vector2i(_nx, _nz):
		img.resize(_nx, _nz, Image.INTERPOLATE_NEAREST)
	_holes = img.get_data()
	for i in _holes.size():
		var h := 1 if _holes[i] > 127 else 0
		_holes[i] = h
		_hole_count += h


func _hole_at(gx: int, gz: int) -> bool:
	return _hole_count > 0 and _holes[clampi(gz, 0, _nz - 1) * _nx + clampi(gx, 0, _nx - 1)] != 0


func _chunk_has_holes(cx: int, cz: int) -> bool:
	var cq := chunk_quads
	for z in range(cz * cq, cz * cq + cq + 1):
		for x in range(cx * cq, cx * cq + cq + 1):
			if _holes[z * _nx + x] != 0:
				return true
	return false


## Leaves out of a built chunk the triangles of its LODs and skirts that touch a hole, and its
## occluder (it would hide what lies below the holes).
func _cut_chunk_holes(out: Dictionary, cx: int, cz: int) -> void:
	var ring := _ring(chunk_quads)
	var arrays: Array = out["arrays"]
	arrays[Mesh.ARRAY_INDEX] = _cut_indices(arrays[Mesh.ARRAY_INDEX], cx, cz, 1, ring)
	var keys: Array = (out["lods"] as Dictionary).keys()
	keys.sort()
	var lods := {}
	for k in keys.size():
		lods[keys[k]] = _cut_indices(out["lods"][keys[k]], cx, cz, 2 << k, ring)
	out["lods"] = lods
	out.erase("occluder")


func _cut_indices(idx: PackedInt32Array, cx: int, cz: int, s: int, ring: Array[Vector2i]) -> PackedInt32Array:
	var cq := chunk_quads
	var n := cq + 1
	var g0 := Vector2i(cx * cq, cz * cq)
	var kept := PackedInt32Array()
	kept.resize(idx.size())
	var count := 0
	for t in range(0, idx.size(), 3):
		var hole := false
		var sum := Vector2i.ZERO
		for k in 3:
			var v := idx[t + k]
			# A skirt vertex hangs from a border vertex: the border vertex decides.
			var g := Vector2i(v % n, v / n) if v < n * n else ring[v - n * n]
			sum += g
			hole = hole or _holes[(g0.y + g.y) * _nx + g0.x + g.x] != 0
		if not hole and s > 1:
			var c := Vector2i(roundi(sum.x / 3.0), roundi(sum.y / 3.0))
			hole = _holes[(g0.y + c.y) * _nx + g0.x + c.x] != 0
		if not hole:
			kept[count] = idx[t]
			kept[count + 1] = idx[t + 1]
			kept[count + 2] = idx[t + 2]
			count += 3
	kept.resize(count)
	return kept


## Whether [param world_position] (its XZ) lies in a hole: on a triangle the chunks leave out at
## their finest LOD.
func is_hole(world_position: Vector3) -> bool:
	if _hole_count == 0:
		return false
	var local := to_local(world_position)
	return _is_hole_local(Vector2(local.x, local.z))


func _is_hole_local(p: Vector2) -> bool:
	if _hole_count == 0:
		return false
	var g := (p - _origin) / _spacing
	if g.x < 0.0 or g.y < 0.0 or g.x > _nx - 1 or g.y > _nz - 1:
		return false
	var x0 := mini(floori(g.x), _nx - 2)
	var z0 := mini(floori(g.y), _nz - 2)
	var fx := g.x - x0
	var fz := g.y - z0
	# The quad's diagonal runs from (x0 + 1, z0) to (x0, z0 + 1), as the chunks triangulate it.
	if fx + fz <= 1.0:
		return _hole_at(x0, z0) or _hole_at(x0 + 1, z0) or _hole_at(x0, z0 + 1)
	return _hole_at(x0 + 1, z0 + 1) or _hole_at(x0 + 1, z0) or _hole_at(x0, z0 + 1)


## Cuts holes (or with [param fill], closes them) within [param radius] metres of
## [param world_position]: every vertex within the radius. Persistent: the hole map becomes an
## editable map of one texel per vertex ([method make_holes_editable]). Returns the grid vertices
## it changed.
func cut_holes(world_position: Vector3, radius: float, fill := false) -> Rect2i:
	if _nx < 2 or radius <= 0.0:
		return Rect2i()
	make_holes_editable()
	_wait_tasks()
	var local := to_local(world_position)
	var c := (Vector2(local.x, local.z) - _origin) / _spacing
	var r := radius / _spacing
	var g0 := Vector2i((c - Vector2.ONE * r).floor()).clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	var g1 := Vector2i((c + Vector2.ONE * r).ceil()).clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	var value := 0 if fill else 1
	for gz in range(g0.y, g1.y + 1):
		for gx in range(g0.x, g1.x + 1):
			if (Vector2(gx, gz) - c).length() <= r:
				_holes[gz * _nx + gx] = value
	var rect := Rect2i(g0, g1 - g0 + Vector2i.ONE)
	_holes_changed(rect)
	return rect


## Whether [member holes] is an editable map (an ImageTexture of one L8 texel per vertex).
func is_holes_editable() -> bool:
	var tex := holes as ImageTexture
	return tex != null and _nx >= 2 and tex.get_width() == _nx and tex.get_height() == _nz and tex.get_format() == Image.FORMAT_L8


## Replaces [member holes] by an editable map with the same holes at every vertex (255: a hole,
## FORMAT_L8, one texel per vertex), unless it is one.
func make_holes_editable() -> void:
	_sync_maps()
	if _nx < 2 or is_holes_editable():
		return
	_wait_tasks()
	if _holes.is_empty():
		_holes.resize(_nx * _nz)
		_holes.fill(0)
	_swapping_edit_map = true
	holes = ImageTexture.create_from_image(_hole_image())
	_swapping_edit_map = false
	_holes_texture = holes


## The editable hole map (FORMAT_L8, 255 where a vertex is in a hole, one texel per vertex), a copy.
func get_hole_image() -> Image:
	make_holes_editable()
	return _hole_image()


func _hole_image() -> Image:
	var data := _holes.duplicate()
	for i in data.size():
		data[i] = 255 if data[i] != 0 else 0
	return Image.create_from_data(_nx, _nz, false, Image.FORMAT_L8, data)


## Writes [param region] (as [method get_hole_image] has it) into the editable hole map at grid
## vertex [param position] and updates the terrain there. The hole brushes' undo and redo.
func set_hole_region(position: Vector2i, region: Image) -> void:
	make_holes_editable()
	if region == null:
		return
	_wait_tasks()
	var img := region.duplicate() as Image
	img.convert(Image.FORMAT_L8)
	var data := img.get_data()
	var rect := Rect2i(position, img.get_size()).intersection(Rect2i(0, 0, _nx, _nz))
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			_holes[y * _nx + x] = 1 if data[(y - position.y) * img.get_width() + (x - position.x)] > 127 else 0
	_holes_changed(rect)
	flush_edits()


## After the holes of grid [param rect] changed in _holes: the chunks, collision; the ground data
## and the texture with the next flush.
func _holes_changed(rect: Rect2i) -> void:
	if not rect.has_area():
		return
	_hole_count = _holes.size() - _holes.count(0)
	var grown := rect.grow(1).intersection(Rect2i(0, 0, _nx, _nz))
	_rebuild_chunks(grown)
	# Collision: one height shape without holes, a shape per chunk with them (see _build_collision).
	var whole := _whole_shape != null and is_instance_valid(_whole_shape)
	if not is_streaming() and _body != null and whole == (_hole_count > 0):
		_build_collision()
	_queue_edit_flush(grown, "holes")


## The ground data's texels that lie on a hole get no ground (code -2): the near-camera field
## dives under them as at the end of the ground.
func _cut_ground_holes(part: Dictionary) -> void:
	var texel: float = part["texel"]
	var first: Vector2i = part["first"]
	var size: Vector2i = part["size"]
	var codes: PackedInt32Array = part["codes"]
	var lo := Vector2i(((Vector2(first) * texel) / _spacing).floor()) - Vector2i.ONE
	var hi := Vector2i(((Vector2(first + size) * texel) / _spacing).ceil()) + Vector2i.ONE
	lo = lo.clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	hi = hi.clamp(Vector2i.ZERO, Vector2i(_nx - 1, _nz - 1))
	for gz in range(lo.y, hi.y + 1):
		for gx in range(lo.x, hi.x + 1):
			if _holes[gz * _nx + gx] == 0:
				continue
			# Every texel in the quads around the vertex.
			var t0 := Vector2i(((Vector2(gx - 1, gz - 1) * _spacing) / texel).floor()) - first
			var t1 := Vector2i(((Vector2(gx + 1, gz + 1) * _spacing) / texel).ceil()) - first
			for tz in range(maxi(t0.y, 0), mini(t1.y, size.y - 1) + 1):
				for tx in range(maxi(t0.x, 0), mini(t1.x, size.x - 1) + 1):
					codes[tz * size.x + tx] = -2
	part["codes"] = codes


## What the native chunk builder needs of the grid: the heights (the whole terrain's, or the
## heightmap's to sample) and the weights (per vertex, the splat map or the rules).
func _grid_state(levels: int) -> Dictionary:
	var g := {"nx": _nx, "nz": _nz, "spacing": _spacing, "origin": _origin, "cq": chunk_quads, "levels": levels,
		"occluder_quads": occluder_quads if occluders else 0, "height_offset": height_offset, "height_scale": height_scale,
		"slope_layer": slope_layer, "slope_range": slope_range, "height_layer": height_layer, "height_band": height_band}
	if not _heights.is_empty():
		g["heights"] = _heights
	elif not _src.is_empty():
		g["src"] = _src["data"]
		g["src_w"] = _src["width"]
		g["src_h"] = _src["height"]
	if not _w1.is_empty():
		g["w1"] = _w1
		g["w2"] = _w2
	elif not _splat.is_empty():
		g["splat"] = _splat["data"]
		g["splat_w"] = _splat["width"]
		g["splat_h"] = _splat["height"]
	return g


## The painted weights (paint_layer()) on a natively built chunk's vertex colours.
func _paint_chunk_colors(out: Dictionary, cx: int, cz: int) -> void:
	var cq := chunk_quads
	var n := cq + 1
	var arrays: Array = out["arrays"]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var paint := _paint
	for z in n:
		for x in n:
			var painted: Variant = paint.get((cz * cq + z) * _nx + cx * cq + x)
			if painted != null:
				colors[z * n + x] = Color(painted.x, painted.y, 0.0, 1.0)
	var ring := _ring(cq)
	for i in ring.size():
		colors[n * n + i] = colors[ring[i].y * n + ring[i].x]
	arrays[Mesh.ARRAY_COLOR] = colors


## [method _chunk_arrays] in GDScript (without the native library).
func _chunk_arrays_gd(cx: int, cz: int, levels: int) -> Dictionary:
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
	_set_occluder(mi, data)
	_chunks.append(mi)
	_chunk_nodes[key] = mi
	_chunk_data[key] = data
	if is_streaming() and _body != null:
		_add_chunk_shape(key, data)


## Gives chunk [param mi] the occluder of its [param data], or none (a chunk with holes has none).
func _set_occluder(mi: MeshInstance3D, data: Dictionary) -> void:
	var oi: OccluderInstance3D
	for child in mi.get_children(true):
		if child is OccluderInstance3D:
			oi = child
	if not data.has("occluder"):
		if oi != null:
			oi.queue_free()
		return
	if oi == null:
		oi = OccluderInstance3D.new()
		oi.name = "Occluder"
		oi.occluder = ArrayOccluder3D.new()
		mi.add_child(oi, false, Node.INTERNAL_MODE_BACK)
	(oi.occluder as ArrayOccluder3D).set_arrays(data["occluder"]["vertices"], data["occluder"]["indices"])


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
	_shapes.clear()
	_whole_shape = null
	if is_streaming():
		return # one shape per streamed chunk, as it loads
	if _hole_count > 0:
		# Holes: a shape per chunk, the chunks with holes as their triangles.
		for key: Vector2i in _chunk_data:
			_add_chunk_shape(key, _chunk_data[key])
		return
	# A HeightMapShape3D has one unit between samples and is centred: scale it by the spacing
	# (uniformly, with the heights divided by it), offset to the grid's centre.
	var data := PackedFloat32Array()
	data.resize(_heights.size())
	for i in _heights.size():
		data[i] = _heights[i] / _spacing
	_whole_shape = _height_shape(_nx, _nz, data, _origin + Vector2(_nx - 1, _nz - 1) * _spacing * 0.5)
	_body.add_child(_whole_shape)


func _height_shape(w: int, d: int, data: PackedFloat32Array, centre: Vector2) -> CollisionShape3D:
	var shape := HeightMapShape3D.new()
	shape.map_width = w
	shape.map_depth = d
	shape.map_data = data
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = Transform3D(Basis.from_scale(Vector3.ONE * _spacing), Vector3(centre.x, 0.0, centre.y))
	return cs


func _add_chunk_shape(key: Vector2i, chunk: Dictionary) -> void:
	var cs := _chunk_shape(key, chunk)
	cs.name = "Chunk_%d_%d" % [key.x, key.y]
	_body.add_child(cs)
	_shapes[key] = cs


## A chunk's collision shape: its heights (a HeightMapShape3D), or, with holes in it, its finest
## triangles the holes leave (a trimesh; a height shape cannot have holes but by NaN heights, which
## Godot's own physics warns about on every ray).
func _chunk_shape(key: Vector2i, chunk: Dictionary) -> CollisionShape3D:
	var n := chunk_quads + 1
	if _hole_count > 0 and _chunk_has_holes(key.x, key.y):
		var verts: PackedVector3Array = chunk["arrays"][Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = chunk["arrays"][Mesh.ARRAY_INDEX]
		var faces := PackedVector3Array()
		for t in range(0, idx.size(), 3):
			if idx[t] < n * n and idx[t + 1] < n * n and idx[t + 2] < n * n: # not the skirts
				faces.append_array([verts[idx[t]], verts[idx[t + 1]], verts[idx[t + 2]]])
		var trimesh := ConcavePolygonShape3D.new()
		trimesh.set_faces(faces)
		var cs := CollisionShape3D.new()
		cs.shape = trimesh
		return cs
	var heights: PackedFloat32Array = chunk["heights"]
	var data := PackedFloat32Array()
	data.resize(heights.size())
	for i in heights.size():
		data[i] = heights[i] / _spacing
	return _height_shape(n, n, data, _chunk_rect(key).get_center())


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
