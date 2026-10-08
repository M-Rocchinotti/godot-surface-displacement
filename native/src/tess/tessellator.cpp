#include "tessellator.h"

#include "parallel.h"

extern "C" {
#include "mikktspace.h"
}

#include <algorithm>
#include <chrono>
#include <cmath>

namespace gads {

static constexpr double PI = 3.14159265358979323846;
// A triangle whose edges span more texels than this is not scanned: its min / max bound decides.
static constexpr double SCAN_LIMIT_TEXELS = 64.0;

// --- Edge table --------------------------------------------------------------------------------

void Tessellator::EdgeTable::rehash(size_t cap) {
	std::vector<uint64_t> old_keys = std::move(keys_);
	std::vector<EdgeRec> old_vals = std::move(vals_);
	keys_.assign(cap, EMPTY);
	vals_.assign(cap, EdgeRec());
	count_ = used_ = 0;
	for (size_t i = 0; i < old_keys.size(); i++) {
		if (old_keys[i] != EMPTY && old_keys[i] != DEAD) {
			size_t s = slot(old_keys[i]);
			keys_[s] = old_keys[i];
			vals_[s] = old_vals[i];
			count_++;
			used_++;
		}
	}
}

void Tessellator::EdgeTable::reserve(size_t n) {
	size_t cap = 16;
	while (cap < n * 2) {
		cap <<= 1;
	}
	if (cap > keys_.size()) {
		rehash(cap);
	}
}

size_t Tessellator::EdgeTable::slot(uint64_t key) const {
	// The first slot holding the key, else the first empty one (tombstones are skipped).
	uint64_t h = key * 0x9E3779B97F4A7C15ull;
	size_t mask = keys_.size() - 1;
	size_t i = size_t(h >> 17) & mask;
	while (keys_[i] != EMPTY && keys_[i] != key) {
		i = (i + 1) & mask;
	}
	return i;
}

void Tessellator::EdgeTable::grow() {
	// Live keys and tombstones both lengthen probes; a rehash drops the tombstones, at the same
	// size when they are most of the load.
	if (keys_.empty()) {
		rehash(64);
	} else if ((used_ + 1) * 10 > keys_.size() * 7) {
		rehash((count_ + 1) * 10 > keys_.size() * 5 ? keys_.size() * 2 : keys_.size());
	}
}

Tessellator::EdgeRec *Tessellator::EdgeTable::find(uint64_t key) {
	if (keys_.empty()) {
		return nullptr;
	}
	size_t s = slot(key);
	return keys_[s] == key ? &vals_[s] : nullptr;
}

void Tessellator::EdgeTable::add(uint64_t key, int tri, std::vector<std::vector<int>> &extra) {
	grow();
	size_t s = slot(key);
	if (keys_[s] != key) {
		keys_[s] = key;
		vals_[s] = EdgeRec();
		count_++;
		used_++;
	}
	EdgeRec &r = vals_[s];
	if (r.t[0] < 0) {
		r.t[0] = tri;
	} else if (r.t[1] < 0) {
		r.t[1] = tri;
	} else {
		if (r.more < 0) {
			r.more = int(extra.size());
			extra.emplace_back();
		}
		extra[r.more].push_back(tri);
	}
}

void Tessellator::EdgeTable::remove_tri(uint64_t key, int tri, std::vector<std::vector<int>> &extra) {
	EdgeRec *r = find(key);
	if (r == nullptr) {
		return;
	}
	if (r->t[0] == tri) {
		r->t[0] = r->t[1];
		r->t[1] = -1;
	} else if (r->t[1] == tri) {
		r->t[1] = -1;
	} else if (r->more >= 0) {
		std::vector<int> &m = extra[r->more];
		m.erase(std::remove(m.begin(), m.end(), tri), m.end());
	}
	// Keep the two inline slots filled first.
	if (r->more >= 0 && !extra[r->more].empty() && (r->t[0] < 0 || r->t[1] < 0)) {
		int moved = extra[r->more].back();
		extra[r->more].pop_back();
		(r->t[0] < 0 ? r->t[0] : r->t[1]) = moved;
	}
	if (r->t[0] < 0 && r->t[1] >= 0) {
		r->t[0] = r->t[1];
		r->t[1] = -1;
	}
	if (r->t[0] < 0 && (r->more < 0 || extra[r->more].empty())) {
		erase(key);
	}
}

void Tessellator::EdgeTable::erase(uint64_t key) {
	if (keys_.empty()) {
		return;
	}
	size_t s = slot(key);
	if (keys_[s] == key) {
		keys_[s] = DEAD;
		count_--;
	}
}

// --- Input -------------------------------------------------------------------------------------

int Tessellator::add_height_map(int width, int height, std::vector<float> data) {
	maps_.push_back(std::make_unique<HeightMap>(width, height, std::move(data)));
	return int(maps_.size()) - 1;
}

int Tessellator::add_displacement(const Displacement &d) {
	displacements_.push_back(d);
	return int(displacements_.size()) - 1;
}

void Tessellator::add_surface(SurfaceInput s) {
	inputs_.push_back(std::move(s));
}

void Tessellator::set_blend_shapes(int surface, std::vector<std::vector<V3>> positions, std::vector<std::vector<V3>> normals, bool relative) {
	if (surface < 0 || size_t(surface) >= inputs_.size()) {
		return;
	}
	SurfaceInput &s = inputs_[surface];
	normals.resize(positions.size());
	for (size_t k = 0; k < positions.size(); k++) {
		positions[k].resize(s.positions.size());
		normals[k].resize(s.positions.size());
		if (!relative) {
			// Offsets from the base (a shape without normals keeps the base's).
			bool has_normals = false;
			for (const V3 &v : normals[k]) {
				has_normals = has_normals || v.length_squared() > 0.0;
			}
			for (size_t i = 0; i < s.positions.size(); i++) {
				positions[k][i] = positions[k][i] - s.positions[i];
				normals[k][i] = has_normals && i < s.normals.size() ? normals[k][i] - s.normals[i] : V3();
			}
		}
	}
	s.shape_positions = std::move(positions);
	s.shape_normals = std::move(normals);
}

// --- Topology ----------------------------------------------------------------------------------

namespace {
struct CellKey {
	int64_t x, y, z;
	bool operator==(const CellKey &o) const { return x == o.x && y == o.y && z == o.z; }
};
struct CellHash {
	size_t operator()(const CellKey &k) const {
		uint64_t h = uint64_t(k.x) * 0x9E3779B97F4A7C15ull ^ uint64_t(k.y) * 0xC2B2AE3D27D4EB4Full ^ uint64_t(k.z) * 0x165667B19E3779F9ull;
		return size_t(h ^ (h >> 31));
	}
};
} // namespace

bool Tessellator::build_topology() {
	normal_matrix_ = xform_.basis.inverse().transposed();
	world_to_object_ = xform_.basis.inverse();
	if (std::fabs(xform_.basis.determinant()) < 1e-20) {
		error_ = "the transform has no volume (zero scale)";
		return false;
	}
	for (const Displacement &d : displacements_) {
		bool main_ok = d.height_map >= 0 && size_t(d.height_map) < maps_.size();
		bool detail_ok = d.detail_map < 0 || size_t(d.detail_map) < maps_.size();
		for (const Layer &l : d.layers) {
			detail_ok = detail_ok && (l.map < 0 || size_t(l.map) < maps_.size());
		}
		for (int k = 0; k < 3; k++) {
			detail_ok = detail_ok && (d.vector_map[0] < 0 || (d.vector_map[k] >= 0 && size_t(d.vector_map[k]) < maps_.size()));
		}
		if (!main_ok || !detail_ok) {
			error_ = "a displacement refers to a height map that was not added";
			return false;
		}
	}
	for (const SurfaceInput &s : inputs_) {
		if (s.displacement >= int(displacements_.size())) {
			error_ = "a surface refers to a displacement that was not added";
			return false;
		}
	}
	// Mesh size, for the default weld distance.
	V3 lo(1e300, 1e300, 1e300), hi(-1e300, -1e300, -1e300);
	size_t vertex_count = 0;
	for (const SurfaceInput &s : inputs_) {
		for (const V3 &p : s.positions) {
			lo = V3(std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z));
			hi = V3(std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z));
		}
		vertex_count += s.positions.size();
	}
	if (vertex_count == 0) {
		error_ = "the mesh has no vertices";
		return false;
	}
	double diag = (hi - lo).length();
	double eps = settings_.weld_distance >= 0.0 ? settings_.weld_distance : std::max(diag * 1e-6, 1e-9);
	double cell = std::max(eps, 1e-12);

	bool skinned = false;
	for (const SurfaceInput &s : inputs_) {
		skinned = skinned || (s.bone_count > 0 && s.bones.size() >= s.positions.size() * size_t(s.bone_count) &&
										   s.weights.size() >= s.positions.size() * size_t(s.bone_count));
	}
	skins_.clear();
	bool shaped = false;
	for (const SurfaceInput &s : inputs_) {
		shaped = shaped || !s.shape_positions.empty();
	}
	blends_.clear();

	// Corners (one per source vertex) and position groups (corners within eps share one).
	std::unordered_map<CellKey, std::vector<int>, CellHash> cells;
	cells.reserve(vertex_count);
	std::vector<int> corner_base(inputs_.size(), 0);
	bool all_world = true, any_displaced = false;
	for (size_t si = 0; si < inputs_.size(); si++) {
		const SurfaceInput &s = inputs_[si];
		corner_base[si] = int(corners_.size());
		if (s.displacement >= 0) {
			any_displaced = true;
			all_world = all_world && displacements_[s.displacement].mapping == MAPPING_WORLD;
		}
		for (size_t vi = 0; vi < s.positions.size(); vi++) {
			const V3 &p = s.positions[vi];
			CellKey k{ (int64_t)std::floor(p.x / cell), (int64_t)std::floor(p.y / cell), (int64_t)std::floor(p.z / cell) };
			int group = -1;
			for (int dz = -1; dz <= 1 && group < 0; dz++) {
				for (int dy = -1; dy <= 1 && group < 0; dy++) {
					for (int dx = -1; dx <= 1 && group < 0; dx++) {
						auto it = cells.find(CellKey{ k.x + dx, k.y + dy, k.z + dz });
						if (it == cells.end()) {
							continue;
						}
						for (int g : it->second) {
							if ((groups_[g].rest - p).length_squared() <= eps * eps) {
								group = g;
								break;
							}
						}
					}
				}
			}
			if (group < 0) {
				group = int(groups_.size());
				Group g;
				g.rest = p;
				g.world = xform_.xform(p);
				groups_.push_back(g);
				cells[k].push_back(group);
			}
			Corner c;
			c.group = group;
			c.surface = int(si);
			c.normal = vi < s.normals.size() ? s.normals[vi] : V3();
			c.uv = vi < s.uv.size() ? s.uv[vi] : V2();
			c.uv2 = vi < s.uv2.size() ? s.uv2[vi] : V2();
			if (s.colors.size() >= (vi + 1) * 4) {
				for (int k4 = 0; k4 < 4; k4++) {
					c.color[k4] = s.colors[vi * 4 + k4];
				}
			}
			corners_.push_back(c);
			if (skinned) {
				Skin sk;
				int n = std::min(s.bone_count, 8);
				if (s.bones.size() >= (vi + 1) * size_t(n) && s.weights.size() >= (vi + 1) * size_t(n)) {
					for (int k = 0; k < n; k++) {
						sk.b[k] = s.bones[vi * n + k];
						sk.w[k] = s.weights[vi * n + k];
					}
				}
				skins_.push_back(sk);
			}
			if (shaped) {
				Blend b;
				b.v[0] = int(vi);
				b.w[0] = 1.0f;
				blends_.push_back(b);
			}
		}
	}
	axis_directions_ = settings_.direction_mode == DIRECTION_AXIS || (settings_.direction_mode == DIRECTION_AUTO && any_displaced && all_world);

	// Triangles; area-weighted face normals give each group its displacement direction (one per
	// position, so every corner there moves the same way: no cracks at hard edges or seams).
	std::vector<V3> group_normal(groups_.size());
	std::vector<V3> corner_face_normal(corners_.size());
	std::vector<V3> corner_du(corners_.size()), corner_dv(corners_.size());
	size_t tri_count = 0;
	for (const SurfaceInput &s : inputs_) {
		tri_count += (s.indices.empty() ? s.positions.size() : s.indices.size()) / 3;
	}
	tris_.reserve(tri_count * 4);
	edges_.reserve(tri_count * 3);
	for (size_t si = 0; si < inputs_.size(); si++) {
		const SurfaceInput &s = inputs_[si];
		size_t n = s.indices.empty() ? s.positions.size() : s.indices.size();
		for (size_t i = 0; i + 2 < n; i += 3) {
			int v[3];
			bool valid = true;
			for (int k = 0; k < 3; k++) {
				v[k] = s.indices.empty() ? int(i + k) : s.indices[i + k];
				valid = valid && v[k] >= 0 && size_t(v[k]) < s.positions.size();
			}
			if (!valid) {
				error_ = "a surface's index array points past its vertices";
				return false;
			}
			int c0 = corner_base[si] + v[0], c1 = corner_base[si] + v[1], c2 = corner_base[si] + v[2];
			int g0 = corners_[c0].group, g1 = corners_[c1].group, g2 = corners_[c2].group;
			if (g0 == g1 || g1 == g2 || g2 == g0) {
				continue; // collapsed by the weld: no area
			}
			// Godot's front faces wind clockwise: the outward normal is (c - a) x (b - a).
			const V3 &a = groups_[g0].rest, &b = groups_[g1].rest, &c = groups_[g2].rest;
			V3 fn = (c - a).cross(b - a);
			group_normal[g0] += fn;
			group_normal[g1] += fn;
			group_normal[g2] += fn;
			corner_face_normal[c0] += fn;
			corner_face_normal[c1] += fn;
			corner_face_normal[c2] += fn;
			// World directions of +u and +v on this triangle (area-weighted at its corners).
			{
				const V3 &wa = groups_[g0].world, &wb = groups_[g1].world, &wc = groups_[g2].world;
				V2 ua = corners_[c0].uv, ub = corners_[c1].uv, uc = corners_[c2].uv;
				V3 e1 = wb - wa, e2 = wc - wa;
				double du1 = ub.x - ua.x, dv1 = ub.y - ua.y, du2 = uc.x - ua.x, dv2 = uc.y - ua.y;
				double det = du1 * dv2 - du2 * dv1;
				if (std::fabs(det) > 1e-20) {
					double area = e1.cross(e2).length();
					V3 dpdu = ((e1 * dv2 - e2 * dv1) * (1.0 / det)).normalized(V3()) * area;
					V3 dpdv = ((e2 * du1 - e1 * du2) * (1.0 / det)).normalized(V3()) * area;
					for (int cc : { c0, c1, c2 }) {
						corner_du[cc] += dpdu;
						corner_dv[cc] += dpdv;
					}
				}
			}
			new_tri(c0, c1, c2, int(si), 0);
		}
	}
	if (tris_.empty()) {
		error_ = "the mesh has no triangles";
		return false;
	}
	for (size_t ci = 0; ci < corners_.size(); ci++) {
		if (corners_[ci].normal.length_squared() < 1e-20) {
			corners_[ci].normal = corner_face_normal[ci].normalized();
		}
		corners_[ci].tu = corner_du[ci].normalized(V3(1.0, 0.0, 0.0));
		corners_[ci].tv = (corner_dv[ci] * -1.0).normalized(V3(0.0, 0.0, -1.0));
	}
	V3 axis = settings_.direction.normalized();
	for (size_t g = 0; g < groups_.size(); g++) {
		groups_[g].dir = axis_directions_ ? (settings_.direction_mode == DIRECTION_AXIS ? axis : V3(0.0, 1.0, 0.0))
										  : normal_matrix_.xform(group_normal[g]).normalized();
	}
	// Open boundary edges (one triangle) lock their groups.
	if (settings_.lock_borders) {
		for (const Tri &t : tris_) {
			for (int k = 0; k < 3; k++) {
				int ga = corners_[t.c[k]].group, gb = corners_[t.c[(k + 1) % 3]].group;
				EdgeRec *r = edges_.find(pair_key(ga, gb));
				if (r != nullptr && r->t[1] < 0 && r->more < 0) {
					groups_[ga].locked = true;
					groups_[gb].locked = true;
				}
			}
		}
	}
	for (Corner &c : corners_) {
		c.h = corner_h(c);
		c.vec = corner_vec(c);
	}
	stats_.source_triangles = int(tris_.size());
	return true;
}

