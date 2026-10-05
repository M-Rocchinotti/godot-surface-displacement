// GADSTessellator: the adaptive displacement tessellator for GDScript (see tess/tessellator.h).
// Inputs are copied in on the calling thread; run() may then run on any thread while the main
// thread polls get_progress() / get_triangle_count() and may call cancel().
#pragma once

#include "tess/tessellator.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <atomic>

namespace godot {

class GADSTessellator : public RefCounted {
	GDCLASS(GADSTessellator, RefCounted)

	gads::Tessellator core_;
	std::atomic<bool> cancel_{ false };
	std::atomic<float> progress_{ 0.0f };
	std::atomic<int> triangles_{ 0 };
	std::atomic<bool> done_{ false };
	bool ok_ = false;

protected:
	static void _bind_methods();

public:
	int add_height_map(const Ref<Image> &p_image);
	void add_surface(const Array &p_arrays, const Dictionary &p_displacement);
	void set_transform(const Transform3D &p_transform);
	void set_settings(const Dictionary &p_settings);
	bool run();
	void cancel();
	float get_progress() const;
	int get_triangle_count() const;
	bool is_done() const;
	Array get_surfaces() const;
	Dictionary get_stats() const;
	String get_error() const;

	static String get_build_hash();
	static int get_algorithm_version();
};

} // namespace godot
