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

// A layer of a layered GADS material: it covers the relief below where its mask is (a vertex
// colour channel times amount, times a band of the displacement direction's y), the higher
// relief winning within the mask (height-aware blending, as gads_height_blend() in the shaders).
struct Layer {
	int map = -1; // index into add_height_map(); -1 = none
	double height_m = 0.03;
	double scale = 1.0; // repeats per main repeat
	int mask_channel = 0; // 0-3: vertex colour R, G, B, A; 4: everywhere
	double amount = 0.0;
	V2 slope; // smoothstep band of the direction's y; off when y <= x
	double blend_width = 0.1;
};

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
	// Optional detail layer: detail_height_m * (d - 0.5), d sampled at uv * detail_scale.
	int detail_map = -1; // index into add_height_map(); -1 = none
	double detail_height_m = 0.0;
	double detail_scale = 8.0;
	Layer layers[2]; // layered materials: layers 1 and 2
	// Displacement mask: a vertex colour channel (0-3: R, G, B, A) scales the height relief (main,
	// detail and layers; not the vector offsets); -1: none.
	int relief_mask_channel = -1;
	// Optional vector displacement (UV mapping): an XYZ offset per texel, three maps (the x, y and z
	// channels), times vector_m metres; in tangent space (x along +u, y along the image's up, z
	// along the displacement direction, as OpenGL normal maps) or in object space. Signed values,
	// or 0..1 around 0.5 when !vector_signed.
	int vector_map[3] = { -1, -1, -1 };
	double vector_m = 0.0;
	int vector_space = 0; // 0: tangent, 1: object
	bool vector_signed = false;
};

struct SurfaceInput {
	std::vector<V3> positions;
	std::vector<V3> normals; // empty: face normals
	std::vector<V2> uv, uv2; // empty: absent
	std::vector<float> colors; // 4 per vertex, empty: absent
	// Skinning: bone_count (4 or 8) bone indices and weights per vertex; 0: not skinned.
	std::vector<int> bones;
	std::vector<float> weights;
	int bone_count = 0;
	// Blend shapes: per shape, each vertex's offset from the base (position and normal).
	std::vector<std::vector<V3>> shape_positions, shape_normals;
	std::vector<int> indices; // empty: unindexed triangles
	int displacement = -1; // index into add_displacement(); -1 = not displaced
};

struct SurfaceOutput {
	std::vector<float> positions, normals, tangents, uv, uv2, colors, custom0, custom1;
	std::vector<int> indices;
	std::vector<int> bones; // bone_count per vertex (skinned surfaces)
	std::vector<float> weights;
	int bone_count = 0;
	// Per blend shape: each vertex's position and normal in that shape (3 floats each).
	std::vector<std::vector<float>> shape_positions, shape_normals;
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
	// Curvature-aware subdivision, 0..1: a vertex added on an edge whose normals agree on both
	// sides moves this far towards the circular arc its corner normals describe, and that curvature
	// counts in the refinement error, so low-poly curved meshes come out round (spheres and
	// cylinders exactly). 0: new vertices stay on the source's flat triangles. Hard edges stay sharp.
	double smooth_shape = 0.0;
	bool filter_heights = true; // where refinement stopped early: heights at each vertex's footprint
	int threads = 0; // 0: hardware concurrency
	// View-dependent refinement (runtime tessellation): a triangle's tolerance grows with its
	// distance from view_position (world) so its error stays under pixel_error pixels on screen,
	// focal_px being the pixels per radian (viewport height / (2 tan(fov / 2))); max_error stays
	// the finest tolerance. No edge is split below min_edge_pixels on screen, and the budget goes
	// to the triangles with the largest error on screen first.
	bool view_dependent = false;
	V3 view_position;
	double pixel_error = 1.0;
	double focal_px = 1000.0;
	double min_edge_pixels = 2.0;
};

struct Stats {
	int source_triangles = 0;
	int triangles = 0;
	int vertices = 0;
	int rounds = 0;
	int max_level = 0;
	bool budget_reached = false;
	double max_error_left = 0.0; // m, of triangles that may still need refinement
	double max_pixels_left = 0.0; // view-dependent: the same on screen (pixels at the triangle's distance)
	double milliseconds = 0.0;
};