int Tessellator::new_tri(int c0, int c1, int c2, int surface, int level) {
	Tri t;
	t.c[0] = c0;
	t.c[1] = c1;
	t.c[2] = c2;
	t.surface = surface;
	t.level = level;
	int id = int(tris_.size());
	tris_.push_back(t);
	for (int k = 0; k < 3; k++) {
		edges_.add(pair_key(corners_[t.c[k]].group, corners_[t.c[(k + 1) % 3]].group), id, extra_);
	}
	return id;
}

// --- Sampling (the GADS shaders' mappings, gads_core.gdshaderinc) --------------------------------

static double remap_height(double h, const V2 &remap) {
	double span = remap.y - remap.x;
	span = std::fabs(span) < 1e-5 ? 1e-5 : span;
	return std::clamp((h - remap.x) / span, 0.0, 1.0);
}

// The plane of a world-planar mapping and of each triplanar projection: uv = (gu.q, gv.q).
static void triplanar_axes(int axis, const V3 &n, V3 &r_right, V3 &r_up) {
	if (axis == 0) {
		double sg = n.x >= 0.0 ? 1.0 : -1.0;
		r_right = V3(0.0, 0.0, -sg);
		r_up = V3(0.0, 1.0, 0.0);
	} else if (axis == 1) {
		double sg = n.y >= 0.0 ? 1.0 : -1.0;
		r_right = V3(1.0, 0.0, 0.0);
		r_up = V3(0.0, 0.0, -sg);
	} else {
		double sg = n.z >= 0.0 ? 1.0 : -1.0;
		r_right = V3(sg, 0.0, 0.0);
		r_up = V3(0.0, 1.0, 0.0);
	}
}

static void triplanar_weights(const V3 &n, double sharpness, double r_w[3]) {
	double w[3] = { std::pow(std::fabs(n.x), sharpness), std::pow(std::fabs(n.y), sharpness), std::pow(std::fabs(n.z), sharpness) };
	double sum = std::max(w[0] + w[1] + w[2], 1e-6);
	for (double &v : w) {
		v /= sum;
		v = v < 0.05 ? 0.0 : v;
	}
	sum = std::max(w[0] + w[1] + w[2], 1e-6);
	for (int k = 0; k < 3; k++) {
		r_w[k] = w[k] / sum;
	}
}

