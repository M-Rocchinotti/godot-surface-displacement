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
##
## The terrain is centred on the node, its size rounded to whole chunks. The detail field and
## deformation work in world space: keep the node unrotated and unscaled (moving it is fine; the
## ground data follows on the next rebuild).

signal rebuilt

const MAX_LAYERS := 3

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
var _heights := PackedFloat32Array() # local y per vertex, row-major (_nx per row)
var _w1 := PackedFloat32Array() # the second layer's weight per vertex
var _w2 := PackedFloat32Array() # the third layer's
var _chunks: Array[MeshInstance3D] = []
var _body: StaticBody3D
var _field: GADSDisplacementField3D
var _material: Material
var _queued := false
var _build_ms := 0.0


func _ready() -> void:
	rebuild()


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
## layers' materials, say). Runs on the calling thread.
func rebuild() -> void:
	_queued = false
	if not is_inside_tree():
		return
	var t0 := Time.get_ticks_usec()
	_build_heights()
	_build_weights()
	_material = material if material != null else GADSMaterials.combine_layers(layers.slice(0, MAX_LAYERS))
	_build_chunks()
	_build_collision()
	_build_field()
	_build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	update_configuration_warnings()
	rebuilt.emit()


# --- Queries ------------------------------------------------------------------------------------

## Width and depth (m) after rounding to whole chunks.
func get_extent() -> Vector2:
	return Vector2(_nx - 1, _nz - 1) * _spacing


## The vertices per side (x, z) of the finest grid.
func get_grid_size() -> Vector2i:
	return Vector2i(_nx, _nz)


func get_vertex_spacing() -> float:
	return _spacing


## World height of the terrain's surface (as its finest LOD draws it) under [param world_position];
## NAN outside the terrain.
func get_height(world_position: Vector3) -> float:
	var local := to_local(world_position)
	var h := _height_local(Vector2(local.x, local.z))
	if is_nan(h):
		return NAN
	return to_global(Vector3(local.x, h, local.z)).y


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
	return Vector2(_bilinear(_w1, g), _bilinear(_w2, g))


## The terrain's chunks (internal MeshInstance3D children).
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


## The texel of the ground data (m): the vertex spacing divided by [member detail_subdivision],
## or multiplied by powers of two while the data would exceed 2048 texels a side. Texel centres
## lie on the vertices, so the field's bilinear heights follow the triangles.
func get_ground_texel() -> float:
	var extent := get_extent()
	var texel := _spacing / maxi(detail_subdivision, 1)
	while maxf(extent.x, extent.y) / texel + 1.0 > 2048.0:
		texel *= 2.0
	return texel


## The terrain's ground data for a GADSDisplacementField3D (world space): height of the finest
## LOD and the dominant layer per texel, texel centres on the vertices (see
## [method get_ground_texel]).
func make_ground_bake() -> GADSGroundBake:
	if _nx < 2:
		return null
	var extent := get_extent()
	var texel := get_ground_texel()
	var w := roundi(extent.x / texel) + 1
	var d := roundi(extent.y / texel) + 1
	var gp := global_position
	var heights := PackedFloat32Array()
	heights.resize(w * d)
	var codes := PackedInt32Array()
	codes.resize(w * d)
	for z in d:
		for x in w:
			var p := _origin + Vector2(x, z) * texel
			var i := z * w + x
			heights[i] = _height_local(p.clamp(_origin, _origin + extent)) + gp.y
			var g := (p - _origin) / _spacing
			g = g.clamp(Vector2.ZERO, Vector2(_nx - 1, _nz - 1))
			var w2 := _bilinear(_w2, g)
			var w1 := _bilinear(_w1, g)
			var layer := 2 if w2 >= 0.5 else (1 if w1 >= 0.5 else 0)
			codes[i] = layer if layer < layers.size() else -1
	return GADSGroundBake.from_arrays(Vector2i(w, d), heights, codes, _origin - Vector2(texel, texel) * 0.5 + Vector2(gp.x, gp.z), texel)


## How far the field's bilinear heights can fall from the triangles on ground it displaces (m):
## a texel cell that a quad's diagonal crosses differs by up to a quarter of the quad's crease
## (h00 + h11 - h10 - h01) times the texel over the spacing, halved; quads steeper than the
## field's step limit are left out (the field does not displace them).
func ground_data_error() -> float:
	var ratio := get_ground_texel() / _spacing
	var factor := 0.125 if ratio < 0.75 else 0.25 * ratio
	var steep := GADSGroundBake.STEP_SLOPE * _spacing
	var worst := 0.0
	for z in _nz - 1:
		for x in _nx - 1:
			var h00 := _heights[z * _nx + x]
			var h10 := _heights[z * _nx + x + 1]
			var h01 := _heights[(z + 1) * _nx + x]
			var h11 := _heights[(z + 1) * _nx + x + 1]
			if maxf(maxf(absf(h10 - h00), absf(h01 - h00)), maxf(absf(h11 - h10), absf(h11 - h01))) > steep:
				continue
			worst = maxf(worst, absf(h00 + h11 - h10 - h01))
	return worst * factor