class Tessellator {
public:
	int add_height_map(int width, int height, std::vector<float> data);
	// Optional sculpt offsets (m, along the displacement direction) added on every surface: map
	// `map` (from add_height_map) in the source mesh's own first UVs (0..1, clamped at the edges;
	// no material transform), raw values in metres. -1 = none.
	void set_offset_map(int map) { offset_map_ = map; }
	// Blend shapes of surface `surface` (added before): per shape, every vertex's position and
	// normal, absolute or (relative) offsets from the base.
	void set_blend_shapes(int surface, std::vector<std::vector<V3>> positions, std::vector<std::vector<V3>> normals, bool relative);
	int add_displacement(const Displacement &d);
	void add_surface(SurfaceInput s);
	void set_transform(const Xform &x) { xform_ = x; }
	void set_settings(const Settings &s) { settings_ = s; }

	// Blocking. Returns false when cancelled or when the input is unusable (see error()).
	bool run(const std::atomic<bool> &cancel, std::atomic<float> &progress, std::atomic<int> &triangles);

	const std::vector<SurfaceOutput> &outputs() const { return outputs_; }
	// The outputs split into spatial clusters of at most max_triangles (all surfaces together,
	// median splits along the longest axis): clusters()[c][s] is surface s's part of cluster c
	// (no indices where cluster c has none of it). After run().
	std::vector<std::vector<SurfaceOutput>> clusters(int max_triangles) const;
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
		V3 tu, tv; // world directions of +u and of the image's up (-v), for vector displacement
		V3 vec; // the vector displacement here (world, m, mip 0)
	};
	struct Tri {
		int c[3];
		int surface = 0;
		int level = 0;
		float error = 0.0f;
		float tol = 0.0f; // its tolerance (m): max_error, or more far from the view
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
	double sample_displacement(int surface, const V3 &world, const V3 &dir, const V2 &uv, double lod, const float color[4]) const;
	double relief_at(const Displacement &d, const V2 &uv, double lod, const double masks[2]) const;
	bool has_detail(const Displacement &d) const { return d.detail_map >= 0 && d.detail_height_m > 0.0; }
	bool has_layer(const Displacement &d, int k) const { return d.layers[k].map >= 0 && d.layers[k].amount > 0.0; }
	bool has_vector(const Displacement &d) const { return d.vector_map[0] >= 0 && d.vector_m != 0.0 && d.mapping == MAPPING_UV; }
	double vector_texels(const Displacement &d) const;
	bool has_offset() const { return offset_map_ >= 0 && size_t(offset_map_) < maps_.size(); }
	double offset_at(const V2 &uv) const;
	double offset_bound(const V2 uv[3], const V3 world[3], double &r_longest_texels) const;
	double offset_texel_size_m(int t) const;
	float scan_error(int t, double longest_texels, bool vector) const;
	V3 vector_displacement(int surface, const V2 &uv, const V3 &dir, const V3 &tu, const V3 &tv, double lod) const;
	V3 corner_vec(const Corner &c) const;
	double detail_texels(const Displacement &d) const;
	double layer_texels(const Displacement &d, int k) const;
	double finest_texels(const Displacement &d) const;
	void layer_masks(const Displacement &d, const float color[4], const V3 &dir, double r_masks[2]) const;
	static double relief_mask(const Displacement &d, const float color[4]);
	double corner_h(const Corner &c) const;
	float tri_error(int t, double tol) const;
	float relief_error(int t, double tol) const;
	// How far (object space) the curved surface lies from the straight edge between corners ca and
	// cb at its middle, as smooth_shape moves a vertex added there.
	V3 curve_offset(int ca, int cb) const;
	// The largest curve_offset over a triangle's edges, in world metres.
	double curvature_error(int t) const;
	double tri_tolerance(int t) const;
	double view_distance(int t) const;
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
	int offset_map_ = -1;
	std::vector<Displacement> displacements_;
	std::vector<SurfaceInput> inputs_;
	std::vector<Group> groups_;
	std::vector<Corner> corners_;
	// Skinning of each corner (parallel to corners_ when a surface is skinned, else empty): its
	// bone_count strongest influences, weights summing to 1.
	struct Skin {
		int b[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
		float w[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
	};
	std::vector<Skin> skins_;
	static Skin mix_skins(const Skin &x, const Skin &y, int count);
	// Each corner as a blend of its surface's source vertices (parallel to corners_ when a
	// surface has blend shapes, else empty): every corner of a source triangle is one of its
	// three vertices' blends, so three entries suffice.
	struct Blend {
		int v[3] = { -1, -1, -1 };
		float w[3] = { 0, 0, 0 };
	};
	std::vector<Blend> blends_;
	static Blend mix_blends(const Blend &x, const Blend &y);
	std::vector<Tri> tris_;
	EdgeTable edges_;
	std::vector<std::vector<int>> extra_;
	std::vector<SurfaceOutput> outputs_;
	Stats stats_;
	std::string error_;
	bool axis_directions_ = false;
};

} // namespace gads