// The uv (in texture repeats) of projection `plane` at a world point (plane < 0: the world-planar
// mapping; 0-2: triplanar axis).
static V2 planar_uv(const Displacement &d, int plane, const V3 &world, const V3 &n) {
	V3 q = world - V3(d.planar_offset_m.x, 0.0, d.planar_offset_m.y);
	V3 gu, gv;
	if (plane < 0) {
		double c = std::cos(d.rotation_rad), s = std::sin(d.rotation_rad);
		gu = V3(c, 0.0, -s) * (1.0 / d.texture_size_m.x);
		gv = V3(s, 0.0, c) * (1.0 / d.texture_size_m.y);
	} else {
		V3 right, up;
		triplanar_axes(plane, n, right, up);
		gu = right * (1.0 / d.texture_size_m.x);
		gv = -up * (1.0 / d.texture_size_m.y);
	}
	return V2(gu.dot(q), gv.dot(q));
}

static V2 uv_transform(const Displacement &d, const V2 &uv) {
	return V2(uv.x * d.uv_scale.x + d.uv_offset.x, uv.y * d.uv_scale.y + d.uv_offset.y);
}

// Detail texels per main-map texel (1 without a detail layer).
double Tessellator::detail_texels(const Displacement &d) const {
	return has_detail(d) ? d.detail_scale * maps_[d.detail_map]->width() / double(maps_[d.height_map]->width()) : 1.0;
}

// Texels of layer k per main-map texel.
double Tessellator::layer_texels(const Displacement &d, int k) const {
	return d.layers[k].scale * maps_[d.layers[k].map]->width() / double(maps_[d.height_map]->width());
}

// The finest texels the displacement samples, per main-map texel (at least 1).
double Tessellator::finest_texels(const Displacement &d) const {
	double finest = std::max(1.0, detail_texels(d));
	if (has_vector(d)) {
		finest = std::max(finest, vector_texels(d));
	}
	for (int k = 0; k < 2; k++) {
		if (has_layer(d, k)) {
			finest = std::max(finest, layer_texels(d, k));
		}
	}
	return finest;
}

