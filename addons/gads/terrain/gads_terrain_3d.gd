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
			if value != null:
				_leave_sparse() # a whole heightmap overrides region-file-backed residency
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
			if value != null:
				_leave_sparse()
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

@export_group("Regions")
## The side (m) of one region of the sparse region grid the terrain's maps are partitioned into
## (Stage 3a). Rounded up to a whole number of chunks (so it stays aligned to the chunk grid and
## is a power-of-two multiple of the chunk size when it starts as one), at least one chunk. The
## default (1024 m) is far larger than a typical demo terrain, so such a terrain is a single
## region and the maps are stored and read exactly as before; a terrain wider than this tiles into
## a [method get_region_grid] grid of regions, the last on each axis partial. The grid is the
## foundation a 16k world needs: it addresses each region by an integer [Vector2i] coordinate (not
## assumed to start at the origin) so later stages can load and free regions by distance and save
## them one file at a time. It changes no geometry, collision or rendering: every region stays
## resident here.
@export_range(16.0, 16384.0, 1.0, "or_greater", "suffix:m") var region_size := 1024.0:
	set(value):
		region_size = maxf(value, 1.0)
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
# The sparse region store (Stage 3a). The terrain's maps -- the heightmap source (_src), the splat
# source (_splat), the holes and the per-vertex caches (_heights/_w1/_w2) -- are partitioned into a
# grid of fixed-size regions keyed by integer coordinate, each region holding its own slice of each
# map. This is the per-region SOURCE OF TRUTH that Stages 3b (load/free by distance) and 3c (save
# per region) build on. While every region is resident (all of Stage 3a) the flat arrays above stay
# as the hot-path view: the whole terrain's map coalesced for the chunk builder, the native mesher,
# the collision shape and the editing tools, which read and write it exactly as before. _region_sync
# re-partitions the store from that view after every change, so the two never diverge; in the common
# single-region case the store simply references the same arrays (no copy, byte-identical).
var _regions := {} # Vector2i -> { map_name: PackedFloat32Array / PackedByteArray slice }
var _region_dims := {} # map_name -> {"w", "h", "ch"} of the whole (coalesced) map
var _region_quads := 0 # a region's side in quads on the finest grid (a whole number of chunks)
var _region_cols := 1
var _region_rows := 1
# Sparse DATA residency (Stage 4a). A terrain whose source is per-region files (loaded by
# load_regions) and that streams keeps only the regions near the camera in memory: _regions then
# holds just the RESIDENT tiles (loaded from region_<x>_<y>.res, freed when the camera leaves),
# not every region, so a 16k world costs a bounded handful of region tiles rather than the whole
# ~1 GB map. The whole-texture import and every non-streaming terrain keep the Stage 3a behaviour
# (all regions resident, the flat arrays as the hot-path view) unchanged: _sparse is false for them
# and the accessors fall back to _src/_heights/_splat exactly as before.
var _sparse := false # region-file-backed data residency is active (see _sparse_active)
var _region_dir := "" # where the region_<x>_<y>.res files live (sparse source)
var _region_files := {} # Vector2i -> true: a region that has a file on disk (available to load)
var _region_loads := {} # Vector2i -> file path of a region load in progress (ResourceLoader threaded)
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
	if _sparse_active():
		# Region-file-backed streaming: the store is residency-managed (filled and freed by distance
		# in _process), not derived from the flat maps -- which are empty here. Start from nothing so
		# the near regions load afresh; _region_dims/_region_files set by load_regions stay.
		_regions.clear()
	else:
		_region_sync() # partition the freshly read maps into the region store
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


## Whether sparse region-DATA residency (Stage 4a) is in effect: the terrain is backed by per-region
## files [method load_regions] loaded, and it streams. Only then do [member _regions], the grid
## accessors and the chunk builder work from resident region tiles instead of the whole maps; a
## whole-texture terrain or a non-streaming one keeps every map resident and this is false.
func _sparse_active() -> bool:
	return _sparse and is_streaming()


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


## Regions per side (x, z) of the sparse region grid the maps are partitioned into (see
## [member region_size]); at least 1 x 1. The last region on each axis may be partial.
func get_region_grid() -> Vector2i:
	return Vector2i(_region_cols, _region_rows)


## The integer coordinates of the regions whose map tiles are currently resident in memory. With
## sparse residency (Stage 4a: a region-file-backed streaming terrain) this is only the regions near
## the camera -- far regions' tiles are freed and reloaded on approach, so the set stays a bounded
## handful however large the world is. For a whole-texture or non-streaming terrain every region is
## resident, so it is the whole grid.
func get_resident_regions() -> Array:
	return _regions.keys()


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
	return not _pending.is_empty() or not _region_loads.is_empty() or _window_task >= 0


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
func make_ground_bake(rect := Rect2(), store := {}) -> GADSGroundBake:
	var part := _ground_arrays(rect, store)
	if part.is_empty():
		return null
	var texel: float = part["texel"]
	var gp := _ground_offset_cache
	return GADSGroundBake.from_arrays(part["size"], part["heights"], part["codes"],
		_origin + Vector2(part["first"]) * texel - Vector2(texel, texel) * 0.5 + Vector2(gp.x, gp.z), texel)


## The ground data's texels within local [param rect] (all: empty): {"first" (the first texel's
## index on the terrain's texel grid), "size", "heights" (world), "codes", "texel"}, or {}. Sparse
## ([param store] a resident-tile snapshot) takes the GDScript path reading those tiles.
func _ground_arrays(rect := Rect2(), store := {}) -> Dictionary:
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
	var holed := _hole_count > 0 if store.is_empty() else _region_dims.has("holes")
	if ClassDB.class_exists(MESHER) and _paint.is_empty() and store.is_empty():
		var part: Dictionary = ClassDB.class_call_static(MESHER, &"ground_arrays", _grid_state(1), i0, Vector2i(w, d), texel, gp.y, layers.size())
		part.merge({"first": i0, "size": Vector2i(w, d), "texel": texel})
		if holed:
			_cut_ground_holes(part, store)
		return part
	var heights := PackedFloat32Array()
	heights.resize(w * d)
	var codes := PackedInt32Array()
	codes.resize(w * d)
	for z in d:
		for x in w:
			var p := _origin + Vector2(i0.x + x, i0.y + z) * texel
			var i := z * w + x
			heights[i] = _height_local(p.clamp(_origin, _origin + extent), store) + gp.y
			var g := ((p - _origin) / _spacing).clamp(Vector2.ZERO, Vector2(_nx - 1, _nz - 1))
			var wts := _weights_at(g, store)
			var layer := 2 if wts.y >= 0.5 else (1 if wts.x >= 0.5 else 0)
			codes[i] = layer if layer < layers.size() else -1
	var out := {"first": i0, "size": Vector2i(w, d), "heights": heights, "codes": codes, "texel": texel}
	if holed:
		_cut_ground_holes(out, store)
	return out


