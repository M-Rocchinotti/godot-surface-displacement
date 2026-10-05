#include "gads_tessellator.h"

#include "build_hash.gen.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cstring>

namespace godot {

// Bumped whenever the tessellator's output for the same input changes: it is part of the bake
// cache key, so stale bakes are rebuilt.
static constexpr int ALGORITHM_VERSION = 2; // 2: detail layer, heights filtered only where refinement stopped early

// Mesh.ArrayType
enum {
	ARRAY_VERTEX = 0,
	ARRAY_NORMAL = 1,
	ARRAY_TANGENT = 2,
	ARRAY_COLOR = 3,
	ARRAY_TEX_UV = 4,
	ARRAY_TEX_UV2 = 5,
	ARRAY_CUSTOM0 = 6,
	ARRAY_CUSTOM1 = 7,
	ARRAY_INDEX = 12,
	ARRAY_MAX = 13,
};

void GADSTessellator::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add_height_map", "image"), &GADSTessellator::add_height_map);
	ClassDB::bind_method(D_METHOD("add_surface", "arrays", "displacement"), &GADSTessellator::add_surface);
	ClassDB::bind_method(D_METHOD("set_transform", "transform"), &GADSTessellator::set_transform);
	ClassDB::bind_method(D_METHOD("set_settings", "settings"), &GADSTessellator::set_settings);
	ClassDB::bind_method(D_METHOD("run"), &GADSTessellator::run);
	ClassDB::bind_method(D_METHOD("cancel"), &GADSTessellator::cancel);
	ClassDB::bind_method(D_METHOD("get_progress"), &GADSTessellator::get_progress);
	ClassDB::bind_method(D_METHOD("get_triangle_count"), &GADSTessellator::get_triangle_count);
	ClassDB::bind_method(D_METHOD("is_done"), &GADSTessellator::is_done);
	ClassDB::bind_method(D_METHOD("get_surfaces"), &GADSTessellator::get_surfaces);
	ClassDB::bind_method(D_METHOD("get_stats"), &GADSTessellator::get_stats);
	ClassDB::bind_method(D_METHOD("get_error"), &GADSTessellator::get_error);
	ClassDB::bind_static_method("GADSTessellator", D_METHOD("get_build_hash"), &GADSTessellator::get_build_hash);
	ClassDB::bind_static_method("GADSTessellator", D_METHOD("get_algorithm_version"), &GADSTessellator::get_algorithm_version);
}

int GADSTessellator::add_height_map(const Ref<Image> &p_image) {
	ERR_FAIL_COND_V_MSG(p_image.is_null() || p_image->is_empty(), -1, "GADSTessellator: empty height map.");
	Ref<Image> img = Image::create_from_data(p_image->get_width(), p_image->get_height(), p_image->has_mipmaps(), p_image->get_format(), p_image->get_data());
	if (img->is_compressed()) {
		img->decompress();
	}
	img->clear_mipmaps();
	img->convert(Image::FORMAT_RF);
	PackedByteArray bytes = img->get_data();
	std::vector<float> data(size_t(img->get_width()) * img->get_height());
	ERR_FAIL_COND_V(size_t(bytes.size()) < data.size() * sizeof(float), -1);
	std::memcpy(data.data(), bytes.ptr(), data.size() * sizeof(float));
	return core_.add_height_map(img->get_width(), img->get_height(), std::move(data));
}

static gads::V2 v2(const Variant &v, gads::V2 fallback) {
	if (v.get_type() != Variant::VECTOR2) {
		return fallback;
	}
	Vector2 x = v;
	return gads::V2(x.x, x.y);
}