# --- Building -----------------------------------------------------------------------------------

func _build_heights() -> void:
	var cq := chunk_quads
	var qx := maxi(cq, roundi(size.x / vertex_spacing / cq) * cq)
	_spacing = size.x / qx
	var qz := maxi(cq, roundi(size.y / _spacing / cq) * cq)
	_nx = qx + 1
	_nz = qz + 1
	_origin = -Vector2(qx, qz) * _spacing * 0.5
	_heights.resize(_nx * _nz)
	var img := _float_image(heightmap)
	if img.is_empty():
		_heights.fill(height_offset)
		return
	var w: int = img["width"]
	var h: int = img["height"]
	var data: PackedFloat32Array = img["data"]
	for z in _nz:
		var py := float(z) / (_nz - 1) * (h - 1)
		var y0 := mini(floori(py), h - 2) if h > 1 else 0
		var fy := py - y0 if h > 1 else 0.0
		for x in _nx:
			var px := float(x) / (_nx - 1) * (w - 1)
			var x0 := mini(floori(px), w - 2) if w > 1 else 0
			var fx := px - x0 if w > 1 else 0.0
			var x1 := mini(x0 + 1, w - 1)
			var y1 := mini(y0 + 1, h - 1)
			var top := lerpf(data[y0 * w + x0], data[y0 * w + x1], fx)
			var bottom := lerpf(data[y1 * w + x0], data[y1 * w + x1], fx)
			_heights[z * _nx + x] = height_offset + height_scale * lerpf(top, bottom, fy)


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


func _build_weights() -> void:
	var n := _nx * _nz
	_w1.resize(n)
	_w2.resize(n)
	_w1.fill(0.0)
	_w2.fill(0.0)
	if splatmap != null:
		var img := splatmap.get_image()
		if img != null and not img.is_empty():
			img = img.duplicate() as Image
			if img.is_compressed():
				img.decompress()
			img.clear_mipmaps()
			img.convert(Image.FORMAT_RGBAF)
			var w := img.get_width()
			var h := img.get_height()
			var data := img.get_data().to_float32_array()
			for z in _nz:
				for x in _nx:
					var px := clampi(roundi(float(x) / (_nx - 1) * (w - 1)), 0, w - 1)
					var py := clampi(roundi(float(z) / (_nz - 1) * (h - 1)), 0, h - 1)
					var k := (py * w + px) * 4
					_w1[z * _nx + x] = data[k]
					_w2[z * _nx + x] = data[k + 1]
			return
	for z in _nz:
		for x in _nx:
			var i := z * _nx + x
			var nrm := _grid_normal(x, z)
			var slope := smoothstep(slope_range.x, maxf(slope_range.y, slope_range.x + 0.001), rad_to_deg(acos(clampf(nrm.y, -1.0, 1.0))))
			var high := smoothstep(height_band.x, maxf(height_band.y, height_band.x + 0.001), _heights[i])
			for rule in [[slope_layer, slope], [height_layer, high]]:
				if rule[0] == 1:
					_w1[i] = maxf(_w1[i], rule[1])
				elif rule[0] == 2:
					_w2[i] = maxf(_w2[i], rule[1])


func _grid_normal(x: int, z: int) -> Vector3:
	var xa := maxi(x - 1, 0)
	var xb := mini(x + 1, _nx - 1)
	var za := maxi(z - 1, 0)
	var zb := mini(z + 1, _nz - 1)
	var dhdx := (_heights[z * _nx + xb] - _heights[z * _nx + xa]) / ((xb - xa) * _spacing)
	var dhdz := (_heights[zb * _nx + x] - _heights[za * _nx + x]) / ((zb - za) * _spacing)
	return Vector3(-dhdx, 1.0, -dhdz).normalized()


