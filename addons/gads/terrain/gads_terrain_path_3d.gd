@tool
@icon("res://addons/gads/icons/gads_terrain_3d.svg")
class_name GADSTerrainPath3D
extends Path3D
## A road, track, trench or river bed on a GADSTerrain3D: draw the curve in the viewport, then
## Apply to Terrain flattens the ground along it ([member width], fading back to the ground over
## [member falloff]) and can paint a layer under it. With [member conform] the road follows the
## ground (the terrain's heights under the curve, averaged over [member smoothing] metres) instead
## of the curve's own heights. Apply is one undoable action in the editor; at runtime [method apply]
## edits the terrain directly.

## The terrain to edit; empty: the parent.
@export var terrain: NodePath
## The flat band's width (m).
@export_range(0.5, 200.0, 0.1, "or_greater", "suffix:m") var width := 4.0
## How far beyond the band the ground fades back to its own height (m).
@export_range(0.0, 200.0, 0.1, "or_greater", "suffix:m") var falloff := 3.0
## The layer painted under the road (1: the second, 2: the third, 0: the first); -1: none.
@export_range(-1, 2) var layer := -1
## Follow the ground (its heights under the curve, smoothed) instead of the curve's heights.
@export var conform := true
## The length (m) over which a conforming road's heights are averaged: longer, smoother.
@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var smoothing := 12.0
## How far the heights move to the road's (0..1).
@export_range(0.0, 1.0) var strength := 1.0
## Apply when the game starts (a road made at runtime, e.g. from a generated curve). In the editor
## press Apply to Terrain instead, so the road is saved with the terrain's maps.
@export var apply_on_ready := false
@export_tool_button("Apply to Terrain", "Path3D") var _apply_button := apply


func _ready() -> void:
	if apply_on_ready and not Engine.is_editor_hint():
		# After the terrain (the parent) is built.
		apply.call_deferred()


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if get_terrain() == null:
		out.append("No GADSTerrain3D to edit: make this node a child of one, or set terrain.")
	if curve == null or curve.point_count < 2:
		out.append("Draw a curve with at least two points (the road's centre line).")
	if layer >= 0 and get_terrain() != null and layer >= get_terrain().layers.size():
		out.append("The terrain has no layer %d to paint (it has %d)." % [layer, get_terrain().layers.size()])
	return out


func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED or what == NOTIFICATION_UNPARENTED:
		update_configuration_warnings()


func get_terrain() -> GADSTerrain3D:
	if not terrain.is_empty():
		return get_node_or_null(terrain) as GADSTerrain3D
	return get_parent() as GADSTerrain3D


## The road's centre line (world positions every half vertex spacing along the curve) with its
## heights: the curve's, or with [member conform] the terrain's under it, averaged over
## [member smoothing] metres.
func road_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	var t := get_terrain()
	if curve == null or curve.point_count < 2 or t == null:
		return out
	var length := curve.get_baked_length()
	var step := maxf(t.get_vertex_spacing() * 0.5, 0.01)
	var n := maxi(int(ceil(length / step)) + 1, 2)
	for i in n:
		out.append(global_transform * curve.sample_baked(minf(i * step, length)))
	if conform:
		var ground := PackedFloat32Array()
		ground.resize(n)
		for i in n:
			var h := t.get_height(out[i])
			ground[i] = h if not is_nan(h) else out[i].y
		var half := int(round(smoothing / step * 0.5))
		for i in n:
			var sum := 0.0
			var count := 0
			for k in range(maxi(i - half, 0), mini(i + half, n - 1) + 1):
				sum += ground[k]
				count += 1
			out[i].y = sum / count
	return out


## Flattens the terrain along the road (and paints [member layer]); one undoable action in the
## editor. Returns the grid vertices it changed.
func apply() -> Rect2i:
	var t := get_terrain()
	if t == null:
		push_warning("GADS: %s: no GADSTerrain3D to apply to (set terrain, or make the path its child)." % name)
		return Rect2i()
	var points := road_points()
	var changed := [Rect2i()]
	GADSTerrainEdit.run(t, "Apply GADS Road", func() -> void:
		changed[0] = t.flatten_path(points, width, falloff, layer, strength), true, layer >= 0)
	return changed[0]