void GADSTessellator::add_surface(const Array &p_arrays, const Dictionary &p_displacement) {
	ERR_FAIL_COND_MSG(p_arrays.size() < ARRAY_MAX, "GADSTessellator: surface arrays must have Mesh.ARRAY_MAX entries.");
	gads::SurfaceInput s;
	PackedVector3Array vertices = p_arrays[ARRAY_VERTEX];
	s.positions.resize(vertices.size());
	for (int64_t i = 0; i < vertices.size(); i++) {
		s.positions[i] = gads::V3(vertices[i].x, vertices[i].y, vertices[i].z);
	}
	if (p_arrays[ARRAY_NORMAL].get_type() == Variant::PACKED_VECTOR3_ARRAY) {
		PackedVector3Array normals = p_arrays[ARRAY_NORMAL];
		for (int64_t i = 0; i < normals.size(); i++) {
			s.normals.push_back(gads::V3(normals[i].x, normals[i].y, normals[i].z));
		}
	}
	for (int ch = ARRAY_TEX_UV; ch <= ARRAY_TEX_UV2; ch++) {
		if (p_arrays[ch].get_type() == Variant::PACKED_VECTOR2_ARRAY) {
			PackedVector2Array uv = p_arrays[ch];
			std::vector<gads::V2> &dst = ch == ARRAY_TEX_UV ? s.uv : s.uv2;
			for (int64_t i = 0; i < uv.size(); i++) {
				dst.push_back(gads::V2(uv[i].x, uv[i].y));
			}
		}
	}
	if (p_arrays[ARRAY_COLOR].get_type() == Variant::PACKED_COLOR_ARRAY) {
		PackedColorArray colors = p_arrays[ARRAY_COLOR];
		for (int64_t i = 0; i < colors.size(); i++) {
			s.colors.insert(s.colors.end(), { colors[i].r, colors[i].g, colors[i].b, colors[i].a });
		}
	}
	if (p_arrays[ARRAY_INDEX].get_type() == Variant::PACKED_INT32_ARRAY) {
		PackedInt32Array indices = p_arrays[ARRAY_INDEX];
		s.indices.assign(indices.ptr(), indices.ptr() + indices.size());
	}
	if (!p_displacement.is_empty() && int(p_displacement.get("height_map", -1)) >= 0) {
		gads::Displacement d;
		d.height_map = p_displacement.get("height_map", -1);
		d.mapping = gads::Mapping(int(p_displacement.get("mapping", 0)));
		d.height_m = p_displacement.get("height_m", 0.03);
		d.center = p_displacement.get("center", 1.0);
		d.remap = v2(p_displacement.get("remap", Variant()), gads::V2(0.0, 1.0));
		d.uv_scale = v2(p_displacement.get("uv_scale", Variant()), gads::V2(1.0, 1.0));
		d.uv_offset = v2(p_displacement.get("uv_offset", Variant()), gads::V2());
		d.texture_size_m = v2(p_displacement.get("texture_size_m", Variant()), gads::V2(2.0, 2.0));
		d.rotation_rad = double(p_displacement.get("rotation_deg", 0.0)) * 3.14159265358979323846 / 180.0;
		d.planar_offset_m = v2(p_displacement.get("planar_offset_m", Variant()), gads::V2());
		d.triplanar_sharpness = p_displacement.get("triplanar_sharpness", 4.0);
		d.detail_map = p_displacement.get("detail_height_map", -1);
		d.detail_height_m = p_displacement.get("detail_height_m", 0.0);
		d.detail_scale = p_displacement.get("detail_scale", 8.0);
		s.displacement = core_.add_displacement(d);
	}
	core_.add_surface(std::move(s));
}

void GADSTessellator::set_transform(const Transform3D &p_transform) {
	gads::Xform x;
	for (int i = 0; i < 3; i++) {
		for (int j = 0; j < 3; j++) {
			x.basis.m[i][j] = p_transform.basis.rows[i][j];
		}
	}
	x.origin = gads::V3(p_transform.origin.x, p_transform.origin.y, p_transform.origin.z);
	core_.set_transform(x);
}

void GADSTessellator::set_settings(const Dictionary &p_settings) {
	gads::Settings s;
	s.max_error = p_settings.get("max_error", s.max_error);
	s.min_edge_texels = p_settings.get("min_edge_texels", s.min_edge_texels);
	s.max_triangles = p_settings.get("max_triangles", s.max_triangles);
	s.max_level = p_settings.get("max_level", s.max_level);
	s.lock_borders = p_settings.get("lock_borders", s.lock_borders);
	s.weld_distance = p_settings.get("weld_distance", s.weld_distance);
	s.direction_mode = gads::DirectionMode(int(p_settings.get("direction_mode", int(s.direction_mode))));
	if (p_settings.has("direction")) {
		Vector3 d = p_settings["direction"];
		s.direction = gads::V3(d.x, d.y, d.z);
	}
	s.geometry_normals = p_settings.get("geometry_normals", s.geometry_normals);
	s.hard_angle_deg = p_settings.get("hard_angle_deg", s.hard_angle_deg);
	s.filter_heights = p_settings.get("filter_heights", s.filter_heights);
	s.threads = p_settings.get("threads", s.threads);
	core_.set_settings(s);
}

