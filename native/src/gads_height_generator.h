// GADSHeightGenerator: procedural, tileable height fields, the maps derived from height fields
// (normal, ambient occlusion, curvature) and erosion, for GDScript (see proc/height_gen.h and
// proc/erosion.h). Static methods; safe to call from any thread.
#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

class GADSHeightGenerator : public RefCounted {
	GDCLASS(GADSHeightGenerator, RefCounted)

protected:
	static void _bind_methods();

public:
	static PackedStringArray get_kinds();
	static Ref<Image> generate(const String &p_kind, int p_size, const Dictionary &p_params);
	static Ref<Image> normal_map(const Ref<Image> &p_height, float p_depth_m, const Vector2 &p_tile_m);
	static Ref<Image> ambient_occlusion(const Ref<Image> &p_height, float p_depth_m, const Vector2 &p_tile_m, float p_radius_m);
	static Ref<Image> curvature(const Ref<Image> &p_height, float p_radius_texels, float p_gain);
	static Ref<Image> albedo_map(const Ref<Image> &p_height, const Color &p_low, const Color &p_high, const Ref<Image> &p_ao, const Ref<Image> &p_curvature,
			float p_ao_strength, float p_cavity_strength);
	static Ref<Image> orm_map(const Ref<Image> &p_ao, const Ref<Image> &p_curvature, float p_roughness, float p_variation);
	static Ref<Image> erode(const Ref<Image> &p_height, const Dictionary &p_params);
};

} // namespace godot