## How far the field's bilinear heights can fall from the triangles on ground it displaces (m):
## a texel cell that a quad's diagonal crosses differs by up to a quarter of the quad's crease
## (h00 + h11 - h10 - h01) times the texel over the spacing, halved; quads steeper than the
## field's step limit are left out (the field does not displace them). [param rect]: the local XZ
## part to look at (empty: all).
func ground_data_error(rect := Rect2(), store := {}) -> float:
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
	if ClassDB.class_exists(MESHER) and store.is_empty():
		return float(ClassDB.class_call_static(MESHER, &"ground_error", _grid_state(1), Rect2i(g0, g1 - g0), steep)) * factor
	var worst := 0.0
	for z in range(g0.y, g1.y):
		for x in range(g0.x, g1.x):
			var h00 := _grid_h(x, z, store)
			var h10 := _grid_h(x + 1, z, store)
			var h01 := _grid_h(x, z + 1, store)
			var h11 := _grid_h(x + 1, z + 1, store)
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
	_region_sync() # _src is now an editable per-vertex map: re-partition it into the store


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
	_region_sync() # _splat (and the weight caches) rebuilt: re-partition into the store


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


# --- Per-region persistence (Stage 3b) ----------------------------------------------------------
# A whole-texture terrain is one file; a 16k world cannot be. These two methods save the terrain's
# editable maps (height, splat, holes) one file per region and load them back, so Stage 4 can keep
# only the near regions on disk-backed storage and free the far ones. They are ADDITIONAL to the
# whole-texture import and save_edited_maps()/flush_edits() -- those paths are untouched -- and in
# 3b every region still stays resident and building is unchanged: save writes the region store, load
# reassembles the whole maps through _region_coalesce() (the exact inverse of the split) so a terrain
# loaded from region files is byte-identical to the same terrain imported from a whole map. Only
# the SOURCE maps are persisted; the per-vertex caches (_heights/_w1/_w2) are derived on the next
# rebuild, exactly as they are for a whole import.

## Saves each region's slice of the editable maps that exist (height, splat, holes) to its own
## resource under [param dir] ([code]region_<x>_<y>.res[/code], a [GADSTerrainRegion]), with enough
## header to reconstruct the terrain's grid and put each tile back. A set of these files is the
## per-region form of [method save_edited_maps]'s whole-map files; [method load_regions] reads them
## back. Works at runtime and in the editor (unlike [method save_edited_maps], which also rewrites
## the scene's resource references). Returns [constant OK], or the first save error. Writes nothing
## and returns [constant OK] for a terrain with no maps (nothing to persist).
func save_regions(dir := data_directory) -> Error:
	flush_edits() # fold any pending stroke into the maps before the store is read
	if _regions.is_empty():
		return OK
	var abs_dir := ProjectSettings.globalize_path(dir)
	if DirAccess.make_dir_recursive_absolute(abs_dir) != OK and not DirAccess.dir_exists_absolute(abs_dir):
		push_warning("GADS: %s: cannot create %s." % [name, dir])
		return ERR_CANT_CREATE
	var first_error := OK
	for coord: Vector2i in _regions:
		var region := GADSTerrainRegion.new()
		region.coord = coord
		region.region_grid = Vector2i(_region_cols, _region_rows)
		region.region_size = region_size
		region.terrain_size = Vector2(_nx - 1, _nz - 1) * _spacing
		region.vertex_spacing = _spacing
		region.chunk_quads = chunk_quads
		# Each map's WHOLE dimensions (what the split used) plus this region's tile; a map that does
		# not exist leaves its dims zero and its tile empty.
		if _region_dims.has("height"):
			region.height_dims = _dims_vec("height")
			region.height_tile = _region_slice(coord, "height")
		if _region_dims.has("splat"):
			region.splat_dims = _dims_vec("splat")
			region.splat_tile = _region_slice(coord, "splat")
		if _region_dims.has("holes"):
			region.holes_dims = _dims_vec("holes")
			region.holes_tile = _region_slice(coord, "holes")
		var path := dir.path_join("region_%d_%d.res" % [coord.x, coord.y])
		var err := ResourceSaver.save(region, path)
		if err != OK:
			push_warning("GADS: %s: cannot save %s." % [name, path])
			if first_error == OK:
				first_error = err
	return first_error


