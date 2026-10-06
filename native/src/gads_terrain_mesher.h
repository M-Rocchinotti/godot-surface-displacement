// GADSTerrainMesher: the per-vertex and per-texel passes of GADSTerrain3D, natively (the same
// results as its GDScript, many times faster): a chunk's mesh arrays, LODs and occluder; the
// grid's heights and layer weights; the detail field's ground data and its encoding; the ground
// data's error. Static; they read only their arguments, so worker threads can call them.
#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace godot {

class GADSTerrainMesher : public RefCounted {
	GDCLASS(GADSTerrainMesher, RefCounted)

protected:
	static void _bind_methods();

public:
	static Dictionary build_chunk(const Dictionary &p_grid, int p_cx, int p_cz);
	static PackedFloat32Array grid_heights(const Dictionary &p_grid);
	static Dictionary grid_weights(const Dictionary &p_grid);
	static Dictionary ground_arrays(const Dictionary &p_grid, const Vector2i &p_first, const Vector2i &p_size, float p_texel, float p_ground_y, int p_layer_count);
	static float ground_error(const Dictionary &p_grid, const Rect2i &p_vertices, float p_steep);
	static Dictionary encode_ground(const PackedFloat32Array &p_heights, const PackedInt32Array &p_codes, const Vector2i &p_size);
};

} // namespace godot
