#include "gads_terrain_mesher.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

namespace godot {

void GADSTerrainMesher::_bind_methods() {
	ClassDB::bind_static_method("GADSTerrainMesher", D_METHOD("build_chunk", "grid", "cx", "cz"), &GADSTerrainMesher::build_chunk);
}

namespace {

// Mesh.ArrayType
enum {
	ARRAY_VERTEX = 0,
	ARRAY_NORMAL = 1,
	ARRAY_TANGENT = 2,
	ARRAY_COLOR = 3,
	ARRAY_TEX_UV = 4,
	ARRAY_INDEX = 12,
	ARRAY_MAX = 13,
};

double smoothstep(double from, double to, double x) {
	double s = std::clamp((x - from) / (to - from), 0.0, 1.0);
	return s * s * (3.0 - 2.0 * s);
}

double tri_interp(double h00, double h10, double h01, double h11, double fx, double fz) {
	if (fx + fz <= 1.0) {
		return h00 + fx * (h10 - h00) + fz * (h01 - h00);
	}
	return h11 + (1.0 - fx) * (h01 - h11) + (1.0 - fz) * (h10 - h11);
}

// The terrain's grid as GADSTerrain3D describes it (see _grid_state() there).
struct Grid {
	int nx = 0, nz = 0;
	double spacing = 1.0;
	Vector2 origin;
	// Heights: the whole terrain's array, or the heightmap sampled bilinearly (streaming).
	PackedFloat32Array heights;
	PackedFloat32Array src;
	int src_w = 0, src_h = 0;
	double height_offset = 0.0, height_scale = 1.0;
	// Weights: per-vertex arrays, or the splat map (RGBA floats, nearest), or the rules.
	PackedFloat32Array w1, w2;
	PackedFloat32Array splat;
	int splat_w = 0, splat_h = 0;
	int slope_layer = 0, height_layer = 0;
	Vector2 slope_range, height_band;

	double h(int gx, int gz) const {
		gx = std::clamp(gx, 0, nx - 1);
		gz = std::clamp(gz, 0, nz - 1);
		if (!heights.is_empty()) {
			return heights[int64_t(gz) * nx + gx];
		}
		if (src.is_empty() || src_w < 1 || src_h < 1) {
			return height_offset;
		}
		const float *d = src.ptr();
		double py = double(gz) / (nz - 1) * (src_h - 1);
		int y0 = src_h > 1 ? std::min(int(std::floor(py)), src_h - 2) : 0;
		double fy = src_h > 1 ? py - y0 : 0.0;
		double px = double(gx) / (nx - 1) * (src_w - 1);
		int x0 = src_w > 1 ? std::min(int(std::floor(px)), src_w - 2) : 0;
		double fx = src_w > 1 ? px - x0 : 0.0;
		int x1 = std::min(x0 + 1, src_w - 1);
		int y1 = std::min(y0 + 1, src_h - 1);
		double top = d[size_t(y0) * src_w + x0] + (d[size_t(y0) * src_w + x1] - d[size_t(y0) * src_w + x0]) * fx;
		double bottom = d[size_t(y1) * src_w + x0] + (d[size_t(y1) * src_w + x1] - d[size_t(y1) * src_w + x0]) * fx;
		return height_offset + height_scale * (top + (bottom - top) * fy);
	}

	Vector3 normal(int x, int z) const {
		int xa = std::max(x - 1, 0), xb = std::min(x + 1, nx - 1);
		int za = std::max(z - 1, 0), zb = std::min(z + 1, nz - 1);
		double dhdx = (h(xb, z) - h(xa, z)) / ((xb - xa) * spacing);
		double dhdz = (h(x, zb) - h(x, za)) / ((zb - za) * spacing);
		return Vector3(real_t(-dhdx), 1.0, real_t(-dhdz)).normalized();
	}

