#include "erosion.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace gads {

namespace {

// xorshift64*: the same sequence on every platform (std:: distributions are not).
struct Rng {
	uint64_t s;
	explicit Rng(uint64_t seed) :
			s(seed * 0x9E3779B97F4A7C15ULL + 0x632BE59BD9B4E019ULL) {}
	double next() {
		s ^= s >> 12;
		s ^= s << 25;
		s ^= s >> 27;
		return double((s * 2685821657736338717ULL) >> 11) * (1.0 / 9007199254740992.0);
	}
};

struct Grid {
	std::vector<double> &v;
	int w, h;
	bool wrap;
	int wx(int x) const { return wrap ? ((x % w) + w) % w : x; }
	int wy(int y) const { return wrap ? ((y % h) + h) % h : y; }
	bool inside(int x, int y) const { return wrap || (x >= 0 && y >= 0 && x < w && y < h); }
	double &at(int x, int y) { return v[size_t(wy(y)) * w + wx(x)]; }
	double get(int x, int y) const { return v[size_t(wy(y)) * w + wx(x)]; }
	// Bilinear height and gradient at (x, y); the cell (ix, iy) must have all four corners.
	void sample(double x, double y, double &r_h, double &r_gx, double &r_gy) const {
		int ix = int(std::floor(x));
		int iy = int(std::floor(y));
		double u = x - ix;
		double t = y - iy;
		double h00 = get(ix, iy), h10 = get(ix + 1, iy), h01 = get(ix, iy + 1), h11 = get(ix + 1, iy + 1);
		r_gx = (h10 - h00) * (1.0 - t) + (h11 - h01) * t;
		r_gy = (h01 - h00) * (1.0 - u) + (h11 - h10) * u;
		r_h = h00 * (1.0 - u) * (1.0 - t) + h10 * u * (1.0 - t) + h01 * (1.0 - u) * t + h11 * u * t;
	}
	// Whether a droplet at (x, y) can be sampled.
	bool can_sample(double x, double y) const {
		return wrap || (x >= 0.0 && y >= 0.0 && x < w - 1 && y < h - 1);
	}
};

struct BrushCell {
	int dx, dy;
	double weight;
};

void hydraulic(Grid &g, const ErosionParams &p) {
	if (p.droplets <= 0 || g.w < 2 || g.h < 2) {
		return;
	}
	std::vector<BrushCell> brush;
	int r = std::max(p.radius, 1);
	for (int dy = -r; dy <= r; dy++) {
		for (int dx = -r; dx <= r; dx++) {
			double d = std::sqrt(double(dx * dx + dy * dy));
			if (d < r) {
				brush.push_back({ dx, dy, r - d });
			}
		}
	}
	std::vector<std::pair<double *, double>> cells;
	cells.reserve(brush.size());
	Rng rng(uint64_t(p.seed));
	double inertia = std::clamp(p.inertia, 0.0, 1.0);
	for (int d = 0; d < p.droplets; d++) {
		double x = rng.next() * (g.wrap ? g.w : g.w - 1);
		double y = rng.next() * (g.wrap ? g.h : g.h - 1);
		double dir_x = 0.0, dir_y = 0.0;
		double speed = 1.0, water = 1.0, sediment = 0.0;
		bool left = false;
		for (int step = 0; step < p.max_steps; step++) {
			int ix = int(std::floor(x));
			int iy = int(std::floor(y));
			double u = x - ix;
			double t = y - iy;
			double height, gx, gy;
			g.sample(x, y, height, gx, gy);
			dir_x = dir_x * inertia - gx * (1.0 - inertia);
			dir_y = dir_y * inertia - gy * (1.0 - inertia);
			double len = std::sqrt(dir_x * dir_x + dir_y * dir_y);
			if (len < 1e-12) {
				break;
			}
			dir_x /= len;
			dir_y /= len;
			double nx = x + dir_x;
			double ny = y + dir_y;
			if (!g.can_sample(nx, ny)) {
				left = true; // what it carries flows off the field
				break;
			}
			double new_height, ngx, ngy;
			g.sample(nx, ny, new_height, ngx, ngy);
			double delta = new_height - height;
			double cap = std::max(-delta * speed * water * p.capacity, p.min_capacity);
			if (sediment > cap || delta > 0.0) {
				// Uphill: fill the pit behind it (at most to its level); else drop the excess.
				double amount = delta > 0.0 ? std::min(delta, sediment) : (sediment - cap) * p.deposition;
				sediment -= amount;
				g.at(ix, iy) += amount * (1.0 - u) * (1.0 - t);
				g.at(ix + 1, iy) += amount * u * (1.0 - t);
				g.at(ix, iy + 1) += amount * (1.0 - u) * t;
				g.at(ix + 1, iy + 1) += amount * u * t;
			} else {
				// Take sediment from around it (never more than the drop to the next step).
				double amount = std::min((cap - sediment) * p.erosion, -delta);
				cells.clear();
				double total = 0.0;
				for (const BrushCell &b : brush) {
					int bx = ix + b.dx, by = iy + b.dy;
					if (!g.inside(bx, by)) {
						continue;
					}
					cells.push_back({ &g.at(bx, by), b.weight });
					total += b.weight;
				}
				for (auto &c : cells) {
					double take = amount * c.second / total;
					*c.first -= take;
					sediment += take;
				}
			}
			// Faster going down, slower going up.
			speed = std::sqrt(std::max(0.0, speed * speed - delta * p.gravity));
			water *= 1.0 - p.evaporation;
			x = g.wrap ? std::fmod(nx + g.w, double(g.w)) : nx;
			y = g.wrap ? std::fmod(ny + g.h, double(g.h)) : ny;
		}
		// A droplet that stops (stalls or runs out of steps) leaves its sediment where it is.
		if (!left && sediment > 0.0) {
			int ix = int(std::floor(x));
			int iy = int(std::floor(y));
			double u = x - ix;
			double t = y - iy;
			g.at(ix, iy) += sediment * (1.0 - u) * (1.0 - t);
			g.at(ix + 1, iy) += sediment * u * (1.0 - t);
			g.at(ix, iy + 1) += sediment * (1.0 - u) * t;
			g.at(ix + 1, iy + 1) += sediment * u * t;
		}
	}
}

void thermal(Grid &g, const ErosionParams &p) {
	if (p.thermal_iterations <= 0) {
		return;
	}
	const double talus = std::tan(std::clamp(p.talus_deg, 0.0, 89.0) * 3.14159265358979323846 / 180.0);
	const double rate = std::clamp(p.thermal_rate, 0.0, 1.0);
	static const int N[8][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } };
	std::vector<double> delta(g.v.size());
	for (int it = 0; it < p.thermal_iterations; it++) {
		std::fill(delta.begin(), delta.end(), 0.0);
		for (int y = 0; y < g.h; y++) {
			for (int x = 0; x < g.w; x++) {
				double hc = g.get(x, y);
				double excess[8];
				double total = 0.0, most = 0.0;
				for (int k = 0; k < 8; k++) {
					excess[k] = 0.0;
					int nx = x + N[k][0], ny = y + N[k][1];
					if (!g.inside(nx, ny)) {
						continue;
					}
					double dist = k < 4 ? 1.0 : 1.41421356237309505;
					double e = hc - g.get(nx, ny) - talus * dist;
					if (e > 0.0) {
						excess[k] = e;
						total += e;
						most = std::max(most, e);
					}
				}
				if (total <= 0.0) {
					continue;
				}
				// Half the steepest excess (so the two cells end level at most), shared by excess.
				double move = rate * most * 0.5;
				for (int k = 0; k < 8; k++) {
					if (excess[k] > 0.0) {
						double share = move * excess[k] / total;
						int nx = g.wx(x + N[k][0]), ny = g.wy(y + N[k][1]);
						delta[size_t(ny) * g.w + nx] += share;
						delta[size_t(y) * g.w + x] -= share;
					}
				}
			}
		}
		for (size_t i = 0; i < g.v.size(); i++) {
			g.v[i] += delta[i];
		}
	}
}

} // namespace

void erode(std::vector<float> &field, int w, int h, const ErosionParams &p) {
	if (w < 2 || h < 2 || field.size() < size_t(w) * h || p.cell_m <= 0.0 || p.height_m <= 0.0) {
		return;
	}
	// In texel units vertically too, so slopes are rise over run.
	const double to_texels = p.height_m / p.cell_m;
	std::vector<double> v(size_t(w) * h);
	for (size_t i = 0; i < v.size(); i++) {
		v[i] = field[i] * to_texels;
	}
	Grid g{ v, w, h, p.wrap };
	hydraulic(g, p);
	thermal(g, p);
	for (size_t i = 0; i < v.size(); i++) {
		field[i] = float(v[i] / to_texels);
	}
}

} // namespace gads