bool GADSTessellator::run() {
	// cancel_ is not reset: a cancel() that arrives before a worker thread gets to run() counts.
	done_ = false;
	ok_ = core_.run(cancel_, progress_, triangles_);
	done_ = true;
	return ok_;
}

void GADSTessellator::cancel() {
	cancel_ = true;
}

float GADSTessellator::get_progress() const {
	return progress_;
}

int GADSTessellator::get_triangle_count() const {
	return triangles_;
}

bool GADSTessellator::is_done() const {
	return done_;
}

static PackedFloat32Array floats(const std::vector<float> &v) {
	PackedFloat32Array out;
	out.resize(int64_t(v.size()));
	if (!v.empty()) {
		std::memcpy(out.ptrw(), v.data(), v.size() * sizeof(float));
	}
	return out;
}

Array GADSTessellator::get_surfaces() const {
	Array result;
	for (const gads::SurfaceOutput &o : core_.outputs()) {
		Array arrays;
		arrays.resize(ARRAY_MAX);
		size_t n = o.positions.size() / 3;
		PackedVector3Array vertices, normals;
		vertices.resize(int64_t(n));
		normals.resize(int64_t(n));
		for (size_t i = 0; i < n; i++) {
			vertices.set(int64_t(i), Vector3(o.positions[i * 3], o.positions[i * 3 + 1], o.positions[i * 3 + 2]));
			normals.set(int64_t(i), Vector3(o.normals[i * 3], o.normals[i * 3 + 1], o.normals[i * 3 + 2]));
		}
		arrays[ARRAY_VERTEX] = vertices;
		arrays[ARRAY_NORMAL] = normals;
		arrays[ARRAY_TANGENT] = floats(o.tangents);
		if (o.has_colors) {
			PackedColorArray colors;
			colors.resize(int64_t(n));
			for (size_t i = 0; i < n; i++) {
				colors.set(int64_t(i), Color(o.colors[i * 4], o.colors[i * 4 + 1], o.colors[i * 4 + 2], o.colors[i * 4 + 3]));
			}
			arrays[ARRAY_COLOR] = colors;
		}
		for (int ch = ARRAY_TEX_UV; ch <= ARRAY_TEX_UV2; ch++) {
			const std::vector<float> &src = ch == ARRAY_TEX_UV ? o.uv : o.uv2;
			if ((ch == ARRAY_TEX_UV ? o.has_uv : o.has_uv2)) {
				PackedVector2Array uv;
				uv.resize(int64_t(n));
				for (size_t i = 0; i < n; i++) {
					uv.set(int64_t(i), Vector2(src[i * 2], src[i * 2 + 1]));
				}
				arrays[ch] = uv;
			}
		}
		arrays[ARRAY_CUSTOM0] = floats(o.custom0);
		arrays[ARRAY_CUSTOM1] = floats(o.custom1);
		PackedInt32Array indices;
		indices.resize(int64_t(o.indices.size()));
		if (!o.indices.empty()) {
			std::memcpy(indices.ptrw(), o.indices.data(), o.indices.size() * sizeof(int));
		}
		arrays[ARRAY_INDEX] = indices;
		result.push_back(arrays);
	}
	return result;
}

Dictionary GADSTessellator::get_stats() const {
	const gads::Stats &s = core_.stats();
	Dictionary d;
	d["source_triangles"] = s.source_triangles;
	d["triangles"] = s.triangles;
	d["vertices"] = s.vertices;
	d["rounds"] = s.rounds;
	d["max_level"] = s.max_level;
	d["budget_reached"] = s.budget_reached;
	d["max_error_left"] = s.max_error_left;
	d["milliseconds"] = s.milliseconds;
	return d;
}

String GADSTessellator::get_error() const {
	return String(core_.error().c_str());
}

String GADSTessellator::get_build_hash() {
	return String(GADS_BUILD_HASH);
}

int GADSTessellator::get_algorithm_version() {
	return ALGORITHM_VERSION;
}

} // namespace godot