## Reconstructs the terrain's maps from the [code]region_*.res[/code] files under [param dir]
## (written by [method save_regions]): restores the grid from their header, reassembles the whole
## height, splat and hole maps from the per-region tiles (through [method _region_coalesce]), binds
## them as the terrain's maps and rebuilds. The result is byte-identical to the same terrain imported
## from a whole heightmap / splat. Returns false (and changes nothing) if [param dir] holds no region
## files. The terrain's own configuration that is not part of the maps (height scale and offset, the
## layer materials) is left as it is -- only the grid geometry and the maps come from the files.
func load_regions(dir := data_directory) -> bool:
	# Read only ONE file for the header (geometry and map dimensions); the tiles stay on disk until
	# needed. A 16k world has thousands of files -- loading them all here to read a header would be
	# the very cost the region system exists to avoid.
	var files := _list_region_files(dir)
	if files.is_empty():
		return false
	var header := ResourceLoader.load(dir.path_join(files[0]), "", ResourceLoader.CACHE_MODE_IGNORE) as GADSTerrainRegion
	if header == null:
		return false
	# Restore the grid from the header (any file carries it; they all agree), so _setup_grid()
	# reproduces _nx/_nz/_spacing/_origin and the region split, then the tiles land where they came
	# from. The setters queue a deferred rebuild, which our explicit rebuild() below makes a no-op.
	size = header.terrain_size
	chunk_quads = header.chunk_quads
	region_size = header.region_size
	vertex_spacing = header.vertex_spacing # the resolved spacing reproduces the same grid
	_setup_grid()
	if Vector2i(_region_cols, _region_rows) != header.region_grid:
		push_warning("GADS: %s: region grid %s does not match the files' %s; loading anyway." %
			[name, Vector2i(_region_cols, _region_rows), header.region_grid])
	# Sparse residency (Stage 4a): a streaming terrain whose maps are one texel per vertex keeps only
	# the near regions resident and loads / frees the rest by distance -- the large-world memory win.
	# Anything else (not streaming, or a map at a different resolution than the grid) loads whole, as
	# Stage 3b did, so a small terrain and a whole-texture import are unchanged.
	var per_vertex := header.height_dims == Vector3i(_nx, _nz, 1) \
		and (header.splat_dims == Vector3i.ZERO or header.splat_dims == Vector3i(_nx, _nz, 4)) \
		and (header.holes_dims == Vector3i.ZERO or header.holes_dims == Vector3i(_nx, _nz, 1))
	if is_streaming() and per_vertex:
		return _load_regions_sparse(header, files, dir)
	# --- Whole-resident path (Stage 3b): coalesce every region into one map and bind it. ---
	var loaded := _read_region_files(dir)
	if loaded.is_empty():
		return false
	_regions.clear()
	_region_dims.clear()
	for coord: Vector2i in loaded:
		var region: GADSTerrainRegion = loaded[coord]
		var tiles := {}
		if region.height_dims != Vector3i.ZERO:
			tiles["height"] = region.height_tile
		if region.splat_dims != Vector3i.ZERO:
			tiles["splat"] = region.splat_tile
		if region.holes_dims != Vector3i.ZERO:
			tiles["holes"] = region.holes_tile
		_regions[coord] = tiles
	for entry in [["height", header.height_dims], ["splat", header.splat_dims], ["holes", header.holes_dims]]:
		var d: Vector3i = entry[1]
		if d != Vector3i.ZERO:
			_region_dims[entry[0]] = {"w": d.x, "h": d.y, "ch": d.z}
	_swapping_edit_map = true # bind the maps without each setter queuing its own rebuild
	if _region_dims.has("height"):
		var d: Dictionary = _region_dims["height"]
		var img := Image.create_from_data(d["w"], d["h"], false, Image.FORMAT_RF,
			(_region_coalesce("height") as PackedFloat32Array).to_byte_array())
		heightmap = ImageTexture.create_from_image(img)
		_src_texture = heightmap
	if _region_dims.has("splat"):
		var d: Dictionary = _region_dims["splat"]
		var img := Image.create_from_data(d["w"], d["h"], false, Image.FORMAT_RGBAF,
			(_region_coalesce("splat") as PackedFloat32Array).to_byte_array())
		splatmap = ImageTexture.create_from_image(img)
		_splat_texture = splatmap
	if _region_dims.has("holes"):
		var d: Dictionary = _region_dims["holes"]
		# One L8 texel a vertex, 255 for a hole (as _hole_image() stores it, so _build_holes() reads
		# it back with no resize and the same threshold): coalesced bytes are the store's 0 / non-zero.
		var bytes: PackedByteArray = _region_coalesce("holes")
		var l8 := bytes.duplicate()
		for i in l8.size():
			l8[i] = 255 if l8[i] != 0 else 0
		var img := Image.create_from_data(d["w"], d["h"], false, Image.FORMAT_L8, l8)
		holes = ImageTexture.create_from_image(img)
		_holes_texture = holes
	_swapping_edit_map = false
	rebuild()
	return true


## Sets up sparse DATA residency from the region files under [param dir] (Stage 4a): records the
## grid, the whole-map dimensions and which region coordinates have a file, but loads NO tiles --
## [method _update_residency] loads the near ones and frees the far ones as the camera moves. The
## whole maps stay empty (null textures), so the terrain never holds more than a bounded handful of
## region tiles. [param header] is any one region (for the dimensions); [param files] their names.
func _load_regions_sparse(header: GADSTerrainRegion, files: PackedStringArray, dir: String) -> bool:
	_sparse = true
	_region_dir = dir
	_region_files.clear()
	for f in files:
		var c := _coord_from_filename(f)
		if c.x >= 0:
			_region_files[c] = true
	_region_dims.clear()
	for entry in [["height", header.height_dims], ["splat", header.splat_dims], ["holes", header.holes_dims]]:
		var d: Vector3i = entry[1]
		if d != Vector3i.ZERO:
			_region_dims[entry[0]] = {"w": d.x, "h": d.y, "ch": d.z}
	# No whole maps: the data lives in the files, loaded by distance. Clear the map textures (without
	# re-queuing a rebuild or leaving sparse) so rebuild() reads nothing into _src / _splat / _holes.
	_swapping_edit_map = true
	heightmap = null
	splatmap = null
	holes = null
	_swapping_edit_map = false
	_src_texture = null
	_splat_texture = null
	_holes_texture = null
	_regions.clear()
	_region_loads.clear()
	rebuild()
	return true


## Leaves sparse residency (a whole heightmap / splat was assigned, overriding the region files).
func _leave_sparse() -> void:
	_sparse = false
	_region_dir = ""
	_region_files = {}


## The region_*.res file names under [param dir] (not loaded), or empty if it has none / cannot open.
func _list_region_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var da := DirAccess.open(dir)
	if da == null:
		return out
	for f in da.get_files():
		if f.begins_with("region_") and f.get_extension() == "res":
			out.append(f)
	return out


