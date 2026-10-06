#include "gads_height_generator.h"

#include "proc/erosion.h"
#include "proc/height_gen.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstring>
#include <vector>

namespace godot {

void GADSHeightGenerator::_bind_methods() {
	ClassDB::bind_static_method("GADSHeightGenerator", D_METHOD("get_kinds"), &GADSHeightGenerator::get_kinds);
	ClassDB::bind_static_method("GADSHeightGenerator", D_METHOD("generate", "kind", "size", "params"), &GADSHeightGenerator::generate, DEFVAL(Dictionary()));
	ClassDB::bind_static_method("GADSHeightGenerator", D_METHOD("normal_map", "height", "depth_m", "tile_m"), &GADSHeightGenerator::normal_map);
	ClassDB::bind_static_method("GADSHeightGenerator", D_METHOD("ambient_occlusion", "height", "depth_m", "tile_m", "radius_m"), &GADSHeightGenerator::ambient_occlusion);
	ClassDB::bind_static_method("GADSHeightGenerator", D_METHOD("curvature", "height", "radius_texels", "gain"), &GADSHeightGenerator::curvature, DEFVAL(4.0f));
	ClassDB::bind_static_method("GADSHeightGenerator", D_METHOD("albedo_map", "height", "low", "high", "ao", "curvature", "ao_strength", "cavity_strength"),
			&GADSHeightGenerator::albedo_map, DEFVAL(Ref<Image>()), DEFVAL(Ref<Image>()), DEFVAL(0.6f), DEFVAL(0.5f));
	ClassDB::bind_static_method("GADSHeightGenerator", D_METHOD("orm_map", "ao", "curvature", "roughness", "variation"), &GADSHeightGenerator::orm_map,
			DEFVAL(0.85f), DEFVAL(0.15f));
	ClassDB::bind_static_method("GADSHeightGenerator", D_METHOD("erode", "height", "params"), &GADSHeightGenerator::erode, DEFVAL(Dictionary()));
}

static Ref<Image> image_of(int p_w, int p_h, Image::Format p_format, const std::vector<float> &p_values) {
	PackedByteArray bytes;
	bytes.resize(int64_t(p_values.size() * sizeof(float)));
	std::memcpy(bytes.ptrw(), p_values.data(), p_values.size() * sizeof(float));
	return Image::create_from_data(p_w, p_h, false, p_format, bytes);
}

// The red channel of an image as floats (decompressed, mip 0).
static bool heights_of(const Ref<Image> &p_image, std::vector<float> &r_values, int &r_w, int &r_h) {
	ERR_FAIL_COND_V_MSG(p_image.is_null() || p_image->is_empty(), false, "GADSHeightGenerator: empty height image.");
	Ref<Image> img = Image::create_from_data(p_image->get_width(), p_image->get_height(), p_image->has_mipmaps(), p_image->get_format(), p_image->get_data());
	if (img->is_compressed()) {
		img->decompress();
	}
	img->clear_mipmaps();
	img->convert(Image::FORMAT_RF);
	r_w = img->get_width();
	r_h = img->get_height();
	r_values.resize(size_t(r_w) * r_h);
	PackedByteArray bytes = img->get_data();
	ERR_FAIL_COND_V(size_t(bytes.size()) < r_values.size() * sizeof(float), false);
	std::memcpy(r_values.data(), bytes.ptr(), r_values.size() * sizeof(float));
	return true;
}

PackedStringArray GADSHeightGenerator::get_kinds() {
	PackedStringArray out;
	for (const std::string &k : gads::generator_kinds()) {
		out.push_back(String(k.c_str()));
	}
	return out;
}

Ref<Image> GADSHeightGenerator::generate(const String &p_kind, int p_size, const Dictionary &p_params) {
	gads::GenParams p;
	p.seed = p_params.get("seed", p.seed);
	p.scale = p_params.get("scale", p.scale);
	p.octaves = p_params.get("octaves", p.octaves);
	p.gain = p_params.get("gain", p.gain);
	p.lacunarity = p_params.get("lacunarity", p.lacunarity);
	p.warp = p_params.get("warp", p.warp);
	p.width = p_params.get("width", p.width);
	p.bevel = p_params.get("bevel", p.bevel);
	p.variation = p_params.get("variation", p.variation);
	p.aspect = p_params.get("aspect", p.aspect);
	p.roughness = p_params.get("roughness", p.roughness);
	p.sharpness = p_params.get("sharpness", p.sharpness);
	p.count = p_params.get("count", p.count);
	std::string error;
	std::vector<float> h = gads::generate(p_kind.utf8().get_data(), p_size, p, int(p_params.get("threads", 0)), error);
	ERR_FAIL_COND_V_MSG(h.empty(), Ref<Image>(), String("GADSHeightGenerator: ") + error.c_str() + ".");
	return image_of(p_size, p_size, Image::FORMAT_RF, h);
}

Ref<Image> GADSHeightGenerator::normal_map(const Ref<Image> &p_height, float p_depth_m, const Vector2 &p_tile_m) {
	std::vector<float> h;
	int w, ht;
	if (!heights_of(p_height, h, w, ht)) {
		return Ref<Image>();
	}
	std::vector<float> n = gads::normal_map(h, w, ht, p_depth_m, p_tile_m.x, p_tile_m.y, 0);
	Ref<Image> img = image_of(w, ht, Image::FORMAT_RGBF, n);
	img->convert(Image::FORMAT_RGB8);
	return img;
}

Ref<Image> GADSHeightGenerator::ambient_occlusion(const Ref<Image> &p_height, float p_depth_m, const Vector2 &p_tile_m, float p_radius_m) {
	std::vector<float> h;
	int w, ht;
	if (!heights_of(p_height, h, w, ht)) {
		return Ref<Image>();
	}
	return image_of(w, ht, Image::FORMAT_RF, gads::ambient_occlusion(h, w, ht, p_depth_m, p_tile_m.x, p_tile_m.y, p_radius_m, 0));
}

Ref<Image> GADSHeightGenerator::curvature(const Ref<Image> &p_height, float p_radius_texels, float p_gain) {
	std::vector<float> h;
	int w, ht;
	if (!heights_of(p_height, h, w, ht)) {
		return Ref<Image>();
	}
	return image_of(w, ht, Image::FORMAT_RF, gads::curvature(h, w, ht, p_radius_texels, p_gain, 0));
}

// An optional image's red channel at w x h (resized when it differs), or empty.
static std::vector<float> optional_heights(const Ref<Image> &p_image, int p_w, int p_h) {
	std::vector<float> out;
	if (p_image.is_null() || p_image->is_empty()) {
		return out;
	}
	Ref<Image> img = p_image;
	if (img->get_width() != p_w || img->get_height() != p_h) {
		img = Image::create_from_data(p_image->get_width(), p_image->get_height(), p_image->has_mipmaps(), p_image->get_format(), p_image->get_data());
		if (img->is_compressed()) {
			img->decompress();
		}
		img->resize(p_w, p_h, Image::INTERPOLATE_BILINEAR);
	}
	int w, h;
	if (!heights_of(img, out, w, h)) {
		out.clear();
	}
	return out;
}

Ref<Image> GADSHeightGenerator::albedo_map(const Ref<Image> &p_height, const Color &p_low, const Color &p_high, const Ref<Image> &p_ao, const Ref<Image> &p_curvature,
		float p_ao_strength, float p_cavity_strength) {
	std::vector<float> h;
	int w, ht;
	if (!heights_of(p_height, h, w, ht)) {
		return Ref<Image>();
	}
	const float low[3] = { p_low.r, p_low.g, p_low.b };
	const float high[3] = { p_high.r, p_high.g, p_high.b };
	std::vector<float> rgb = gads::colorize(h, optional_heights(p_ao, w, ht), optional_heights(p_curvature, w, ht), low, high, p_ao_strength, p_cavity_strength);
	Ref<Image> img = image_of(w, ht, Image::FORMAT_RGBF, rgb);
	img->convert(Image::FORMAT_RGB8);
	return img;
}

Ref<Image> GADSHeightGenerator::orm_map(const Ref<Image> &p_ao, const Ref<Image> &p_curvature, float p_roughness, float p_variation) {
	Ref<Image> size_of = p_ao.is_valid() && !p_ao->is_empty() ? p_ao : p_curvature;
	ERR_FAIL_COND_V_MSG(size_of.is_null() || size_of->is_empty(), Ref<Image>(), "GADSHeightGenerator: orm_map needs an occlusion or a curvature image.");
	int w = size_of->get_width(), ht = size_of->get_height();
	std::vector<float> rgb = gads::orm(optional_heights(p_ao, w, ht), optional_heights(p_curvature, w, ht), size_t(w) * ht, p_roughness, p_variation);
	Ref<Image> img = image_of(w, ht, Image::FORMAT_RGBF, rgb);
	img->convert(Image::FORMAT_RGB8);
	return img;
}

// Hydraulic, then thermal erosion of the red channel (see proc/erosion.h); FORMAT_RF.
Ref<Image> GADSHeightGenerator::erode(const Ref<Image> &p_height, const Dictionary &p_params) {
	std::vector<float> h;
	int w, ht;
	if (!heights_of(p_height, h, w, ht)) {
		return Ref<Image>();
	}
	gads::ErosionParams p;
	p.droplets = p_params.get("droplets", p.droplets);
	p.seed = p_params.get("seed", p.seed);
	p.max_steps = p_params.get("max_steps", p.max_steps);
	p.inertia = p_params.get("inertia", p.inertia);
	p.capacity = p_params.get("capacity", p.capacity);
	p.min_capacity = p_params.get("min_capacity", p.min_capacity);
	p.erosion = p_params.get("erosion", p.erosion);
	p.deposition = p_params.get("deposition", p.deposition);
	p.evaporation = p_params.get("evaporation", p.evaporation);
	p.gravity = p_params.get("gravity", p.gravity);
	p.radius = p_params.get("radius", p.radius);
	p.thermal_iterations = p_params.get("thermal_iterations", p.thermal_iterations);
	p.talus_deg = p_params.get("talus_deg", p.talus_deg);
	p.thermal_rate = p_params.get("thermal_rate", p.thermal_rate);
	p.cell_m = p_params.get("cell_m", p.cell_m);
	p.height_m = p_params.get("height_m", p.height_m);
	p.wrap = p_params.get("wrap", p.wrap);
	gads::erode(h, w, ht, p);
	return image_of(w, ht, Image::FORMAT_RF, h);
}

} // namespace godot
