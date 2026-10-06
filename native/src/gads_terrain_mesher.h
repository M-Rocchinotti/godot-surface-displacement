// GADSTerrainMesher: a GADSTerrain3D chunk's mesh arrays, LODs and occluder, built natively (the
// same as GADSTerrain3D._chunk_arrays in GDScript, about thirty times faster). Static; reads
// only its arguments, so worker threads can call it.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class GADSTerrainMesher : public RefCounted {
	GDCLASS(GADSTerrainMesher, RefCounted)

protected:
	static void _bind_methods();

public:
	static Dictionary build_chunk(const Dictionary &p_grid, int p_cx, int p_cz);
};

} // namespace godot