## The region coordinate a [code]region_<x>_<y>.res[/code] file name encodes, or (-1, -1) if the
## name does not match (save_regions writes the coordinate into the name).
func _coord_from_filename(file: String) -> Vector2i:
	var parts := file.get_basename().split("_")
	if parts.size() != 3 or parts[0] != "region" or not parts[1].is_valid_int() or not parts[2].is_valid_int():
		return Vector2i(-1, -1)
	return Vector2i(int(parts[1]), int(parts[2]))


## The file path of region [param coord]'s resource.
func _region_path(coord: Vector2i) -> String:
	return _region_dir.path_join("region_%d_%d.res" % [coord.x, coord.y])


## The {map_name: tile} of each map a loaded [param region] holds. The tiles are flat arrays copied
## by value, so the resource can be freed immediately after (on the main thread, no leak).
func _tiles_from_region(region: GADSTerrainRegion) -> Dictionary:
	var tile := {}
	if region.height_dims != Vector3i.ZERO:
		tile["height"] = region.height_tile
	if region.splat_dims != Vector3i.ZERO:
		tile["splat"] = region.splat_tile
	if region.holes_dims != Vector3i.ZERO:
		tile["holes"] = region.holes_tile
	return tile


## Whether a freshly loaded [param tile] for [param coord] has the sizes the region grid expects (a
## guard against a corrupt or stale file producing out-of-range reads in the accessors).
func _validate_tile(coord: Vector2i, tile: Dictionary) -> bool:
	if tile.is_empty():
		return false
	var rect := _region_vertex_rect(coord)
	var texels := rect.size.x * rect.size.y
	for pair in [["height", 1], ["splat", 4], ["holes", 1]]:
		if _region_dims.has(pair[0]):
			if not tile.has(pair[0]) or (tile[pair[0]] as Variant).size() != texels * int(pair[1]):
				return false
	return true


## The whole-map (width, height, channels) of map [param name] from [member _region_dims] as a
## [Vector3i], for a [GADSTerrainRegion] header.
func _dims_vec(name: String) -> Vector3i:
	var d: Dictionary = _region_dims[name]
	return Vector3i(d["w"], d["h"], d["ch"])


## Loads the [code]region_*.res[/code] files under [param dir] into {coord: [GADSTerrainRegion]}.
## Empty if the directory has none (or cannot be opened). Keyed by each resource's own coordinate,
## not its file name, so a renamed file still lands in the right place.
func _read_region_files(dir: String) -> Dictionary:
	var out := {}
	var da := DirAccess.open(dir)
	if da == null:
		return out
	for file in da.get_files():
		if not file.begins_with("region_") or file.get_extension() != "res":
			continue
		# Save then load in one run (a test, an editor session): ignore the resource cache so a file
		# rewritten this run is read fresh, not served from an earlier load. The type hint stays
		# empty -- a custom class_name there makes ResourceLoader fail to resolve the loader.
		var region := ResourceLoader.load(dir.path_join(file), "", ResourceLoader.CACHE_MODE_IGNORE) as GADSTerrainRegion
		if region != null:
			out[region.coord] = region
	return out


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
	_region_sync() # the edited heights (and the caches they changed) back into the store


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
	_region_sync() # the edited splat weights (and the caches) back into the store


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
	# region_size rounded to a whole number of chunks (so a region is a block of whole chunks), at
	# least one chunk, then expressed in quads. ceili so a terrain that is not a whole number of
	# regions still tiles, with the last region on each axis partial; at least one region on each
	# axis so a terrain smaller than a region is one region.
	var chunk_side := cq * _spacing
	var region_chunks := maxi(1, ceili(region_size / maxf(chunk_side, 1e-6) - 1e-6))
	_region_quads = region_chunks * cq
	_region_cols = maxi(1, ceili(float(qx) / _region_quads))
	_region_rows = maxi(1, ceili(float(qz) / _region_quads))


func _levels() -> int:
	return clampi(lod_levels, 1, int(log(chunk_quads) / log(2.0) + 0.5) + 1)


# --- Region store (Stage 3a) --------------------------------------------------------------------
# The maps are partitioned into a sparse grid of fixed-size regions (see region_size). _regions is
# the per-region source of truth; the flat arrays (_src/_splat/_holes/_heights/_w1/_w2) are the
# coalesced hot-path view that _region_sync keeps the store in step with after every change. In the
# single-region case (a terrain smaller than one region, the usual case) a region simply references
# the whole map array, so this is a no-op in storage and behaviour; a multi-region terrain splits
# each map into its regions' slices. No geometry reads the store yet (every region is resident), so
# 3a changes nothing observable; 3b (load/free by distance) and 3c (save per region) build on it.

## Re-partitions the store from the current coalesced view. Called after every change to the maps,
## so _regions always equals the live maps split into the region grid.
func _region_sync() -> void:
	_regions.clear()
	_region_dims.clear()
	if not _src.is_empty():
		_region_put("height", int(_src["width"]), int(_src["height"]), 1, _src["data"])
	if not _splat.is_empty():
		_region_put("splat", int(_splat["width"]), int(_splat["height"]), 4, _splat["data"])
	if not _holes.is_empty():
		_region_put("holes", _nx, _nz, 1, _holes)
	if not _heights.is_empty():
		_region_put("heights", _nx, _nz, 1, _heights)
	if not _w1.is_empty():
		_region_put("w1", _nx, _nz, 1, _w1)
		_region_put("w2", _nx, _nz, 1, _w2)


## Splits the whole-terrain map [param flat] ([param w] x [param h] texels, [param ch] values a
## texel, row-major) into the store under [param name]. One region holds the whole array by
## reference (no copy); otherwise each region holds the texels of its rectangle of the grid.
func _region_put(name: String, w: int, h: int, ch: int, flat: Variant) -> void:
	_region_dims[name] = {"w": w, "h": h, "ch": ch}
	if _region_cols == 1 and _region_rows == 1:
		if not _regions.has(Vector2i.ZERO):
			_regions[Vector2i.ZERO] = {}
		_regions[Vector2i.ZERO][name] = flat
		return
	for ry in _region_rows:
		var y0 := _axis_bound(h, _region_rows, ry)
		var y1 := _axis_bound(h, _region_rows, ry + 1)
		for rx in _region_cols:
			var x0 := _axis_bound(w, _region_cols, rx)
			var x1 := _axis_bound(w, _region_cols, rx + 1)
			var tile: Variant = PackedByteArray() if name == "holes" else PackedFloat32Array()
			for y in range(y0, y1):
				tile.append_array(flat.slice((y * w + x0) * ch, (y * w + x1) * ch))
			var key := Vector2i(rx, ry)
			if not _regions.has(key):
				_regions[key] = {}
			_regions[key][name] = tile