	Vector2 weights(int gx, int gz) const {
		gx = std::clamp(gx, 0, nx - 1);
		gz = std::clamp(gz, 0, nz - 1);
		if (!w1.is_empty()) {
			int64_t i = int64_t(gz) * nx + gx;
			return Vector2(w1[i], w2[i]);
		}
		if (!splat.is_empty() && splat_w > 0 && splat_h > 0) {
			int px = std::clamp(int(std::lround(double(gx) / (nx - 1) * (splat_w - 1))), 0, splat_w - 1);
			int py = std::clamp(int(std::lround(double(gz) / (nz - 1) * (splat_h - 1))), 0, splat_h - 1);
			int64_t k = (int64_t(py) * splat_w + px) * 4;
			return Vector2(splat[k], splat[k + 1]);
		}
		Vector2 out;
		Vector3 n = normal(gx, gz);
		double deg = std::acos(std::clamp(double(n.y), -1.0, 1.0)) * 180.0 / 3.14159265358979323846;
		double slope = smoothstep(slope_range.x, std::max(double(slope_range.y), double(slope_range.x) + 0.001), deg);
		double high = smoothstep(height_band.x, std::max(double(height_band.y), double(height_band.x) + 0.001), h(gx, gz));
		const int layer[2] = { slope_layer, height_layer };
		const double value[2] = { slope, high };
		for (int r = 0; r < 2; r++) {
			if (layer[r] == 1) {
				out.x = std::max(out.x, real_t(value[r]));
			} else if (layer[r] == 2) {
				out.y = std::max(out.y, real_t(value[r]));
			}
		}
		return out;
	}
};

// The vertices of a chunk's border, once around: -Z side, +X side, +Z side, -X side.
std::vector<Vector2i> ring_of(int cq) {
	std::vector<Vector2i> ring;
	for (int x = 0; x < cq; x++) {
		ring.push_back(Vector2i(x, 0));
	}
	for (int z = 0; z < cq; z++) {
		ring.push_back(Vector2i(cq, z));
	}
	for (int x = cq; x > 0; x--) {
		ring.push_back(Vector2i(x, cq));
	}
	for (int z = cq; z > 0; z--) {
		ring.push_back(Vector2i(0, z));
	}
	return ring;
}

// Triangles of a chunk's grid at stride s and its skirts (GADSTerrain3D._chunk_indices).
PackedInt32Array chunk_indices(int cq, int s, const std::vector<Vector2i> &ring) {
	int n = cq + 1;
	std::vector<int32_t> idx;
	for (int z = 0; z < cq; z += s) {
		for (int x = 0; x < cq; x += s) {
			int a = z * n + x, b = a + s, c = a + s * n, d = c + s;
			idx.insert(idx.end(), { a, b, c, b, d, c });
		}
	}
	int rs = int(ring.size());
	for (int r = 0; r < rs; r += s) {
		int r2 = (r + s) % rs;
		int top_a = ring[r].y * n + ring[r].x;
		int top_b = ring[r2].y * n + ring[r2].x;
		int low_a = n * n + r, low_b = n * n + r2;
		idx.insert(idx.end(), { top_a, low_a, top_b, top_b, low_a, low_b });
	}
	PackedInt32Array out;
	out.resize(int64_t(idx.size()));
	std::copy(idx.begin(), idx.end(), out.ptrw());
	return out;
}

// A conservative occluder of a chunk (GADSTerrain3D._occluder_arrays).
Dictionary occluder_of(const PackedFloat32Array &heights, const PackedVector3Array &verts, int cq, int quads) {
	int n = cq + 1;
	int s = 1;
	while (s * 2 <= cq && cq / (s * 2) >= std::max(quads, 1)) {
		s *= 2;
	}
	double worst = 0.0;
	for (int z = 0; z < n; z++) {
		for (int x = 0; x < n; x++) {
			int x0 = std::min((x / s) * s, cq - s);
			int z0 = std::min((z / s) * s, cq - s);
			double hc = tri_interp(heights[z0 * n + x0], heights[z0 * n + x0 + s], heights[(z0 + s) * n + x0], heights[(z0 + s) * n + x0 + s],
					double(x - x0) / s, double(z - z0) / s);
			worst = std::max(worst, hc - heights[z * n + x]);
		}
	}
	double drop = worst + 0.01;
	PackedVector3Array points;
	int m = cq / s + 1;
	for (int z = 0; z < n; z += s) {
		for (int x = 0; x < n; x += s) {
			points.push_back(verts[z * n + x] - Vector3(0, real_t(drop), 0));
		}
	}
	PackedInt32Array idx;
	for (int z = 0; z < m - 1; z++) {
		for (int x = 0; x < m - 1; x++) {
			int a = z * m + x, b = a + 1, c = a + m, d = c + 1;
			for (int v : { a, b, c, b, d, c }) {
				idx.push_back(v);
			}
		}
	}
	Dictionary out;
	out["vertices"] = points;
	out["indices"] = idx;
	out["drop"] = drop;
	return out;
}

} // namespace

// A chunk's {"arrays", "lods", "heights" (and "occluder")}, as GADSTerrain3D._chunk_arrays builds
// it. p_grid: "nx", "nz", "spacing", "origin", "cq", "levels", "occluder_quads" (< 1: none);
// heights from "heights" (nx * nz) or "src" + "src_w", "src_h", "height_offset", "height_scale";
// weights from "w1" + "w2" (nx * nz), or "splat" (RGBA) + "splat_w", "splat_h", or the rules
// "slope_layer", "slope_range", "height_layer", "height_band".
Dictionary GADSTerrainMesher::build_chunk(const Dictionary &p_grid, int p_cx, int p_cz) {
	Grid g;
	g.nx = p_grid.get("nx", 0);
	g.nz = p_grid.get("nz", 0);
	ERR_FAIL_COND_V_MSG(g.nx < 2 || g.nz < 2, Dictionary(), "GADSTerrainMesher: the grid needs at least 2 x 2 vertices.");
	g.spacing = p_grid.get("spacing", 1.0);
	g.origin = p_grid.get("origin", Vector2());
	g.heights = p_grid.get("heights", PackedFloat32Array());
	g.src = p_grid.get("src", PackedFloat32Array());
	g.src_w = p_grid.get("src_w", 0);
	g.src_h = p_grid.get("src_h", 0);
	g.height_offset = p_grid.get("height_offset", 0.0);
	g.height_scale = p_grid.get("height_scale", 1.0);
	g.w1 = p_grid.get("w1", PackedFloat32Array());
	g.w2 = p_grid.get("w2", PackedFloat32Array());
	g.splat = p_grid.get("splat", PackedFloat32Array());
	g.splat_w = p_grid.get("splat_w", 0);
	g.splat_h = p_grid.get("splat_h", 0);
	g.slope_layer = p_grid.get("slope_layer", 0);
	g.height_layer = p_grid.get("height_layer", 0);
	g.slope_range = p_grid.get("slope_range", Vector2(28, 40));
	g.height_band = p_grid.get("height_band", Vector2(30, 34));
	if (!g.heights.is_empty() && g.heights.size() < int64_t(g.nx) * g.nz) {
		g.heights = PackedFloat32Array();
	}
	if (!g.w1.is_empty() && (g.w1.size() < int64_t(g.nx) * g.nz || g.w2.size() < int64_t(g.nx) * g.nz)) {
		g.w1 = PackedFloat32Array();
	}
	const int cq = p_grid.get("cq", 64);
	const int levels = p_grid.get("levels", 1);
	const int occluder_quads = p_grid.get("occluder_quads", 0);
	const int n = cq + 1;
	const int gx0 = p_cx * cq, gz0 = p_cz * cq;
	const std::vector<Vector2i> ring = ring_of(cq);
	const int count = n * n + int(ring.size());
	PackedVector3Array verts, normals;
	PackedFloat32Array tangents, heights;
	PackedColorArray colors;
	PackedVector2Array uvs;
	verts.resize(count);
	normals.resize(count);
	tangents.resize(count * 4);
	colors.resize(count);
	uvs.resize(count);
	heights.resize(n * n);
	Vector3 *vp = verts.ptrw();
	Vector3 *np = normals.ptrw();
	float *tp = tangents.ptrw();
	Color *cp = colors.ptrw();
	Vector2 *up = uvs.ptrw();
	float *hp = heights.ptrw();
	const double ex = (g.nx - 1) * g.spacing, ez = (g.nz - 1) * g.spacing;
	for (int z = 0; z < n; z++) {
		for (int x = 0; x < n; x++) {
			int i = z * n + x;
			int gx = gx0 + x, gz = gz0 + z;
			Vector3 nrm = g.normal(gx, gz);
			hp[i] = float(g.h(gx, gz));
			vp[i] = Vector3(real_t(g.origin.x + gx * g.spacing), hp[i], real_t(g.origin.y + gz * g.spacing));
			np[i] = nrm;
			Vector3 t = (Vector3(1, 0, 0) - nrm * nrm.dot(Vector3(1, 0, 0))).normalized();
			tp[i * 4] = t.x;
			tp[i * 4 + 1] = t.y;
			tp[i * 4 + 2] = t.z;
			tp[i * 4 + 3] = 1.0f;
			Vector2 w = g.weights(gx, gz);
			cp[i] = Color(w.x, w.y, 0.0, 1.0);
			up[i] = Vector2(real_t(gx * g.spacing / ex), real_t(gz * g.spacing / ez));
		}
	}
	// The height error of each LOD: the finest grid against the LOD's triangles.
	std::vector<double> errors(std::max(levels, 1), 0.0);
	for (int k = 1; k < levels; k++) {
		int s = 1 << k;
		double worst = 0.0;
		for (int z = 0; z < n; z++) {
			for (int x = 0; x < n; x++) {
				int x0 = std::min((x / s) * s, cq - s);
				int z0 = std::min((z / s) * s, cq - s);
				double hc = tri_interp(hp[z0 * n + x0], hp[z0 * n + x0 + s], hp[(z0 + s) * n + x0], hp[(z0 + s) * n + x0 + s],
						double(x - x0) / s, double(z - z0) / s);
				worst = std::max(worst, std::fabs(hp[z * n + x] - hc));
			}
		}
		errors[k] = worst;
	}
	// Skirts: as deep as twice the largest error (see GADSTerrain3D._chunk_arrays).
	double largest = 0.0;
	for (double e : errors) {
		largest = std::max(largest, e);
	}
	double skirt = 2.0 * largest + g.spacing * 0.05 + 0.01;
	for (int r = 0; r < int(ring.size()); r++) {
		int src = ring[r].y * n + ring[r].x;
		int i = n * n + r;
		vp[i] = vp[src] - Vector3(0, real_t(skirt), 0);
		np[i] = np[src];
		for (int c = 0; c < 4; c++) {
			tp[i * 4 + c] = tp[src * 4 + c];
		}
		cp[i] = cp[src];
		up[i] = up[src];
	}
	Array arrays;
	arrays.resize(ARRAY_MAX);
	arrays[ARRAY_VERTEX] = verts;
	arrays[ARRAY_NORMAL] = normals;
	arrays[ARRAY_TANGENT] = tangents;
	arrays[ARRAY_COLOR] = colors;
	arrays[ARRAY_TEX_UV] = uvs;
	arrays[ARRAY_INDEX] = chunk_indices(cq, 1, ring);
	Dictionary lods;
	double key = 0.0;
	for (int k = 1; k < levels; k++) {
		key = std::max(errors[k], key + 1e-5);
		lods[key] = chunk_indices(cq, 1 << k, ring);
	}
	Dictionary out;
	out["arrays"] = arrays;
	out["lods"] = lods;
	out["heights"] = heights;
	if (occluder_quads > 0) {
		out["occluder"] = occluder_of(heights, verts, cq, occluder_quads);
	}
	return out;
}

} // namespace godot