static double smoothstep01(double edge0, double edge1, double x) {
	double t = std::clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// The masks of layers 1 and 2 at a point of vertex colour `color` moving along `dir` (world), as
// the shaders' gads_layer_masks x gads_slope_band().
void Tessellator::layer_masks(const Displacement &d, const float color[4], const V3 &dir, double r_masks[2]) const {
	for (int k = 0; k < 2; k++) {
		const Layer &l = d.layers[k];
		if (!has_layer(d, k)) {
			r_masks[k] = 0.0;
			continue;
		}
		double m = (l.mask_channel >= 0 && l.mask_channel < 4 ? double(color[l.mask_channel]) : 1.0) * l.amount;
		if (l.slope.y > l.slope.x) {
			m *= smoothstep01(l.slope.x, l.slope.y, dir.y);
		}
		r_masks[k] = m;
	}
}

// Weight of a layer of height `above` over the relief below of height `below` for mask m (as the
// shaders' gads_height_blend()).
static double height_blend(double below, double above, double m, double width) {
	if (m <= 0.0) {
		return 0.0;
	}
	if (m >= 1.0) {
		return 1.0;
	}
	return smoothstep01(-width, width, above - below + (2.0 * m - 1.0) * (1.0 + width));
}

// The relief (m) of one projection at uv (in main-map repeats), the detail layer and the layers
// of a layered material included, as the shaders' gads_relief(). `lod` is a mip level in the
// finest texels the displacement has (those texel_size_m() measures); each map is sampled at the
// matching level of its own texels.
double Tessellator::relief_at(const Displacement &d, const V2 &uv, double lod, const double masks[2]) const {
	const HeightMap &map = *maps_[d.height_map];
	double main_lod = lod - std::log2(finest_texels(d));
	double h = remap_height(map.sample_lod(uv, std::max(main_lod, 0.0)), d.remap);
	double relief = d.height_m * (h - d.center);
	if (has_detail(d)) {
		const HeightMap &detail = *maps_[d.detail_map];
		relief += d.detail_height_m * (detail.sample_lod(uv * d.detail_scale, std::max(main_lod + std::log2(detail_texels(d)), 0.0)) - 0.5);
	}
	for (int k = 0; k < 2; k++) {
		if (masks[k] <= 0.0) {
			continue;
		}
		const Layer &l = d.layers[k];
		double hk = maps_[l.map]->sample_lod(uv * l.scale, std::max(main_lod + std::log2(layer_texels(d, k)), 0.0));
		double t = height_blend(h, hk, masks[k], l.blend_width);
		relief += (l.height_m * (hk - d.center) - relief) * t;
		h += (hk - h) * t;
	}
	return relief;
}

double Tessellator::sample_displacement(int surface, const V3 &world, const V3 &dir, const V2 &uv, double lod, const float color[4]) const {
	double offset = has_offset() ? offset_at(uv) : 0.0;
	int di = inputs_[surface].displacement;
	if (di < 0) {
		return offset;
	}
	const Displacement &d = displacements_[di];
	double masks[2];
	layer_masks(d, color, dir, masks);
	if (d.mapping == MAPPING_UV) {
		return offset + relief_at(d, uv_transform(d, uv), lod, masks);
	}
	if (d.mapping == MAPPING_WORLD) {
		return offset + relief_at(d, planar_uv(d, -1, world, dir), lod, masks);
	}
	double w[3];
	triplanar_weights(dir, d.triplanar_sharpness, w);
	double relief = 0.0;
	for (int a = 0; a < 3; a++) {
		if (w[a] > 0.0) {
			relief += w[a] * relief_at(d, planar_uv(d, a, world, dir), lod, masks);
		}
	}
	return offset + relief;
}

// The sculpt offset (m) at the source mesh's own uv (bilinear, mip 0, clamped to the map).
double Tessellator::offset_at(const V2 &uv) const {
	const HeightMap &m = *maps_[offset_map_];
	V2 c(std::clamp(uv.x, 0.5 / m.width(), 1.0 - 0.5 / m.width()), std::clamp(uv.y, 0.5 / m.height(), 1.0 - 0.5 / m.height()));
	return m.sample(c, 0);
}

// How far the sculpt offsets can leave their interpolation over a triangle with source uvs `uv`
// (their range over the uv rectangle), and the longest edge in offset-map texels.
double Tessellator::offset_bound(const V2 uv[3], const V3 world[3], double &r_longest_texels) const {
	(void)world;
	const HeightMap &m = *maps_[offset_map_];
	V2 lo(std::min({ uv[0].x, uv[1].x, uv[2].x }), std::min({ uv[0].y, uv[1].y, uv[2].y }));
	V2 hi(std::max({ uv[0].x, uv[1].x, uv[2].x }), std::max({ uv[0].y, uv[1].y, uv[2].y }));
	V2 a(std::clamp(lo.x, 0.0, 1.0), std::clamp(lo.y, 0.0, 1.0)), b(std::clamp(hi.x, 0.0, 1.0), std::clamp(hi.y, 0.0, 1.0));
	double r_lo, r_hi;
	m.range(a, b, r_lo, r_hi);
	for (int k = 0; k < 3; k++) {
		V2 e = uv[(k + 1) % 3] - uv[k];
		r_longest_texels = std::max(r_longest_texels, std::hypot(e.x * m.width(), e.y * m.height()));
	}
	return std::max(0.0, r_hi - r_lo);
}

// Metres per offset-map texel on triangle t (from its world and source-uv areas).
double Tessellator::offset_texel_size_m(int t) const {
	const Tri &tr = tris_[t];
	const HeightMap &m = *maps_[offset_map_];
	const V3 &a = groups_[corners_[tr.c[0]].group].world, &b = groups_[corners_[tr.c[1]].group].world, &c = groups_[corners_[tr.c[2]].group].world;
	const V2 &ta = corners_[tr.c[0]].uv, &tb = corners_[tr.c[1]].uv, &tc = corners_[tr.c[2]].uv;
	double area_w = (b - a).cross(c - a).length();
	double area_t = std::fabs((tb.x - ta.x) * (tc.y - ta.y) - (tb.y - ta.y) * (tc.x - ta.x)) * m.width() * m.height();
	return area_t > 1e-12 ? std::sqrt(area_w / area_t) : 1e30;
}

double Tessellator::corner_h(const Corner &c) const {
	const Group &g = groups_[c.group];
	return sample_displacement(c.surface, g.world, g.dir, c.uv, 0.0, c.color);
}

// Texels of the vector map per main-map texel.
double Tessellator::vector_texels(const Displacement &d) const {
	return maps_[d.vector_map[0]]->width() / double(maps_[d.height_map]->width());
}

// The vector displacement (world, m) at uv on a surface moving along dir, whose +u and image-up
// directions are tu and tv, sampled at `lod` (log2 of finest texels, as relief_at()).
V3 Tessellator::vector_displacement(int surface, const V2 &uv, const V3 &dir, const V3 &tu, const V3 &tv, double lod) const {
	int di = inputs_[surface].displacement;
	if (di < 0 || !has_vector(displacements_[di])) {
		return V3();
	}
	const Displacement &d = displacements_[di];
	V2 t = uv_transform(d, uv);
	double vlod = std::max(lod - std::log2(finest_texels(d)) + std::log2(vector_texels(d)), 0.0);
	double v[3];
	for (int k = 0; k < 3; k++) {
		v[k] = maps_[d.vector_map[k]]->sample_lod(t, vlod);
		if (!d.vector_signed) {
			v[k] = 2.0 * v[k] - 1.0;
		}
	}
	V3 off;
	if (d.vector_space == 1) {
		off = xform_.basis.xform(V3(v[0], v[1], v[2]));
	} else {
		V3 n = dir;
		V3 x = (tu - n * n.dot(tu)).normalized(tu);
		V3 y = tv - n * n.dot(tv);
		y = (y - x * x.dot(y)).normalized(n.cross(x));
		off = x * v[0] + y * v[1] + n * v[2];
	}
	return off * d.vector_m;
}

V3 Tessellator::corner_vec(const Corner &c) const {
	const Group &g = groups_[c.group];
	return vector_displacement(c.surface, c.uv, g.dir, c.tu, c.tv, 0.0);
}

// --- Error -------------------------------------------------------------------------------------

// Metres per texel on triangle t (for the smallest edge worth splitting).
double Tessellator::texel_size_m(int t) const {
	const Tri &tr = tris_[t];
	int di = inputs_[tr.surface].displacement;
	double offset = has_offset() ? offset_texel_size_m(t) : 1e30;
	if (di < 0) {
		return offset;
	}
	const Displacement &d = displacements_[di];
	const HeightMap &map = *maps_[d.height_map];
	// The detail layer's and the layers' texels are finer when they repeat more often than their
	// size shrinks.
	double finer = finest_texels(d);
	if (d.mapping != MAPPING_UV) {
		return std::min(offset, d.texture_size_m.x / map.width() / finer);
	}
	const V3 &a = groups_[corners_[tr.c[0]].group].world, &b = groups_[corners_[tr.c[1]].group].world, &c = groups_[corners_[tr.c[2]].group].world;
	V2 ta = uv_transform(d, corners_[tr.c[0]].uv), tb = uv_transform(d, corners_[tr.c[1]].uv), tc = uv_transform(d, corners_[tr.c[2]].uv);
	double area_w = (b - a).cross(c - a).length();
	double area_t = std::fabs((tb.x - ta.x) * (tc.y - ta.y) - (tb.y - ta.y) * (tc.x - ta.x)) * map.width() * map.height();
	return std::min(offset, area_t > 1e-12 ? std::sqrt(area_w / area_t) / finer : 1e30);
}

// The nearest a triangle's bounding sphere comes to the view (m; 0 inside it).
double Tessellator::view_distance(int t) const {
	const Tri &tr = tris_[t];
	const V3 &a = groups_[corners_[tr.c[0]].group].world, &b = groups_[corners_[tr.c[1]].group].world, &c = groups_[corners_[tr.c[2]].group].world;
	V3 centre = (a + b + c) * (1.0 / 3.0);
	double radius = std::sqrt(std::max({ (a - centre).length_squared(), (b - centre).length_squared(), (c - centre).length_squared() }));
	return std::max(0.0, (centre - settings_.view_position).length() - radius);
}

// The error triangle t may keep (m): max_error, or what pixel_error pixels cover at its distance.
double Tessellator::tri_tolerance(int t) const {
	if (!settings_.view_dependent) {
		return settings_.max_error;
	}
	return std::max(settings_.max_error, settings_.pixel_error * view_distance(t) / std::max(settings_.focal_px, 1e-6));
}

// How far the triangle's own height field deviates from the plane through its corners (m). Below
// tol the bound is enough (the triangle needs no refinement either way).
// The middle of the circular arc from a to b that is perpendicular to the corner normals at both
// ends lies (chord / 2) tan(phi / 4) from the chord's middle along the mean normal, phi being the
// angle between the normals: exact on spheres and cylinders (and on the arcs subdividing them,
// as a new corner takes the mean normal), nothing on flat faces. Outwards where the normals
// spread along the edge (convex), inwards where they close (concave).
V3 Tessellator::curve_offset(int ca, int cb) const {
	const Corner &x = corners_[ca], &y = corners_[cb];
	const V3 &a = groups_[x.group].rest, &b = groups_[y.group].rest;
	V3 na = x.normal.normalized(V3()), nb = y.normal.normalized(V3());
	V3 nm = (na + nb).normalized(V3());
	double phi = std::acos(std::clamp(na.dot(nb), -1.0, 1.0));
	double sagitta = (b - a).length() * 0.5 * std::tan(phi * 0.25);
	double side = (nb - na).dot(b - a) >= 0.0 ? 1.0 : -1.0;
	return nm * (sagitta * side * settings_.smooth_shape);
}

double Tessellator::curvature_error(int t) const {
	const Tri &tr = tris_[t];
	double worst = 0.0;
	for (int k = 0; k < 3; k++) {
		worst = std::max(worst, xform_.basis.xform(curve_offset(tr.c[k], tr.c[(k + 1) % 3])).length());
	}
	return worst;
}

// The triangle's error: how far its relief (and, with smooth_shape, the curved surface) leaves the
// flat triangle.
float Tessellator::tri_error(int t, double tol) const {
	if (settings_.smooth_shape <= 0.0) {
		return relief_error(t, tol);
	}
	double curv = curvature_error(t);
	return float(curv) + relief_error(t, std::max(tol - curv, 0.0));
}

float Tessellator::relief_error(int t, double tol) const {
	const Tri &tr = tris_[t];
	int di = inputs_[tr.surface].displacement;
	const Corner *c[3] = { &corners_[tr.c[0]], &corners_[tr.c[1]], &corners_[tr.c[2]] };
	const Group *g[3] = { &groups_[c[0]->group], &groups_[c[1]->group], &groups_[c[2]->group] };
	double offset_term = 0.0, offset_texels = 0.0;
	if (has_offset()) {
		V2 ouv[3] = { c[0]->uv, c[1]->uv, c[2]->uv };
		V3 ow[3] = { g[0]->world, g[1]->world, g[2]->world };
		offset_term = offset_bound(ouv, ow, offset_texels);
	}
	if (di < 0) {
		if (offset_term <= tol || offset_texels > SCAN_LIMIT_TEXELS) {
			return float(offset_term);
		}
		return scan_error(t, offset_texels, false);
	}
	const Displacement &d = displacements_[di];
	const HeightMap &map = *maps_[d.height_map];
	// The projections this triangle samples, their corner uvs (in repeats).
	int planes[3];
	int plane_count = 0;
	if (d.mapping == MAPPING_UV) {
		planes[plane_count++] = -2;
	} else if (d.mapping == MAPPING_WORLD) {
		planes[plane_count++] = -1;
	} else {
		bool used[3] = { false, false, false };
		for (int k = 0; k < 3; k++) {
			double w[3];
			triplanar_weights(g[k]->dir, d.triplanar_sharpness, w);
			for (int a = 0; a < 3; a++) {
				used[a] = used[a] || w[a] > 0.0;
			}
		}
		for (int a = 0; a < 3; a++) {
			if (used[a]) {
				planes[plane_count++] = a;
			}
		}
	}
	double lo = 1e30, hi = -1e30, longest_texels = 0.0;
	double detail_lo = 1e30, detail_hi = -1e30;
	double z_lo = 1e30, z_hi = -1e30;
	// A layer counts where any corner's colour lets it in (the slope band is left out: bounds only
	// need to be conservative).
	bool layer_active[2] = { false, false };
	for (int l = 0; l < 2; l++) {
		if (has_layer(d, l)) {
			int ch = d.layers[l].mask_channel;
			for (int k = 0; k < 3; k++) {
				layer_active[l] = layer_active[l] || ch < 0 || ch > 3 || c[k]->color[ch] > 0.0f;
			}
		}
	}
	for (int p = 0; p < plane_count; p++) {
		V2 uv[3];
		for (int k = 0; k < 3; k++) {
			uv[k] = planes[p] == -2 ? uv_transform(d, c[k]->uv) : planar_uv(d, planes[p], g[k]->world, g[k]->dir);
		}
		V2 uv_min(std::min({ uv[0].x, uv[1].x, uv[2].x }), std::min({ uv[0].y, uv[1].y, uv[2].y }));
		V2 uv_max(std::max({ uv[0].x, uv[1].x, uv[2].x }), std::max({ uv[0].y, uv[1].y, uv[2].y }));
		double r_lo, r_hi;
		map.range(uv_min, uv_max, r_lo, r_hi);
		double a = remap_height(r_lo, d.remap), b = remap_height(r_hi, d.remap);
		lo = std::min(lo, std::min(a, b));
		hi = std::max(hi, std::max(a, b));
		if (has_detail(d)) {
			const HeightMap &detail = *maps_[d.detail_map];
			detail.range(uv_min * d.detail_scale, uv_max * d.detail_scale, r_lo, r_hi);
			detail_lo = std::min(detail_lo, r_lo);
			detail_hi = std::max(detail_hi, r_hi);
		}
		for (int l = 0; l < 2; l++) {
			if (layer_active[l]) {
				const Layer &layer = d.layers[l];
				maps_[layer.map]->range(uv_min * layer.scale, uv_max * layer.scale, r_lo, r_hi);
				z_lo = std::min(z_lo, layer.height_m * (r_lo - d.center));
				z_hi = std::max(z_hi, layer.height_m * (r_hi - d.center));
			}
		}
		for (int k = 0; k < 3; k++) {
			V2 e = uv[(k + 1) % 3] - uv[k];
			longest_texels = std::max(longest_texels, std::hypot(e.x * map.width(), e.y * map.height()));
			if (has_detail(d)) {
				const HeightMap &detail = *maps_[d.detail_map];
				longest_texels = std::max(longest_texels, d.detail_scale * std::hypot(e.x * detail.width(), e.y * detail.height()));
			}
			for (int l = 0; l < 2; l++) {
				if (layer_active[l]) {
					const HeightMap &lm = *maps_[d.layers[l].map];
					longest_texels = std::max(longest_texels, d.layers[l].scale * std::hypot(e.x * lm.width(), e.y * lm.height()));
				}
			}
		}
	}
	// Corner values and the field both stay inside the reliefs' range (the main one, the active
	// layers', plus the detail layer's): the deviation cannot exceed it.
	z_lo = std::min(z_lo, d.height_m * (lo - d.center));
	z_hi = std::max(z_hi, d.height_m * (hi - d.center));
	double bound = (z_hi - z_lo) + (has_detail(d) ? d.detail_height_m * std::max(0.0, detail_hi - detail_lo) : 0.0);
	bool vector = has_vector(d);
	if (vector) {
		// Each channel stays within its range over the triangle's uvs; the frame turns by up to the
		// corners' differences. Both bound how far the offsets can leave their interpolation.
		V2 uv[3];
		for (int k = 0; k < 3; k++) {
			uv[k] = uv_transform(d, c[k]->uv);
		}
		V2 uv_min(std::min({ uv[0].x, uv[1].x, uv[2].x }), std::min({ uv[0].y, uv[1].y, uv[2].y }));
		V2 uv_max(std::max({ uv[0].x, uv[1].x, uv[2].x }), std::max({ uv[0].y, uv[1].y, uv[2].y }));
		double span2 = 0.0, reach2 = 0.0;
		const HeightMap &vm = *maps_[d.vector_map[0]];
		for (int k = 0; k < 3; k++) {
			double r_lo, r_hi;
			maps_[d.vector_map[k]]->range(uv_min, uv_max, r_lo, r_hi);
			double scale = d.vector_signed ? 1.0 : 2.0;
			double lo_k = d.vector_signed ? r_lo : 2.0 * r_lo - 1.0, hi_k = d.vector_signed ? r_hi : 2.0 * r_hi - 1.0;
			span2 += (r_hi - r_lo) * scale * (r_hi - r_lo) * scale;
			reach2 += std::max(lo_k * lo_k, hi_k * hi_k);
		}
		double turn = 0.0;
		for (int k = 0; k < 3; k++) {
			const Corner *p = c[k], *q = c[(k + 1) % 3];
			turn = std::max(turn, (p->tu - q->tu).length() + (p->tv - q->tv).length() + (g[k]->dir - g[(k + 1) % 3]->dir).length());
		}
		bound += std::fabs(d.vector_m) * (std::sqrt(span2) + std::sqrt(reach2) * turn);
		for (int k = 0; k < 3; k++) {
			V2 e = uv[(k + 1) % 3] - uv[k];
			longest_texels = std::max(longest_texels, std::hypot(e.x * vm.width(), e.y * vm.height()));
		}
	}
	bound += offset_term;
	longest_texels = std::max(longest_texels, offset_texels);
	if (bound <= tol || longest_texels > SCAN_LIMIT_TEXELS) {
		return float(bound);
	}
	return scan_error(t, longest_texels, vector);
}

// The triangle's largest deviation from the plane through its displaced corners (height and
// vector displacement), scanned at about 1.5 samples per texel along its longest edge.
float Tessellator::scan_error(int t, double longest_texels, bool vector) const {
	const Tri &tr = tris_[t];
	const Corner *c[3] = { &corners_[tr.c[0]], &corners_[tr.c[1]], &corners_[tr.c[2]] };
	const Group *g[3] = { &groups_[c[0]->group], &groups_[c[1]->group], &groups_[c[2]->group] };
	int n = std::max(2, int(std::ceil(longest_texels * 1.5)));
	double err = 0.0;
	for (int i = 0; i <= n; i++) {
		for (int j = 0; i + j <= n; j++) {
			double a = double(i) / n, b = double(j) / n, w0 = 1.0 - a - b;
			V3 world = g[0]->world * w0 + g[1]->world * a + g[2]->world * b;
			V3 dir = (g[0]->dir * w0 + g[1]->dir * a + g[2]->dir * b).normalized(g[0]->dir);
			V2 uv = c[0]->uv * w0 + c[1]->uv * a + c[2]->uv * b;
			float color[4];
			for (int k = 0; k < 4; k++) {
				color[k] = float(c[0]->color[k] * w0 + c[1]->color[k] * a + c[2]->color[k] * b);
			}
			double h = sample_displacement(tr.surface, world, dir, uv, 0.0, color);
			double lin = c[0]->h * w0 + c[1]->h * a + c[2]->h * b;
			double e = std::fabs(h - lin);
			if (vector) {
				V3 tu = c[0]->tu * w0 + c[1]->tu * a + c[2]->tu * b;
				V3 tv = c[0]->tv * w0 + c[1]->tv * a + c[2]->tv * b;
				V3 v = vector_displacement(tr.surface, uv, dir, tu, tv, 0.0);
				e += (v - (c[0]->vec * w0 + c[1]->vec * a + c[2]->vec * b)).length();
			}
			err = std::max(err, e);
		}
	}
	return float(err);
}

void Tessellator::evaluate(const std::vector<int> &list) {
	parallel_for(list.size(), settings_.threads, [&](size_t i) {
		Tri &tr = tris_[list[i]];
		tr.tol = float(tri_tolerance(list[i]));
		tr.error = tri_error(list[i], tr.tol);
	});
}

// --- Rivara longest-edge bisection -------------------------------------------------------------

// A total order on edges: world length, then the group pair (so two triangles always agree on
// which of their edges is longest, and longest-edge paths cannot cycle).
bool Tessellator::edge_less(int ga, int gb, int ha, int hb) const {
	if (ga > gb) {
		std::swap(ga, gb);
	}
	if (ha > hb) {
		std::swap(ha, hb);
	}
	double la = edge_len2(ga, gb), lb = edge_len2(ha, hb);
	if (la != lb) {
		return la < lb;
	}
	return ga != ha ? ga < ha : gb < hb;
}

int Tessellator::longest_edge(int t) const {
	const Tri &tr = tris_[t];
	int best = 0;
	for (int k = 1; k < 3; k++) {
		int ga = corners_[tr.c[best]].group, gb = corners_[tr.c[(best + 1) % 3]].group;
		int ha = corners_[tr.c[k]].group, hb = corners_[tr.c[(k + 1) % 3]].group;
		if (edge_less(ga, gb, ha, hb)) {
			best = k;
		}
	}
	return best;
}

void Tessellator::split_edge(int ga, int gb) {
	uint64_t key = pair_key(ga, gb);
	EdgeRec *rec = edges_.find(key);
	if (rec == nullptr) {
		return;
	}
	std::vector<int> incident;
	for (int t : rec->t) {
		if (t >= 0) {
			incident.push_back(t);
		}
	}
	if (rec->more >= 0) {
		incident.insert(incident.end(), extra_[rec->more].begin(), extra_[rec->more].end());
	}
	edges_.erase(key);

	Group m;
	const Group &a = groups_[ga], &b = groups_[gb];
	m.rest = (a.rest + b.rest) * 0.5;
	m.world = (a.world + b.world) * 0.5;
	if (settings_.smooth_shape > 0.0 && !(a.locked && b.locked && incident.size() == 1)) {
		// Curved only where the edge is smooth: every side has the same normals at both ends (a
		// hard edge or a crease stays straight, and both sides share the one new position).
		int first_a = -1, first_b = -1;
		bool smooth = true;
		for (int t : incident) {
			const Tri &tr = tris_[t];
			for (int i = 0; i < 3; i++) {
				int ca = tr.c[i], cb = tr.c[(i + 1) % 3];
				int x = corners_[ca].group, y = corners_[cb].group;
				if (x == gb && y == ga) {
					std::swap(ca, cb);
				} else if (!(x == ga && y == gb)) {
					continue;
				}
				if (first_a < 0) {
					first_a = ca;
					first_b = cb;
				} else {
					smooth = smooth && corners_[ca].normal.dot(corners_[first_a].normal) > 0.9999 * corners_[ca].normal.length() * corners_[first_a].normal.length()
						&& corners_[cb].normal.dot(corners_[first_b].normal) > 0.9999 * corners_[cb].normal.length() * corners_[first_b].normal.length();
				}
			}
		}
		if (smooth && first_a >= 0) {
			m.rest = m.rest + curve_offset(first_a, first_b);
			m.world = xform_.xform(m.rest);
		}
	}
	m.dir = axis_directions_ ? a.dir : (a.dir + b.dir).normalized(a.dir);
	m.locked = a.locked && b.locked && incident.size() == 1; // the midpoint of a border edge
	m.level = std::max(a.level, b.level) + 1;
	int gm = int(groups_.size());
	groups_.push_back(m);

	// One new corner per side of the edge (triangles sharing the same two corners share it).
	std::vector<std::pair<uint64_t, int>> mids;
	for (int t : incident) {
		Tri tr = tris_[t];
		int i = 0;
		for (; i < 3; i++) {
			int x = corners_[tr.c[i]].group, y = corners_[tr.c[(i + 1) % 3]].group;
			if ((x == ga && y == gb) || (x == gb && y == ga)) {
				break;
			}
		}
		if (i == 3) {
			continue;
		}
		int ca = tr.c[i], cb = tr.c[(i + 1) % 3], cc = tr.c[(i + 2) % 3];
		uint64_t ck = pair_key(uint32_t(ca), uint32_t(cb));
		int cm = -1;
		for (const auto &p : mids) {
			if (p.first == ck) {
				cm = p.second;
			}
		}
		if (cm < 0) {
			Corner x = corners_[ca], y = corners_[cb], n;
			n.group = gm;
			n.surface = x.surface;
			n.normal = (x.normal + y.normal).normalized(x.normal);
			n.uv = (x.uv + y.uv) * 0.5;
			n.uv2 = (x.uv2 + y.uv2) * 0.5;
			for (int k = 0; k < 4; k++) {
				n.color[k] = 0.5f * (x.color[k] + y.color[k]);
			}
			n.tu = (x.tu + y.tu).normalized(x.tu);
			n.tv = (x.tv + y.tv).normalized(x.tv);
			n.h = corner_h(n);
			n.vec = corner_vec(n);
			cm = int(corners_.size());
			corners_.push_back(n);
			if (!skins_.empty()) {
				int count = std::max(inputs_[x.surface].bone_count, 1);
				skins_.push_back(mix_skins(skins_[ca], skins_[cb], count));
			}
			if (!blends_.empty()) {
				blends_.push_back(mix_blends(blends_[ca], blends_[cb]));
			}
			mids.emplace_back(ck, cm);
		}
		int gc = corners_[cc].group;
		tris_[t].alive = false;
		edges_.remove_tri(pair_key(corners_[cb].group, gc), t, extra_);
		edges_.remove_tri(pair_key(gc, corners_[ca].group), t, extra_);
		new_tri(ca, cm, cc, tr.surface, tr.level + 1);
		new_tri(cm, cb, cc, tr.surface, tr.level + 1);
	}
}

// The skin halfway between two corners: both influences at half weight (a bone in both adds up),
// the `count` strongest kept (ties: the lower bone first, so it does not depend on order) and
// normalised. Linear in between, as the positions are.
Tessellator::Skin Tessellator::mix_skins(const Skin &x, const Skin &y, int count) {
	int b[16];
	float w[16];
	int n = 0;
	for (const Skin *s : { &x, &y }) {
		for (int k = 0; k < 8; k++) {
			if (s->w[k] <= 0.0f) {
				continue;
			}
			int at = -1;
			for (int j = 0; j < n; j++) {
				if (b[j] == s->b[k]) {
					at = j;
				}
			}
			if (at < 0) {
				b[n] = s->b[k];
				w[n] = 0.0f;
				at = n++;
			}
			w[at] += 0.5f * s->w[k];
		}
	}
	int order[16];
	for (int i = 0; i < n; i++) {
		order[i] = i;
	}
	std::sort(order, order + n, [&](int i, int j) { return w[i] != w[j] ? w[i] > w[j] : b[i] < b[j]; });
	Skin out;
	int keep = std::min({ n, count, 8 });
	float total = 0.0f;
	for (int k = 0; k < keep; k++) {
		total += w[order[k]];
	}
	for (int k = 0; k < keep; k++) {
		out.b[k] = b[order[k]];
		out.w[k] = total > 0.0f ? w[order[k]] / total : 0.0f;
	}
	return out;
}

// Halfway between two corners: both blends at half weight (a source vertex in both adds up); the
// three strongest kept and normalised (there are never more within a source triangle).
Tessellator::Blend Tessellator::mix_blends(const Blend &x, const Blend &y) {
	int v[6];
	float w[6];
	int n = 0;
	for (const Blend *b : { &x, &y }) {
		for (int k = 0; k < 3; k++) {
			if (b->v[k] < 0 || b->w[k] <= 0.0f) {
				continue;
			}
			int at = -1;
			for (int j = 0; j < n; j++) {
				if (v[j] == b->v[k]) {
					at = j;
				}
			}
			if (at < 0) {
				v[n] = b->v[k];
				w[n] = 0.0f;
				at = n++;
			}
			w[at] += 0.5f * b->w[k];
		}
	}
	int order[6];
	for (int i = 0; i < n; i++) {
		order[i] = i;
	}
	std::sort(order, order + n, [&](int i, int j) { return w[i] != w[j] ? w[i] > w[j] : v[i] < v[j]; });
	Blend out;
	int keep = std::min(n, 3);
	float total = 0.0f;
	for (int k = 0; k < keep; k++) {
		total += w[order[k]];
	}
	for (int k = 0; k < keep; k++) {
		out.v[k] = v[order[k]];
		out.w[k] = total > 0.0f ? w[order[k]] / total : 0.0f;
	}
	return out;
}

void Tessellator::refine(int t) {
	// Longest-edge propagation: follow neighbours across longest edges until an edge is the
	// longest of every triangle on it, split it, and repeat until t itself has been split.
	for (int guard = 0; tris_[t].alive && guard < 4096; guard++) {
		int cur = t;
		for (int steps = 0; steps < 4096; steps++) {
			const Tri &tr = tris_[cur];
			int e = longest_edge(cur);
			int ga = corners_[tr.c[e]].group, gb = corners_[tr.c[(e + 1) % 3]].group;
			uint64_t key = pair_key(ga, gb);
			EdgeRec *rec = edges_.find(key);
			int next = -1;
			auto visit = [&](int n) {
				if (n >= 0 && n != cur && next < 0) {
					const Tri &nt = tris_[n];
					int ne = longest_edge(n);
					if (pair_key(corners_[nt.c[ne]].group, corners_[nt.c[(ne + 1) % 3]].group) != key) {
						next = n;
					}
				}
			};
			if (rec != nullptr) {
				visit(rec->t[0]);
				visit(rec->t[1]);
				if (rec->more >= 0) {
					for (int n : extra_[rec->more]) {
						visit(n);
					}
				}
			}
			if (next < 0) {
				split_edge(ga, gb);
				break;
			}
			cur = next;
		}
	}
}

// --- Run ---------------------------------------------------------------------------------------

bool Tessellator::run(const std::atomic<bool> &cancel, std::atomic<float> &progress, std::atomic<int> &triangles) {
	auto start = std::chrono::steady_clock::now();
	progress = 0.0f;
	if (!build_topology()) {
		return false;
	}
	std::vector<int> all(tris_.size());
	for (size_t i = 0; i < all.size(); i++) {
		all[i] = int(i);
	}
	evaluate(all);
	int alive = int(tris_.size());
	triangles = alive;
	auto eligible = [&](int t) {
		const Tri &tr = tris_[t];
		if (!tr.alive || tr.error <= tr.tol || tr.level >= settings_.max_level) {
			return false;
		}
		int e = longest_edge(t);
		double len = std::sqrt(edge_len2(corners_[tr.c[e]].group, corners_[tr.c[(e + 1) % 3]].group));
		if (settings_.view_dependent && len * settings_.focal_px <= settings_.min_edge_pixels * std::max(view_distance(t), 1e-6)) {
			return false;
		}
		return len > settings_.min_edge_texels * texel_size_m(t);
	};
	// Worst first: by the error over the tolerance (on screen, for view-dependent refinement).
	auto priority = [&](int t) {
		return double(tris_[t].error) / std::max(double(tris_[t].tol), 1e-12);
	};
	// The rounds a triangle can need is about the bisections from its edge down to a texel.
	int expected_rounds = 1;
	for (size_t t = 0; t < tris_.size(); t++) {
		int e = longest_edge(int(t));
		double len = std::sqrt(edge_len2(corners_[tris_[t].c[e]].group, corners_[tris_[t].c[(e + 1) % 3]].group));
		double texel = std::max(texel_size_m(int(t)) * settings_.min_edge_texels, 1e-9);
		if (texel < 1e29) {
			expected_rounds = std::max(expected_rounds, int(2.0 * std::log2(std::max(len / texel, 1.0))) + 1);
		}
	}
	expected_rounds = std::min(expected_rounds, settings_.max_level);
	for (;;) {
		if (cancel) {
			error_ = "cancelled";
			return false;
		}
		std::vector<int> candidates;
		for (size_t t = 0; t < tris_.size(); t++) {
			if (eligible(int(t))) {
				candidates.push_back(int(t));
			}
		}
		if (candidates.empty()) {
			break;
		}
		std::sort(candidates.begin(), candidates.end(), [&](int x, int y) {
			double px = priority(x), py = priority(y);
			return px != py ? px > py : x < y;
		});
		size_t first_new = tris_.size();
		for (int t : candidates) {
			if (alive >= settings_.max_triangles) {
				stats_.budget_reached = true;
				break;
			}
			if (tris_[t].alive) {
				size_t before = tris_.size();
				refine(t);
				// Each split kills its triangles and adds two children for each.
				alive += int(tris_.size() - before) / 2;
			}
		}
		std::vector<int> fresh;
		for (size_t t = first_new; t < tris_.size(); t++) {
			if (tris_[t].alive) {
				fresh.push_back(int(t));
			}
		}
		evaluate(fresh);
		stats_.rounds++;
		triangles = alive;
		progress = float(0.9 * std::min(1.0, double(stats_.rounds) / expected_rounds));
		if (stats_.budget_reached) {
			break;
		}
	}
	for (const Tri &tr : tris_) {
		if (tr.alive && tr.error > tr.tol) {
			stats_.max_error_left = std::max(stats_.max_error_left, double(tr.error));
			if (settings_.view_dependent) {
				int t = int(&tr - tris_.data());
				stats_.max_pixels_left = std::max(stats_.max_pixels_left, tr.error * settings_.focal_px / std::max(view_distance(t), 1e-6));
			}
		}
		if (tr.alive) {
			stats_.max_level = std::max(stats_.max_level, tr.level);
		}
	}
	if (cancel) {
		error_ = "cancelled";
		return false;
	}
	build_outputs();
	stats_.triangles = alive;
	stats_.milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	progress = 1.0f;
	return true;
}

// --- Output ------------------------------------------------------------------------------------

namespace {
// MikkTSpace over one output surface, written the way Godot's SurfaceTool does
// (scene/resources/surface_tool.cpp): bitangent negated, sign from it, last write per index wins.
struct MikkData {
	SurfaceOutput *out;
};
int mikk_faces(const SMikkTSpaceContext *ctx) {
	return int(static_cast<MikkData *>(ctx->m_pUserData)->out->indices.size() / 3);
}
int mikk_face_verts(const SMikkTSpaceContext *, const int) {
	return 3;
}
void mikk_position(const SMikkTSpaceContext *ctx, float r[], const int face, const int vert) {
	SurfaceOutput *o = static_cast<MikkData *>(ctx->m_pUserData)->out;
	int v = o->indices[face * 3 + vert];
	for (int k = 0; k < 3; k++) {
		r[k] = o->positions[v * 3 + k];
	}
}
void mikk_normal(const SMikkTSpaceContext *ctx, float r[], const int face, const int vert) {
	SurfaceOutput *o = static_cast<MikkData *>(ctx->m_pUserData)->out;
	int v = o->indices[face * 3 + vert];
	for (int k = 0; k < 3; k++) {
		r[k] = o->normals[v * 3 + k];
	}
}
void mikk_uv(const SMikkTSpaceContext *ctx, float r[], const int face, const int vert) {
	SurfaceOutput *o = static_cast<MikkData *>(ctx->m_pUserData)->out;
	int v = o->indices[face * 3 + vert];
	r[0] = o->uv[v * 2];
	r[1] = o->uv[v * 2 + 1];
}
void mikk_set(const SMikkTSpaceContext *ctx, const float t[], const float b[], const float, const float, const tbool, const int face, const int vert) {
	SurfaceOutput *o = static_cast<MikkData *>(ctx->m_pUserData)->out;
	int v = o->indices[face * 3 + vert];
	V3 tangent(t[0], t[1], t[2]), binormal(-b[0], -b[1], -b[2]);
	V3 n(o->normals[v * 3], o->normals[v * 3 + 1], o->normals[v * 3 + 2]);
	o->tangents[v * 4] = float(tangent.x);
	o->tangents[v * 4 + 1] = float(tangent.y);
	o->tangents[v * 4 + 2] = float(tangent.z);
	o->tangents[v * 4 + 3] = binormal.dot(n.cross(tangent)) < 0.0 ? -1.0f : 1.0f;
}
} // namespace

void Tessellator::build_outputs() {
	// Footprint per group (mean length of the edges at it) and texel size per corner.
	std::vector<double> edge_sum(groups_.size(), 0.0), texel_sum(corners_.size(), 0.0);
	std::vector<int> edge_n(groups_.size(), 0), texel_n(corners_.size(), 0);
	std::vector<std::vector<int>> group_corners(groups_.size());
	std::vector<char> corner_used(corners_.size(), 0);
	for (size_t t = 0; t < tris_.size(); t++) {
		const Tri &tr = tris_[t];
		if (!tr.alive) {
			continue;
		}
		double texel = texel_size_m(int(t));
		for (int k = 0; k < 3; k++) {
			int ga = corners_[tr.c[k]].group, gb = corners_[tr.c[(k + 1) % 3]].group;
			double len = std::sqrt(edge_len2(ga, gb));
			edge_sum[ga] += len;
			edge_sum[gb] += len;
			edge_n[ga]++;
			edge_n[gb]++;
			if (texel < 1e29) {
				texel_sum[tr.c[k]] += texel;
				texel_n[tr.c[k]]++;
			}
			if (!corner_used[tr.c[k]]) {
				corner_used[tr.c[k]] = 1;
				group_corners[corners_[tr.c[k]].group].push_back(tr.c[k]);
			}
		}
	}
	// Final displacement per group: the mean of its corners' samples (they differ across a seam).
	// Where refinement met the tolerance the full-resolution samples are right by construction
	// (the error is measured against them). Where it stopped early (budget, smallest edge, deepest
	// level) they are filtered to the footprint, so coarse triangles do not alias the height map.
	// The footprint's mip level per corner also goes to the shaders: the geometry carries the
	// relief down to it, the normal map adds what lies below.
	std::vector<char> coarse(groups_.size(), 0);
	std::vector<int> finest(groups_.size(), 0); // the deepest level among a group's triangles
	for (const Tri &tr : tris_) {
		if (!tr.alive) {
			continue;
		}
		for (int k = 0; k < 3; k++) {
			int g = corners_[tr.c[k]].group;
			finest[g] = std::max(finest[g], tr.level);
			if (tr.error > settings_.max_error) { // also far triangles a view-dependent tolerance let stay coarse
				coarse[g] = 1;
			}
		}
	}
	std::vector<double> value(groups_.size(), 0.0);
	std::vector<V3> vector_value(groups_.size());
	std::vector<float> corner_lod(corners_.size(), 0.0f);
	parallel_for(groups_.size(), settings_.threads, [&](size_t g) {
		const std::vector<int> &cs = group_corners[g];
		double footprint = edge_n[g] > 0 ? edge_sum[g] / edge_n[g] : 0.0;
		for (int ci : cs) {
			if (texel_n[ci] > 0) {
				corner_lod[ci] = float(std::max(0.0, std::log2(std::max(footprint / (texel_sum[ci] / texel_n[ci]), 1e-9))));
			}
		}
		if (cs.empty() || groups_[g].locked) {
			return;
		}
		double sum = 0.0;
		V3 vsum;
		for (int ci : cs) {
			double lod = settings_.filter_heights && coarse[g] ? corner_lod[ci] : 0.0;
			const Corner &c = corners_[ci];
			sum += sample_displacement(c.surface, groups_[g].world, groups_[g].dir, c.uv, lod, c.color);
			vsum += vector_displacement(c.surface, c.uv, groups_[g].dir, c.tu, c.tv, lod);
		}
		value[g] = sum / double(cs.size());
		// Corners of a group differ at seams: they all move by the mean (no crack).
		vector_value[g] = vsum * (1.0 / double(cs.size()));
	});
	std::vector<V3> moved(groups_.size());
	for (size_t g = 0; g < groups_.size(); g++) {
		moved[g] = groups_[g].rest + world_to_object_.xform(groups_[g].dir * value[g] + vector_value[g]);
	}
	// Normal clusters: corners of a group whose source normals point the same way (within
	// hard_angle_deg) share a shading normal; hard edges stay hard.
	std::vector<int> cluster(corners_.size(), -1);
	int cluster_count = 0;
	double cos_hard = std::cos(settings_.hard_angle_deg * PI / 180.0);
	for (const std::vector<int> &cs : group_corners) {
		std::vector<std::pair<V3, int>> reps;
		for (int ci : cs) {
			V3 n = corners_[ci].normal.normalized();
			int id = -1;
			for (const auto &r : reps) {
				if (r.first.dot(n) >= cos_hard) {
					id = r.second;
					break;
				}
			}
			if (id < 0) {
				id = cluster_count++;
				reps.emplace_back(n, id);
			}
			cluster[ci] = id;
		}
	}
	std::vector<V3> cluster_normal(cluster_count);
	for (const Tri &tr : tris_) {
		if (!tr.alive) {
			continue;
		}
		const V3 &a = moved[corners_[tr.c[0]].group], &b = moved[corners_[tr.c[1]].group], &c = moved[corners_[tr.c[2]].group];
		V3 fn = (c - a).cross(b - a);
		for (int k = 0; k < 3; k++) {
			cluster_normal[cluster[tr.c[k]]] += fn;
		}
	}

	M3 to_object_normal = xform_.basis.transposed();
	outputs_.assign(inputs_.size(), SurfaceOutput());
	std::vector<int> out_index(corners_.size(), -1);
	for (size_t si = 0; si < inputs_.size(); si++) {
		SurfaceOutput &o = outputs_[si];
		o.has_uv = !inputs_[si].uv.empty();
		o.has_uv2 = !inputs_[si].uv2.empty();
		o.has_colors = !inputs_[si].colors.empty();
		o.bone_count = skins_.empty() ? 0 : std::min(inputs_[si].bone_count, 8);
		if (!blends_.empty()) {
			o.shape_positions.resize(inputs_[si].shape_positions.size());
			o.shape_normals.resize(inputs_[si].shape_positions.size());
		}
	}
	for (const Tri &tr : tris_) {
		if (!tr.alive) {
			continue;
		}
		SurfaceOutput &o = outputs_[tr.surface];
		for (int k = 0; k < 3; k++) {
			int ci = tr.c[k];
			if (out_index[ci] < 0) {
				const Corner &c = corners_[ci];
				const Group &g = groups_[c.group];
				out_index[ci] = int(o.positions.size() / 3);
				const V3 &p = moved[c.group];
				o.positions.insert(o.positions.end(), { float(p.x), float(p.y), float(p.z) });
				V3 n = settings_.geometry_normals ? cluster_normal[cluster[ci]].normalized(c.normal) : c.normal.normalized();
				o.normals.insert(o.normals.end(), { float(n.x), float(n.y), float(n.z) });
				o.tangents.insert(o.tangents.end(), { 0.0f, 0.0f, 0.0f, 1.0f });
				if (o.has_uv) {
					o.uv.insert(o.uv.end(), { float(c.uv.x), float(c.uv.y) });
				}
				if (o.has_uv2) {
					o.uv2.insert(o.uv2.end(), { float(c.uv2.x), float(c.uv2.y) });
				}
				if (o.has_colors) {
					o.colors.insert(o.colors.end(), { c.color[0], c.color[1], c.color[2], c.color[3] });
				}
				if (o.bone_count > 0) {
					const Skin &sk = skins_[ci];
					for (int k = 0; k < o.bone_count; k++) {
						o.bones.push_back(sk.b[k]);
						o.weights.push_back(sk.w[k]);
					}
				}
				// Each blend shape: the baked vertex moved by the shape's offset there (the blend of
				// the source vertices' offsets), its normal turned by theirs.
				const SurfaceInput &in = inputs_[c.surface];
				for (size_t sh = 0; sh < o.shape_positions.size(); sh++) {
					V3 dp, dn;
					const Blend &b = blends_[ci];
					for (int k = 0; k < 3; k++) {
						if (b.v[k] >= 0 && size_t(b.v[k]) < in.shape_positions[sh].size()) {
							dp = dp + in.shape_positions[sh][b.v[k]] * double(b.w[k]);
							if (size_t(b.v[k]) < in.shape_normals[sh].size()) {
								dn = dn + in.shape_normals[sh][b.v[k]] * double(b.w[k]);
							}
						}
					}
					V3 sp = p + dp;
					V3 snrm = (n + dn).normalized(n);
					o.shape_positions[sh].insert(o.shape_positions[sh].end(), { float(sp.x), float(sp.y), float(sp.z) });
					o.shape_normals[sh].insert(o.shape_normals[sh].end(), { float(snrm.x), float(snrm.y), float(snrm.z) });
				}
				// For the shaders: where the vertex was (textures are mapped at the rest position) and
				// the mip level of its footprint, the direction it moved in and the refinement level of
				// its finest triangle (debug view).
				V3 rest_n = to_object_normal.xform(g.dir).normalized();
				// The shaders take the footprint in main-map texels; corner_lod is in the finest ones.
				int di = inputs_[c.surface].displacement;
				float main_lod = di < 0 ? corner_lod[ci] : float(std::max(0.0, corner_lod[ci] - std::log2(finest_texels(displacements_[di]))));
				o.custom0.insert(o.custom0.end(), { float(g.rest.x), float(g.rest.y), float(g.rest.z), main_lod });
				o.custom1.insert(o.custom1.end(), { float(rest_n.x), float(rest_n.y), float(rest_n.z), float(finest[c.group]) / 32.0f });
			}
			o.indices.push_back(out_index[ci]);
		}
	}
	int vertices = 0;
	for (SurfaceOutput &o : outputs_) {
		vertices += int(o.positions.size() / 3);
		size_t count = o.positions.size() / 3;
		if (o.has_uv && !o.indices.empty()) {
			MikkData data{ &o };
			SMikkTSpaceInterface iface = {};
			iface.m_getNumFaces = mikk_faces;
			iface.m_getNumVerticesOfFace = mikk_face_verts;
			iface.m_getPosition = mikk_position;
			iface.m_getNormal = mikk_normal;
			iface.m_getTexCoord = mikk_uv;
			iface.m_setTSpace = mikk_set;
			SMikkTSpaceContext ctx = {};
			ctx.m_pInterface = &iface;
			ctx.m_pUserData = &data;
			genTangSpaceDefault(&ctx);
		} else {
			// No UVs: any tangent perpendicular to the normal.
			for (size_t v = 0; v < count; v++) {
				V3 n(o.normals[v * 3], o.normals[v * 3 + 1], o.normals[v * 3 + 2]);
				V3 t = (std::fabs(n.y) < 0.999 ? V3(0, 1, 0).cross(n) : V3(1, 0, 0)).normalized(V3(1, 0, 0));
				o.tangents[v * 4] = float(t.x);
				o.tangents[v * 4 + 1] = float(t.y);
				o.tangents[v * 4 + 2] = float(t.z);
			}
		}
	}
	stats_.vertices = vertices;
}

// --- Clusters ----------------------------------------------------------------------------------

namespace {

struct ClusterTri {
	int surface;
	int first; // index of the triangle's first index in the surface's indices
	V3 centre;
};

// Splits tris[begin, end) at the median of the centroids along their bounding box's longest axis
// until a part has at most target triangles: compact clusters of target / 2 to target triangles.
void split_clusters(std::vector<ClusterTri> &tris, size_t begin, size_t end, size_t target, std::vector<std::pair<size_t, size_t>> &leaves) {
	if (end - begin <= target) {
		leaves.emplace_back(begin, end);
		return;
	}
	V3 lo(1e30, 1e30, 1e30), hi(-1e30, -1e30, -1e30);
	for (size_t i = begin; i < end; i++) {
		const V3 &c = tris[i].centre;
		lo = V3(std::min(lo.x, c.x), std::min(lo.y, c.y), std::min(lo.z, c.z));
		hi = V3(std::max(hi.x, c.x), std::max(hi.y, c.y), std::max(hi.z, c.z));
	}
	V3 ext = hi - lo;
	int axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2);
	auto key = [axis](const ClusterTri &t) { return axis == 0 ? t.centre.x : (axis == 1 ? t.centre.y : t.centre.z); };
	size_t mid = begin + (end - begin) / 2;
	// A total order (ties by surface and position in it): the same input always splits the same.
	std::nth_element(tris.begin() + begin, tris.begin() + mid, tris.begin() + end, [&](const ClusterTri &a, const ClusterTri &b) {
		double ka = key(a), kb = key(b);
		if (ka != kb) {
			return ka < kb;
		}
		return a.surface != b.surface ? a.surface < b.surface : a.first < b.first;
	});
	split_clusters(tris, begin, mid, target, leaves);
	split_clusters(tris, mid, end, target, leaves);
}

void copy_vertex(const std::vector<float> &src, std::vector<float> &dst, int v, int n) {
	if (!src.empty()) {
		dst.insert(dst.end(), src.begin() + size_t(v) * n, src.begin() + size_t(v + 1) * n);
	}
}

} // namespace