## Reassembles map [param name] from its regions into one whole-terrain array (the inverse of
## [method _region_put]); the single-region store returns its array directly. For the view, for the
## tests and for Stage 3c's per-region save to reconstruct a map. Empty if the map is not stored.
func _region_coalesce(name: String) -> Variant:
	if not _region_dims.has(name):
		return PackedByteArray() if name == "holes" else PackedFloat32Array()
	var d: Dictionary = _region_dims[name]
	var w: int = d["w"]
	var h: int = d["h"]
	var ch: int = d["ch"]
	if _region_cols == 1 and _region_rows == 1:
		return _regions[Vector2i.ZERO][name]
	var flat: Variant = PackedByteArray() if name == "holes" else PackedFloat32Array()
	flat.resize(w * h * ch)
	for ry in _region_rows:
		var y0 := _axis_bound(h, _region_rows, ry)
		var y1 := _axis_bound(h, _region_rows, ry + 1)
		for rx in _region_cols:
			var x0 := _axis_bound(w, _region_cols, rx)
			var x1 := _axis_bound(w, _region_cols, rx + 1)
			var tile: Variant = _regions[Vector2i(rx, ry)][name]
			var ti := 0
			for y in range(y0, y1):
				var base := (y * w + x0) * ch
				for k in (x1 - x0) * ch:
					flat[base + k] = tile[ti]
					ti += 1
	return flat


## Region [param coord]'s slice of map [param name] (its own texels, row-major), or an empty array
## if the region or the map is not stored. The addressable per-region source of truth 3b/3c use.
func _region_slice(coord: Vector2i, name: String) -> Variant:
	var region: Dictionary = _regions.get(coord, {})
	return region.get(name, PackedByteArray() if name == "holes" else PackedFloat32Array())


## The region that owns grid vertex (gx, gz). Keyed by integer coordinate so a world laid out far
## from the origin addresses the same way (Stage 3b/3c); here the grid starts at vertex (0, 0).
func _region_of_vertex(gx: int, gy: int) -> Vector2i:
	return Vector2i(_region_axis(clampi(gx, 0, _nx - 1), _nx, _region_cols),
		_region_axis(clampi(gy, 0, _nz - 1), _nz, _region_rows))


func _region_axis(i: int, n: int, parts: int) -> int:
	for p in range(parts - 1, -1, -1):
		if _axis_bound(n, parts, p) <= i:
			return p
	return 0


## The grid vertices [param coord]'s region covers: [x0, x0 + w) by [y0, y0 + h).
func _region_vertex_rect(coord: Vector2i) -> Rect2i:
	var x0 := _axis_bound(_nx, _region_cols, coord.x)
	var x1 := _axis_bound(_nx, _region_cols, coord.x + 1)
	var y0 := _axis_bound(_nz, _region_rows, coord.y)
	var y1 := _axis_bound(_nz, _region_rows, coord.y + 1)
	return Rect2i(x0, y0, x1 - x0, y1 - y0)


## The i-th boundary when a map axis of [param n] texels is divided into [param parts] contiguous
## ranges; region r covers [_axis_bound(n, parts, r), _axis_bound(n, parts, r + 1)). Monotonic, 0 at
## i = 0 and n at i = parts, so coalescing the regions reproduces the whole map exactly.
##
## WHY TWO REGIMES. Stage 4a loads and frees region DATA by distance, and builds each near chunk from
## its region's resident tile (plus a one-texel apron the neighbour regions supply). For that the
## region boundaries on the VERTEX grid must land on whole chunks, so a chunk lies within exactly one
## region and a region's tile is a whole-chunk block -- hence the chunk-aligned boundary ([member
## _region_quads] quads, the last region partial) whenever the axis is the vertex grid (n == _nx or
## _nz). A map at a different resolution than the grid (a whole-texture import's heightmap or a
## low-res splat) stays resident in full, so its split need only partition it; the near-equal regime
## (i * n / parts) keeps those byte-identical to Stages 3a/3b. For the common geometries (a region a
## whole power-of-two multiple of the chunk size) the two regimes coincide.
func _axis_bound(n: int, parts: int, i: int) -> int:
	if _region_quads > 0 and (n == _nx or n == _nz):
		return n if i >= parts else mini(i * _region_quads, n)
	return i * n / parts


# --- Resident region tiles (Stage 4a) -----------------------------------------------------------
# The grid accessors below (_grid_h / _compute_weights / ... and, through them, _height_local,
# _weights_at and the GDScript chunk builder) take an optional [store]: the set of resident region
# tiles to read. A worker thread is handed a SNAPSHOT of the store (a shallow copy of _regions taken
# on the main thread) so it never touches _regions while the main thread loads or frees regions --
# the tiles are immutable PackedArrays, so a freed region's tile stays alive for any task that still
# holds it. A main-thread query passes nothing and reads the live _regions. For a non-sparse terrain
# the store is empty and every accessor keeps its original whole-map path, byte-identical.

## The owning region's tile value for map [param name] at grid vertex (gx, gz) in [param store]
## (channel [param channel] of [param ch]), or [param dflt] if that region or map is not resident.
## [param gx], [param gz] must already be clamped to the grid.
func _tile_value(store: Dictionary, gx: int, gz: int, name: String, ch: int, channel: int, dflt: float) -> float:
	var coord := _region_of_vertex(gx, gz)
	var tile: Dictionary = store.get(coord, {})
	if not tile.has(name):
		return dflt
	var rect := _region_vertex_rect(coord)
	var i := ((gz - rect.position.y) * rect.size.x + (gx - rect.position.x)) * ch + channel
	var arr: Variant = tile[name]
	if i < 0 or i >= arr.size():
		return dflt
	return arr[i]


