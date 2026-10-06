// Procedural height fields and the maps derived from height fields (engine-independent).
//
// Every field is `size` x `size` floats, row-major, normalised to 0..1 (1 = top) and periodic:
// it tiles without a seam, because every pattern repeats a whole number of times per tile
// (lattice noise with a period, Voronoi points on a wrapped grid, integer wave vectors, distances
// measured on the torus). The same seed and parameters give the same field on any thread count.
#pragma once

#include <string>
#include <vector>

namespace gads {

struct GenParams {
	int seed = 1;
	double scale = 4.0; // features per tile (noise cells, stones, brick rows, wave frequency)
	int octaves = 5; // noise octaves
	double gain = 0.5; // amplitude factor per octave
	double lacunarity = 2.0; // frequency factor per octave (rounded so every octave tiles)
	double warp = 0.0; // domain warp, in features
	double width = 0.08; // gaps, mortar, cracks (in features)
	double bevel = 0.2; // rounding of stones, bricks and tiles (in features)
	double variation = 0.3; // height variation between stones, bricks or tiles (0..1)
	double aspect = 2.0; // bricks: length / height
	double roughness = 0.05; // fine noise on top of stones, cracks, bricks, tiles and craters (0..1)
	double sharpness = 0.3; // waves: how sharp the crests are (0..1)
	int count = 0; // craters and ripple centres (0 = from scale)
};

// The kinds generate() knows.
const std::vector<std::string> &generator_kinds();

// A field of `kind` (see generator_kinds()); empty with `error` set when the kind is unknown or
// the size is not 4..8192.
std::vector<float> generate(const std::string &kind, int size, const GenParams &p, int threads, std::string &error);

// Tangent-space normals (OpenGL: x along +u, y along -v, z out) of a height field `w` x `h`
// whose 0..1 range spans `depth_m` metres over a tile of `tile_x_m` x `tile_y_m`; RGB 0..1
// interleaved (n * 0.5 + 0.5). Central differences, wrapped.
std::vector<float> normal_map(const std::vector<float> &height, int w, int h, double depth_m, double tile_x_m, double tile_y_m, int threads);

// Ambient occlusion from the height field's horizon: for each texel, the average over 8
// directions of 1 - sin(horizon elevation) within `radius_m` (wrapped). 1 = open, 0 = closed.
std::vector<float> ambient_occlusion(const std::vector<float> &height, int w, int h, double depth_m, double tile_x_m, double tile_y_m, double radius_m, int threads);

// Curvature: 0.5 + gain * (height - its average over a disc of `radius` texels), clamped to
// 0..1 (> 0.5 convex: crests and edges; < 0.5 concave: hollows and cracks). Wrapped.
std::vector<float> curvature(const std::vector<float> &height, int w, int h, double radius, double gain, int threads);

// Albedo from a height field: `low` to `high` colour (RGB 0..1) by height, darkened by
// occlusion (1 - ao_strength * (1 - ao)) and in hollows (curvature below 0.5, by
// cavity_strength). `ao` and `curv` may be empty. RGB interleaved.
std::vector<float> colorize(const std::vector<float> &height, const std::vector<float> &ao, const std::vector<float> &curv, const float low[3],
		const float high[3], double ao_strength, double cavity_strength);

// ORM (R occlusion, G roughness, B metallic 0) from occlusion and curvature (either may be
// empty): roughness `roughness`, lower on crests and higher in hollows by `variation`.
std::vector<float> orm(const std::vector<float> &ao, const std::vector<float> &curv, size_t count, double roughness, double variation);

} // namespace gads