std::vector<std::vector<SurfaceOutput>> Tessellator::clusters(int max_triangles) const {
	std::vector<ClusterTri> tris;
	for (size_t s = 0; s < outputs_.size(); s++) {
		const SurfaceOutput &o = outputs_[s];
		for (size_t i = 0; i + 2 < o.indices.size(); i += 3) {
			V3 c;
			for (int k = 0; k < 3; k++) {
				size_t v = size_t(o.indices[i + k]) * 3;
				c = c + V3(o.positions[v], o.positions[v + 1], o.positions[v + 2]);
			}
			tris.push_back({ int(s), int(i), c * (1.0 / 3.0) });
		}
	}
	std::vector<std::pair<size_t, size_t>> leaves;
	if (!tris.empty()) {
		split_clusters(tris, 0, tris.size(), size_t(std::max(max_triangles, 1)), leaves);
	}
	std::vector<std::vector<int>> remap(outputs_.size());
	for (size_t s = 0; s < outputs_.size(); s++) {
		remap[s].assign(outputs_[s].positions.size() / 3, -1);
	}
	std::vector<std::vector<SurfaceOutput>> out;
	out.reserve(leaves.size());
	for (const std::pair<size_t, size_t> &leaf : leaves) {
		// Each cluster keeps its triangles in surface and source order.
		std::sort(tris.begin() + leaf.first, tris.begin() + leaf.second, [](const ClusterTri &a, const ClusterTri &b) {
			return a.surface != b.surface ? a.surface < b.surface : a.first < b.first;
		});
		std::vector<SurfaceOutput> cluster(outputs_.size());
		for (size_t s = 0; s < outputs_.size(); s++) {
			cluster[s].has_uv = outputs_[s].has_uv;
			cluster[s].has_uv2 = outputs_[s].has_uv2;
			cluster[s].has_colors = outputs_[s].has_colors;
			cluster[s].bone_count = outputs_[s].bone_count;
			cluster[s].shape_positions.resize(outputs_[s].shape_positions.size());
			cluster[s].shape_normals.resize(outputs_[s].shape_normals.size());
		}
		std::vector<std::pair<int, int>> touched;
		for (size_t i = leaf.first; i < leaf.second; i++) {
			const ClusterTri &t = tris[i];
			const SurfaceOutput &src = outputs_[t.surface];
			SurfaceOutput &dst = cluster[t.surface];
			for (int k = 0; k < 3; k++) {
				int v = src.indices[t.first + k];
				int &m = remap[t.surface][v];
				if (m < 0) {
					m = int(dst.positions.size() / 3);
					copy_vertex(src.positions, dst.positions, v, 3);
					copy_vertex(src.normals, dst.normals, v, 3);
					copy_vertex(src.tangents, dst.tangents, v, 4);
					copy_vertex(src.uv, dst.uv, v, 2);
					copy_vertex(src.uv2, dst.uv2, v, 2);
					copy_vertex(src.colors, dst.colors, v, 4);
					copy_vertex(src.custom0, dst.custom0, v, 4);
					copy_vertex(src.custom1, dst.custom1, v, 4);
					if (src.bone_count > 0) {
						for (int k = 0; k < src.bone_count; k++) {
							dst.bones.push_back(src.bones[size_t(v) * src.bone_count + k]);
						}
						copy_vertex(src.weights, dst.weights, v, src.bone_count);
					}
					for (size_t sh = 0; sh < src.shape_positions.size(); sh++) {
						copy_vertex(src.shape_positions[sh], dst.shape_positions[sh], v, 3);
						copy_vertex(src.shape_normals[sh], dst.shape_normals[sh], v, 3);
					}
					touched.emplace_back(t.surface, v);
				}
				dst.indices.push_back(m);
			}
		}
		for (const std::pair<int, int> &p : touched) {
			remap[p.first][p.second] = -1;
		}
		out.push_back(std::move(cluster));
	}
	return out;
}

} // namespace gads