## Whether grid vertex (gx, gz) is in a hole according to the resident hole tiles in [param store].
func _tile_hole(store: Dictionary, gx: int, gz: int) -> bool:
	return _tile_value(store, clampi(gx, 0, _nx - 1), clampi(gz, 0, _nz - 1), "holes", 1, 0, 0.0) != 0.0


## The resident store the accessors should read for this call: an explicit worker snapshot if given,
## else the live _regions when sparse residency is active (main-thread queries), else empty (the
## whole-map fast path).
func _read_store(store: Dictionary) -> Dictionary:
	if not store.is_empty():
		return store
	if _sparse_active():
		return _regions
	return {}


## Height of grid vertex (gx, gz) (clamped to the grid): from the resident region tile (sparse), the
## whole-terrain array, or the heightmap sampled bilinearly (streaming). Thread-safe (a worker passes
## its own [param store] snapshot).
func _grid_h(gx: int, gz: int, store := {}) -> float:
	gx = clampi(gx, 0, _nx - 1)
	gz = clampi(gz, 0, _nz - 1)
	var s := _read_store(store)
	if not s.is_empty():
		return height_offset + height_scale * _tile_value(s, gx, gz, "height", 1, 0, 0.0)
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


## The second and third layers' weights at grid vertex (gx, gz): a resident region's splat tile
## (sparse), the whole splat map's nearest pixel, or the slope and height rules. Thread-safe (a
## worker passes its own [param store] snapshot).
func _compute_weights(gx: int, gz: int, store := {}) -> Vector2:
	var s := _read_store(store)
	if not s.is_empty():
		# Sparse: a per-vertex splat tile (nearest == the vertex), or the rules from the resident
		# heights. _region_dims carries the whole-map dims the header recorded, so "has a splat map"
		# is known without a flat _splat.
		if _region_dims.has("splat"):
			return Vector2(_tile_value(s, gx, gz, "splat", 4, 0, 0.0), _tile_value(s, gx, gz, "splat", 4, 1, 0.0))
		return _rule_weights(_grid_normal(gx, gz, store).y, _grid_h(gx, gz, store))
	if not _splat.is_empty():
		var w: int = _splat["width"]
		var h: int = _splat["height"]
		var data: PackedFloat32Array = _splat["data"]
		var px := clampi(roundi(float(gx) / (_nx - 1) * (w - 1)), 0, w - 1)
		var py := clampi(roundi(float(gz) / (_nz - 1) * (h - 1)), 0, h - 1)
		var k := (py * w + px) * 4
		return Vector2(data[k], data[k + 1])
	return _rule_weights(_grid_normal(gx, gz).y, _grid_h(gx, gz))


## The slope / height rules' weights from an up-normal Y and a local height (shared by the whole-map
## and the resident-tile paths so both compute the rules identically).
func _rule_weights(normal_y: float, h: float) -> Vector2:
	var out := Vector2.ZERO
	var slope := smoothstep(slope_range.x, maxf(slope_range.y, slope_range.x + 0.001), rad_to_deg(acos(clampf(normal_y, -1.0, 1.0))))
	var high := smoothstep(height_band.x, maxf(height_band.y, height_band.x + 0.001), h)
	for rule in [[slope_layer, slope], [height_layer, high]]:
		if rule[0] == 1:
			out.x = maxf(out.x, rule[1])
		elif rule[0] == 2:
			out.y = maxf(out.y, rule[1])
	return out


func _grid_weights(gx: int, gz: int, store := {}) -> Vector2:
	gx = clampi(gx, 0, _nx - 1)
	gz = clampi(gz, 0, _nz - 1)
	if not _paint.is_empty():
		var painted: Variant = _paint.get(gz * _nx + gx)
		if painted != null:
			return painted
	if not _w1.is_empty():
		var i := gz * _nx + gx
		return Vector2(_w1[i], _w2[i])
	return _compute_weights(gx, gz, store)


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


func _grid_normal(x: int, z: int, store := {}) -> Vector3:
	var xa := maxi(x - 1, 0)
	var xb := mini(x + 1, _nx - 1)
	var za := maxi(z - 1, 0)
	var zb := mini(z + 1, _nz - 1)
	var dhdx := (_grid_h(xb, z, store) - _grid_h(xa, z, store)) / ((xb - xa) * _spacing)
	var dhdz := (_grid_h(x, zb, store) - _grid_h(x, za, store)) / ((zb - za) * _spacing)
	return Vector3(-dhdx, 1.0, -dhdz).normalized()


## Layer weights at grid position [param g] (fractional), bilinear between the vertices.
func _weights_at(g: Vector2, store := {}) -> Vector2:
	var x0 := mini(floori(g.x), _nx - 2)
	var z0 := mini(floori(g.y), _nz - 2)
	var fx := g.x - x0
	var fz := g.y - z0
	var top := _grid_weights(x0, z0, store).lerp(_grid_weights(x0 + 1, z0, store), fx)
	var bottom := _grid_weights(x0, z0 + 1, store).lerp(_grid_weights(x0 + 1, z0 + 1, store), fx)
	return top.lerp(bottom, fz)