func _bilinear(values: PackedFloat32Array, g: Vector2) -> float:
	var x0 := mini(floori(g.x), _nx - 2)
	var z0 := mini(floori(g.y), _nz - 2)
	var fx := g.x - x0
	var fz := g.y - z0
	var top := lerpf(values[z0 * _nx + x0], values[z0 * _nx + x0 + 1], fx)
	var bottom := lerpf(values[(z0 + 1) * _nx + x0], values[(z0 + 1) * _nx + x0 + 1], fx)
	return lerpf(top, bottom, fz)


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
	return _tri_interp(_heights[z0 * _nx + x0], _heights[z0 * _nx + x0 + 1], _heights[(z0 + 1) * _nx + x0],
		_heights[(z0 + 1) * _nx + x0 + 1], g.x - x0, g.y - z0)


## Height in a quad split along its (1, 0)-(0, 1) diagonal, as the chunks triangulate it.
static func _tri_interp(h00: float, h10: float, h01: float, h11: float, fx: float, fz: float) -> float:
	if fx + fz <= 1.0:
		return h00 + fx * (h10 - h00) + fz * (h01 - h00)
	return h11 + (1.0 - fx) * (h01 - h11) + (1.0 - fz) * (h10 - h11)


func _build_chunks() -> void:
	for chunk in _chunks:
		chunk.queue_free()
	_chunks.clear()
	var cq := chunk_quads
	var levels := clampi(lod_levels, 1, int(log(cq) / log(2.0) + 0.5) + 1)
	for cz in (_nz - 1) / cq:
		for cx in (_nx - 1) / cq:
			var mi := MeshInstance3D.new()
			mi.name = "Chunk_%d_%d" % [cx, cz]
			mi.mesh = _chunk_mesh(cx, cz, levels)
			mi.material_override = _material
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi, false, Node.INTERNAL_MODE_BACK)
			_chunks.append(mi)


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


func _chunk_mesh(cx: int, cz: int, levels: int) -> ArrayMesh:
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
	var extent := get_extent()
	for z in n:
		for x in n:
			var g := (gz0 + z) * _nx + gx0 + x
			var i := z * n + x
			var nrm := _grid_normal(gx0 + x, gz0 + z)
			verts[i] = Vector3(_origin.x + (gx0 + x) * _spacing, _heights[g], _origin.y + (gz0 + z) * _spacing)
			normals[i] = nrm
			var t := Vector3(1, 0, 0)
			t = (t - nrm * nrm.dot(t)).normalized()
			tangents[i * 4] = t.x
			tangents[i * 4 + 1] = t.y
			tangents[i * 4 + 2] = t.z
			tangents[i * 4 + 3] = 1.0
			colors[i] = Color(_w1[g], _w2[g], 0.0, 1.0)
			uvs[i] = Vector2(float(gx0 + x) * _spacing / extent.x, float(gz0 + z) * _spacing / extent.y)
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
				var hc := _tri_interp(verts[z0 * n + x0].y, verts[z0 * n + x0 + s].y, verts[(z0 + s) * n + x0].y,
					verts[(z0 + s) * n + x0 + s].y, float(x - x0) / s, float(z - z0) / s)
				worst = maxf(worst, absf(verts[z * n + x].y - hc))
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
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods)
	return mesh


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


func _build_collision() -> void:
	if not collision or _nx < 2:
		if _body != null:
			_body.queue_free()
			_body = null
		return
	if _body == null:
		_body = StaticBody3D.new()
		_body.name = "GADSTerrainCollision"
		_body.add_child(CollisionShape3D.new())
		add_child(_body, false, Node.INTERNAL_MODE_BACK)
	_body.collision_layer = collision_layer
	_body.collision_mask = collision_mask
	# A HeightMapShape3D has one unit between samples and is centred: scale it by the spacing
	# (uniformly, with the heights divided by it), offset to the grid's centre.
	var shape := HeightMapShape3D.new()
	shape.map_width = _nx
	shape.map_depth = _nz
	var data := PackedFloat32Array()
	data.resize(_heights.size())
	for i in _heights.size():
		data[i] = _heights[i] / _spacing
	shape.map_data = data
	var cs := _body.get_child(0) as CollisionShape3D
	cs.shape = shape
	cs.transform = Transform3D(Basis.from_scale(Vector3.ONE * _spacing), Vector3(_origin.x + (_nx - 1) * _spacing * 0.5, 0.0,
		_origin.y + (_nz - 1) * _spacing * 0.5))


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
	# Lifted by what its ground data can fall short of the triangles, so the terrain stays under it.
	_field.lift = clampf(ground_data_error() + 0.002, 0.002, 0.1)
	var field_layers: Array[ShaderMaterial] = []
	for i in mini(layers.size(), MAX_LAYERS):
		field_layers.append(layers[i])
	_field.layers = field_layers
	_field.ground_bake = make_ground_bake()
