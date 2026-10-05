// GADS adaptive displacement tessellator (engine-independent C++).
//
// Takes a triangle mesh (any number of surfaces), the height maps and mappings that displace it
// (the GADS material parameters) and an object -> world transform; returns the displaced mesh,
// refined only where the height field needs it:
//
// - Topology on welded positions: corners at the same position (UV seams, hard edges, surface
//   borders) form one position group, and edges are keyed by groups. A split creates one
//   midpoint group for every triangle on the edge, while each side of a seam keeps its own
//   attributes. Both sides refine identically: no cracks or T-junctions by construction.
// - Rivara longest-edge bisection: a triangle is split across its longest edge, after its
//   neighbour across that edge has been brought to the same edge (longest-edge propagation).
//   The mesh stays conforming and the angles stay bounded.
// - Error: how far a triangle's own height field deviates from the linear interpolation of its
//   corners (the geometric error the triangle would show), in metres. Flat and evenly sloped
//   regions stay coarse, cracks and edges get dense. A min / max pyramid gives a conservative
//   bound first, so large flat regions are not scanned texel by texel.
// - Budget: rounds refine the worst triangles first; the triangle budget stops it.
// - Where refinement stopped before the tolerance (budget, smallest edge, deepest level), final
//   heights are filtered to each vertex's footprint (trilinear) so they do not alias. Normals are
//   rebuilt from the displaced faces keeping the source's hard edges, tangents by MikkTSpace.
#pragma once

#include "height_map.h"
#include "math.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace gads {

enum Mapping { MAPPING_UV = 0,
	MAPPING_WORLD = 1,
	MAPPING_TRIPLANAR = 2 };

// The displacement of one surface: the GADS material parameters that place its height map.
struct Displacement {
	int height_map = -1; // index into add_height_map(); -1 = not displaced
	Mapping mapping = MAPPING_UV;
	double height_m = 0.03;
	double center = 1.0;
	V2 remap = V2(0.0, 1.0);
	V2 uv_scale = V2(1.0, 1.0);
	V2 uv_offset;
	V2 texture_size_m = V2(2.0, 2.0);
	double rotation_rad = 0.0;
	V2 planar_offset_m;
	double triplanar_sharpness = 4.0;
};

struct SurfaceInput {
	std::vector<V3> positions;
	std::vector<V3> normals; // empty: face normals
	std::vector<V2> uv, uv2; // empty: absent
	std::vector<float> colors; // 4 per vertex, empty: absent
	std::vector<int> indices; // empty: unindexed triangles
	int displacement = -1; // index into add_displacement(); -1 = not displaced
};

struct SurfaceOutput {
	std::vector<float> positions, normals, tangents, uv, uv2, colors, custom0, custom1;
	std::vector<int> indices;
	bool has_uv = false, has_uv2 = false, has_colors = false;
};

enum DirectionMode { DIRECTION_AUTO = 0,
	DIRECTION_NORMAL = 1,
	DIRECTION_AXIS = 2 };

struct Settings {
	double max_error = 0.0005; // m
	double min_edge_texels = 1.0; // no edge is split below this many texels
	int max_triangles = 500000;
	int max_level = 24; // bisections from a source triangle
	bool lock_borders = false; // open boundary edges keep their position
	double weld_distance = -1.0; // m; < 0: 1e-6 of the mesh size
	DirectionMode direction_mode = DIRECTION_AUTO;
	V3 direction = V3(0.0, 1.0, 0.0); // world, for DIRECTION_AXIS
	bool geometry_normals = true; // false: interpolate the source normals
	double hard_angle_deg = 30.0; // source normals further apart than this stay split
	bool filter_heights = true; // where refinement stopped early: heights at each vertex's footprint
	int threads = 0; // 0: hardware concurrency
};

struct Stats {
	int source_triangles = 0;
	int triangles = 0;
	int vertices = 0;
	int rounds = 0;
	int max_level = 0;
	bool budget_reached = false;
	double max_error_left = 0.0; // m, of triangles that may still need refinement
	double milliseconds = 0.0;
};

class Tessellator {
public:
	int add_height_map(int width, int height, std::vector<float> data);
	int add_displacement(const Displacement &d);
	void add_surface(SurfaceInput s);
	void set_transform(const Xform &x) { xform_ = x; }
	void set_settings(const Settings &s) { settings_ = s; }

	// Blocking. Returns false when cancelled or when the input is unusable (see error()).
	bool run(const std::atomic<bool> &cancel, std::atomic<float> &progress, std::atomic<int> &triangles);

	const std::vector<SurfaceOutput> &outputs() const { return outputs_; }
	const Stats &stats() const { return stats_; }
	const std::string &error() const { return error_; }

private:
	struct Group {
		V3 rest; // object space
		V3 world; // world space
		V3 dir; // displacement direction, world, unit
		bool locked = false;
		int level = 0;
	};
	struct Corner { // a vertex with its attributes; corners of one group differ at seams
		int group = 0;
		int surface = 0;
		V3 normal;
		V2 uv, uv2;
		float color[4] = { 1, 1, 1, 1 };
		double h = 0.0; // the surface's own displacement here (m, mip 0)
	};
	struct Tri {
		int c[3];
		int surface = 0;
		int level = 0;
		float error = 0.0f;
		bool alive = true;
	};
	struct EdgeRec {
		int t[2] = { -1, -1 };
		int more = -1; // index into extra_ for non-manifold edges
	};

	// Open-addressing table: edge key -> incident triangles.
	class EdgeTable {
	public:
		void reserve(size_t n);
		EdgeRec *find(uint64_t key);
		void add(uint64_t key, int tri, std::vector<std::vector<int>> &extra);
		void remove_tri(uint64_t key, int tri, std::vector<std::vector<int>> &extra);
		void erase(uint64_t key);
		size_t size() const { return count_; }

	private:
		static constexpr uint64_t EMPTY = 0, DEAD = ~uint64_t(0);
		std::vector<uint64_t> keys_;
		std::vector<EdgeRec> vals_;
		size_t count_ = 0, used_ = 0;
		size_t slot(uint64_t key) const;
		void grow();
		void rehash(size_t cap);
	};

	bool build_topology();
	double sample_displacement(int surface, const V3 &world, const V3 &dir, const V2 &uv, double lod) const;
	double corner_h(const Corner &c) const;
	float tri_error(int t) const;
	double texel_size_m(int t) const;
	double edge_len2(int ga, int gb) const { return (groups_[ga].world - groups_[gb].world).length_squared(); }
	bool edge_less(int ga, int gb, int ha, int hb) const;
	int longest_edge(int t) const;
	void split_edge(int ga, int gb);
	void refine(int t);
	int new_tri(int c0, int c1, int c2, int surface, int level);
	void evaluate(const std::vector<int> &tris);
	void build_outputs();

	Xform xform_;
	M3 normal_matrix_; // world normal = normal_matrix_ * object normal
	M3 world_to_object_;
	Settings settings_;
	std::vector<std::unique_ptr<HeightMap>> maps_;
	std::vector<Displacement> displacements_;
	std::vector<SurfaceInput> inputs_;
	std::vector<Group> groups_;
	std::vector<Corner> corners_;
	std::vector<Tri> tris_;
	EdgeTable edges_;
	std::vector<std::vector<int>> extra_;
	std::vector<SurfaceOutput> outputs_;
	Stats stats_;
	std::string error_;
	bool axis_directions_ = false;
};

} // namespace gads