## Local height of the finest LOD's triangles at local [param p] (the grid's diagonal split); NAN
## outside.
func _height_local(p: Vector2, store := {}) -> float:
	if _nx < 2:
		return NAN
	var g := (p - _origin) / _spacing
	if g.x < -1e-4 or g.y < -1e-4 or g.x > _nx - 1 + 1e-4 or g.y > _nz - 1 + 1e-4:
		return NAN
	g = g.clamp(Vector2.ZERO, Vector2(_nx - 1, _nz - 1))
	var x0 := mini(floori(g.x), _nx - 2)
	var z0 := mini(floori(g.y), _nz - 2)
	return _tri_interp(_grid_h(x0, z0, store), _grid_h(x0 + 1, z0, store), _grid_h(x0, z0 + 1, store), _grid_h(x0 + 1, z0 + 1, store), g.x - x0, g.y - z0)


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
func _chunk_arrays(cx: int, cz: int, levels: int, store := {}) -> Dictionary:
	var out: Dictionary
	if not store.is_empty():
		# Sparse: the chunk's data lives in resident region tiles, which the native mesher (built for
		# a whole-terrain grid state) cannot read, so the GDScript builder draws from the snapshot.
		# Its one-texel apron comes from the neighbour regions that residency keeps resident, so the
		# chunk's border vertices get the same heights and normals as the whole terrain -- no seam.
		out = _chunk_arrays_gd(cx, cz, levels, store)
	elif not ClassDB.class_exists(MESHER):
		out = _chunk_arrays_gd(cx, cz, levels)
	else:
		out = ClassDB.class_call_static(MESHER, &"build_chunk", _grid_state(levels), cx, cz)
		if not _paint.is_empty():
			_paint_chunk_colors(out, cx, cz)
	if _chunk_has_holes(cx, cz, store):
		_cut_chunk_holes(out, cx, cz, store)
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


func _chunk_has_holes(cx: int, cz: int, store := {}) -> bool:
	if not store.is_empty():
		# Sparse: the hole flags live per region. Only look when the terrain has a hole map at all
		# (its whole dims were recorded on load), reading the resident tiles.
		if not _region_dims.has("holes"):
			return false
	elif _hole_count == 0:
		return false
	var cq := chunk_quads
	for z in range(cz * cq, cz * cq + cq + 1):
		for x in range(cx * cq, cx * cq + cq + 1):
			if _hole_flag(x, z, store):
				return true
	return false


## Whether grid vertex (gx, gz) is in a hole, from the resident tiles ([param store], sparse) or the
## whole hole array; (gx, gz) are already within the grid.
func _hole_flag(gx: int, gz: int, store: Dictionary) -> bool:
	if not store.is_empty():
		return _tile_hole(store, gx, gz)
	return _holes[gz * _nx + gx] != 0


## Leaves out of a built chunk the triangles of its LODs and skirts that touch a hole, and its
## occluder (it would hide what lies below the holes). Marks the chunk so its collision shape
## becomes a trimesh (a height shape cannot carry holes).
func _cut_chunk_holes(out: Dictionary, cx: int, cz: int, store := {}) -> void:
	var ring := _ring(chunk_quads)
	var arrays: Array = out["arrays"]
	arrays[Mesh.ARRAY_INDEX] = _cut_indices(arrays[Mesh.ARRAY_INDEX], cx, cz, 1, ring, store)
	var keys: Array = (out["lods"] as Dictionary).keys()
	keys.sort()
	var lods := {}
	for k in keys.size():
		lods[keys[k]] = _cut_indices(out["lods"][keys[k]], cx, cz, 2 << k, ring, store)
	out["lods"] = lods
	out["has_holes"] = true
	out.erase("occluder")


func _cut_indices(idx: PackedInt32Array, cx: int, cz: int, s: int, ring: Array[Vector2i], store := {}) -> PackedInt32Array:
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
			hole = hole or _hole_flag(g0.x + g.x, g0.y + g.y, store)
		if not hole and s > 1:
			var c := Vector2i(roundi(sum.x / 3.0), roundi(sum.y / 3.0))
			hole = _hole_flag(g0.x + c.x, g0.y + c.y, store)
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
	_region_sync() # _holes is now an editable per-vertex map: re-partition it into the store


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
	_region_sync() # the edited holes back into the store


## The ground data's texels that lie on a hole get no ground (code -2): the near-camera field
## dives under them as at the end of the ground.
func _cut_ground_holes(part: Dictionary, store := {}) -> void:
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
			if not _hole_flag(gx, gz, store):
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


## [method _chunk_arrays] in GDScript (without the native library, or -- sparse -- reading the
## resident region tiles in [param store] instead of the whole maps). Reads no node: runs on worker
## threads while streaming.
func _chunk_arrays_gd(cx: int, cz: int, levels: int, store := {}) -> Dictionary:
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
			var nrm := _grid_normal(gx, gz, store)
			heights[i] = _grid_h(gx, gz, store)
			verts[i] = Vector3(_origin.x + gx * _spacing, heights[i], _origin.y + gz * _spacing)
			normals[i] = nrm
			var t := Vector3(1, 0, 0)
			t = (t - nrm * nrm.dot(t)).normalized()
			tangents[i * 4] = t.x
			tangents[i * 4 + 1] = t.y
			tangents[i * 4 + 2] = t.z
			tangents[i * 4 + 3] = 1.0
			var wts := _grid_weights(gx, gz, store)
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
	_update_residency(xz) # sparse: load / free region tiles by distance before chunks read them
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
	var sparse := _sparse_active()
	var wanted := []
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var key := Vector2i(cx, cz)
			if _chunk_nodes.has(key) or _pending.has(key):
				continue
			# Sparse: a chunk may start only once its region and the neighbour regions its apron
			# reads into are resident, so its build task finds every texel in the snapshot.
			if sparse and not _chunk_region_ready(key):
				continue
			var d := _rect_distance(_chunk_rect(key), xz)
			if d <= stream_radius:
				wanted.append([d, key])
	wanted.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	# One immutable snapshot of the resident tiles for every task started this frame: the build runs
	# on a worker thread and reads only this, so the main thread may load or free regions meanwhile.
	var snap := _regions.duplicate() if sparse else {}
	var levels := _levels()
	for item: Array in wanted:
		if _pending.size() >= MAX_STREAM_TASKS:
			break
		var key: Vector2i = item[1]
		_pending[key] = WorkerThreadPool.add_task(_build_task.bind(key, levels, snap), false, "GADS terrain chunk")
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


# --- Region residency (Stage 4a) ----------------------------------------------------------------
# For a region-file-backed streaming terrain the map DATA is loaded and freed by distance, mirroring
# the chunk stream. A region is LOADED (its file read by the engine's threaded loader on a background
# thread) when it, or a near region whose chunks' aprons reach into it, comes within the stream
# radius; it is FREED when it falls past a larger hysteresis distance so panning across a boundary
# does not thrash. The residency set is thus a bounded ring around the camera -- a handful of region
# tiles, not the whole ~1 GB map of a 16k world. _regions (the resident store) is touched only on the
# main thread; worker build / ground tasks read an immutable snapshot, so a freed region's tile stays
# alive for any task that still holds it and there is no data race on the store.

## Loads the region tiles the camera needs and frees those it has left. Only the regions a chunk
## reads (its own plus the neighbours its one-texel apron reaches) are kept, so a chunk can always
## build from the resident set. [param xz]: the camera in the terrain's local XZ.
func _update_residency(xz: Vector2) -> void:
	if not _sparse_active():
		return
	var grid := get_region_grid()
	var side := _region_quads * _spacing
	var drop := stream_radius * 1.25 + side # free past this (hysteresis), as the chunk stream does
	var reach := drop + side # the search box: the keep distance plus one region for the neighbour ring
	var lo := Vector2i(((xz - Vector2.ONE * reach - _origin) / side).floor()).clamp(Vector2i.ZERO, grid - Vector2i.ONE)
	var hi := Vector2i(((xz + Vector2.ONE * reach - _origin) / side).floor()).clamp(Vector2i.ZERO, grid - Vector2i.ONE)
	var in_range := {}
	var within_drop := {}
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var coord := Vector2i(cx, cy)
			var d := _rect_distance(_region_local_rect(coord), xz)
			if d <= stream_radius:
				in_range[coord] = true
			if d <= drop:
				within_drop[coord] = true
	# A chunk at a region edge reads one texel into the neighbour region, so a region is needed (and
	# kept) together with its eight neighbours.
	var needed := _with_neighbors(in_range, grid)
	var keep := _with_neighbors(within_drop, grid)
	for coord: Vector2i in needed:
		if _regions.has(coord) or _region_loads.has(coord) or not _region_files.has(coord):
			continue
		if _region_loads.size() >= MAX_STREAM_TASKS:
			break
		# The engine's threaded loader does the I/O on a background thread; we poll it in
		# _collect_tasks and take the resource on the main thread (so it frees there -- a resource
		# loaded AND freed on a worker thread leaks in Godot).
		var path := _region_path(coord)
		if ResourceLoader.load_threaded_request(path, "", false, ResourceLoader.CACHE_MODE_IGNORE) == OK:
			_region_loads[coord] = path
	for coord: Vector2i in _regions.keys():
		if not keep.has(coord):
			_regions.erase(coord)


## [param coords] (a set: coord -> true) grown by the eight neighbours of each, clamped to the grid.
func _with_neighbors(coords: Dictionary, grid: Vector2i) -> Dictionary:
	var out := {}
	for coord: Vector2i in coords:
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var c := coord + Vector2i(dx, dy)
				if c.x >= 0 and c.y >= 0 and c.x < grid.x and c.y < grid.y:
					out[c] = true
	return out


## Region [param coord]'s footprint in local XZ (the chunks it owns), for the distance test.
func _region_local_rect(coord: Vector2i) -> Rect2:
	var rq := _region_quads
	var x0 := coord.x * rq
	var x1 := mini((coord.x + 1) * rq, _nx - 1)
	var y0 := coord.y * rq
	var y1 := mini((coord.y + 1) * rq, _nz - 1)
	return Rect2(_origin + Vector2(x0, y0) * _spacing, Vector2(x1 - x0, y1 - y0) * _spacing)


## Whether every region chunk [param key]'s vertices and their one-texel apron read is resident (or
## has no file, so its texels default to the flat height). Only then may the chunk's build start.
func _chunk_region_ready(key: Vector2i) -> bool:
	var cq := chunk_quads
	var r0 := _region_of_vertex(key.x * cq - 1, key.y * cq - 1)
	var r1 := _region_of_vertex(key.x * cq + cq + 1, key.y * cq + cq + 1)
	for ry in range(r0.y, r1.y + 1):
		for rx in range(r0.x, r1.x + 1):
			var c := Vector2i(rx, ry)
			if not _regions.has(c) and _region_files.has(c):
				return false
	return true


## Worker thread: one chunk's arrays. [param store] is the resident-tile snapshot for a sparse
## terrain (empty otherwise); the task reads only it, never the live _regions.
func _build_task(key: Vector2i, levels: int, store := {}) -> void:
	var data := _chunk_arrays(key.x, key.y, levels, store)
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
	# Install the region tiles whose background loads finished, so this frame's _update_stream can
	# build the chunks that were waiting on them. load_threaded_get takes the resource on the main
	# thread; its local reference drops here, so it frees on the main thread (no leak).
	for coord: Vector2i in _region_loads.keys():
		var path: String = _region_loads[coord]
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_region_loads.erase(coord)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var region := ResourceLoader.load_threaded_get(path) as GADSTerrainRegion
			if region != null:
				var tile := _tiles_from_region(region)
				if _validate_tile(coord, tile):
					_regions[coord] = tile


func _wait_tasks() -> void:
	for task: int in _pending.values():
		WorkerThreadPool.wait_for_task_completion(task)
	_pending.clear()
	_pending_version.clear()
	_results.clear()
	# Drain any outstanding background region loads (blocks until each is done) so none lingers.
	for path: String in _region_loads.values():
		ResourceLoader.load_threaded_get(path)
	_region_loads.clear()
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
	# Sparse: hand the job the same resident-tile snapshot the chunks use (the window stays within the
	# near regions residency keeps loaded), so it reads tiles rather than the empty whole maps.
	var snap := _regions.duplicate() if _sparse_active() else {}
	_window_task = WorkerThreadPool.add_task(_window_job.bind(rect, snap), false, "GADS terrain ground data")


func _window_job(rect: Rect2, store := {}) -> void:
	var bake := make_ground_bake(rect, store)
	var lift := clampf(ground_data_error(rect, store) + 0.002, 0.002, 0.1)
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
	# The builder marks a chunk whose triangles it cut for holes (whole array or resident tiles).
	if chunk.get("has_holes", false):
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
