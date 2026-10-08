#include "height_gen.h"

#include "../tess/parallel.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace gads {

namespace {

constexpr double TAU = 6.283185307179586;

uint32_t hash3(int32_t x, int32_t y, uint32_t seed) {
	uint32_t h = seed * 0x9E3779B1u;
	h ^= uint32_t(x) * 0x85EBCA77u;
	h = (h << 13) | (h >> 19);
	h ^= uint32_t(y) * 0xC2B2AE3Du;
	h ^= h >> 15;
	h *= 0x2C1B3C6Du;
	h ^= h >> 12;
	h *= 0x297A2D39u;
	h ^= h >> 15;
	return h;
}

// Uniform in [0, 1).
double rnd(int x, int y, uint32_t seed) {
	return hash3(x, y, seed) * (1.0 / 4294967296.0);
}

int wrap(int i, int n) {
	int r = i % n;
	return r < 0 ? r + n : r;
}

// Wrapped difference on the unit torus, in -0.5..0.5.
double torus(double d) {
	return d - std::floor(d + 0.5);
}

double fade(double t) {
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

double lerp(double a, double b, double t) {
	return a + (b - a) * t;
}

double smoothstep(double e0, double e1, double x) {
	double t = std::clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// Gradient noise, about -1..1, with a period of `period` lattice cells in x and y.
double gnoise(double x, double y, int period, uint32_t seed) {
	double xf = std::floor(x), yf = std::floor(y);
	int x0 = int(xf), y0 = int(yf);
	double fx = x - xf, fy = y - yf;
	auto grad = [&](int ix, int iy, double dx, double dy) {
		double a = rnd(wrap(ix, period), wrap(iy, period), seed) * TAU;
		return std::cos(a) * dx + std::sin(a) * dy;
	};
	double u = fade(fx), v = fade(fy);
	double n00 = grad(x0, y0, fx, fy);
	double n10 = grad(x0 + 1, y0, fx - 1.0, fy);
	double n01 = grad(x0, y0 + 1, fx, fy - 1.0);
	double n11 = grad(x0 + 1, y0 + 1, fx - 1.0, fy - 1.0);
	return lerp(lerp(n00, n10, u), lerp(n01, n11, u), v) * 1.41421356;
}

struct Noise {
	int base = 4; // period of the first octave
	int lacunarity = 2;
	int octaves = 5;
	double gain = 0.5;
	int max_period = 1 << 20;
	uint32_t seed = 1;

	// fBm at (u, v) in tile units; mode 0 plain, 1 ridged, 2 billow. About -1..1 (ridged and
	// billow 0..1).
	double operator()(double u, double v, int mode = 0) const {
		double sum = 0.0, amp = 1.0, norm = 0.0;
		long period = base;
		for (int o = 0; o < octaves && period <= max_period; o++) {
			double n = gnoise(u * period, v * period, int(period), seed + uint32_t(o) * 1013u);
			if (mode == 1) {
				n = 1.0 - std::fabs(n);
				n *= n;
			} else if (mode == 2) {
				n = std::fabs(n);
			}
			sum += amp * n;
			norm += amp;
			amp *= gain;
			period *= lacunarity;
		}
		return norm > 0.0 ? sum / norm : 0.0;
	}
};

Noise make_noise(const GenParams &p, int size, double scale, uint32_t seed, int octaves) {
	Noise n;
	n.base = std::max(1, int(std::lround(scale)));
	n.lacunarity = std::max(1, int(std::lround(p.lacunarity)));
	n.octaves = std::clamp(octaves, 1, 16);
	n.gain = p.gain;
	n.max_period = std::max(1, size / 2);
	n.seed = seed;
	return n;
}

// Voronoi on an n x n wrapped grid of jittered points: the distance to the nearest point's cell
// border (in cells) and that cell's wrapped index.
struct Voronoi {
	int n = 4;
	uint32_t seed = 1;
	double jitter = 0.8;

	void point(int ci, int cj, double &px, double &py) const {
		int wi = wrap(ci, n), wj = wrap(cj, n);
		px = ci + 0.5 + jitter * (rnd(wi, wj, seed) - 0.5);
		py = cj + 0.5 + jitter * (rnd(wi, wj, seed + 17u) - 0.5);
	}

	// (x, y) in cells.
	void query(double x, double y, double &edge, int &cell_i, int &cell_j) const {
		int cx = int(std::floor(x)), cy = int(std::floor(y));
		double best = 1e30, ax = 0.0, ay = 0.0;
		int bi = cx, bj = cy;
		for (int j = -2; j <= 2; j++) {
			for (int i = -2; i <= 2; i++) {
				double px, py;
				point(cx + i, cy + j, px, py);
				double d = (px - x) * (px - x) + (py - y) * (py - y);
				if (d < best) {
					best = d;
					ax = px;
					ay = py;
					bi = cx + i;
					bj = cy + j;
				}
			}
		}
		// Exact distance to the border: the nearest bisector between the nearest point and another.
		edge = 1e30;
		for (int j = -2; j <= 2; j++) {
			for (int i = -2; i <= 2; i++) {
				int ci = bi + i, cj = bj + j;
				if (ci == bi && cj == bj) {
					continue;
				}
				double px, py;
				point(ci, cj, px, py);
				double dx = px - ax, dy = py - ay;
				double len = std::sqrt(dx * dx + dy * dy);
				if (len < 1e-9) {
					continue;
				}
				double mx = 0.5 * (px + ax) - x, my = 0.5 * (py + ay) - y;
				edge = std::min(edge, (mx * dx + my * dy) / len);
			}
		}
		cell_i = wrap(bi, n);
		cell_j = wrap(bj, n);
	}
};

// A rounded plateau: 0 within half the gap of a border, rising over `bevel` like a quarter circle.
double plateau(double border, double width, double bevel) {
	double s = std::clamp((border - 0.5 * width) / std::max(bevel, 1e-6), 0.0, 1.0);
	return border < 0.5 * width ? 0.0 : std::sqrt(s * (2.0 - s));
}

void normalise(std::vector<float> &h) {
	if (h.empty()) {
		return;
	}
	auto [lo, hi] = std::minmax_element(h.begin(), h.end());
	double a = *lo, b = *hi;
	double inv = b - a > 1e-12 ? 1.0 / (b - a) : 0.0;
	for (float &x : h) {
		x = float((x - a) * inv);
	}
}

} // namespace

const std::vector<std::string> &generator_kinds() {
	static const std::vector<std::string> kinds = { "noise", "ridged", "billow", "rock", "stones", "cracks", "bricks", "tiles",
		"waves", "ripples", "craters", "scales", "dunes" };
	return kinds;
}

std::vector<float> generate(const std::string &kind, int size, const GenParams &p, int threads, std::string &error) {
	std::vector<float> out;
	if (size < 4 || size > 8192) {
		error = "size must be 4..8192";
		return out;
	}
	const auto &kinds = generator_kinds();
	int k = int(std::find(kinds.begin(), kinds.end(), kind) - kinds.begin());
	if (k >= int(kinds.size())) {
		error = "unknown kind '" + kind + "'";
		return out;
	}
	out.resize(size_t(size) * size);
	const uint32_t seed = uint32_t(p.seed) * 7919u + 1u;
	const double scale = std::max(1.0, p.scale);
	const int cells = std::max(1, int(std::lround(scale)));
	Noise noise = make_noise(p, size, scale, seed, p.octaves);
	Noise warp_x = make_noise(p, size, scale, seed + 501u, 3);
	Noise warp_y = make_noise(p, size, scale, seed + 907u, 3);
	Noise fine = make_noise(p, size, scale * 8.0, seed + 101u, 3);
	Voronoi vor;
	vor.n = cells;
	vor.seed = seed + 31u;
	// Bricks: an even number of rows, a whole number of bricks per row (half-brick offset on odd
	// rows), so the pattern tiles.
	int rows = std::max(2, cells + (cells & 1));
	int per_row = kind == "tiles" || kind == "scales" ? rows : std::max(1, int(std::lround(rows / std::max(p.aspect, 0.1))));
	// Waves: integer wave vectors around a main direction.
	struct Wave {
		int a, b;
		double phase, amp;
	};
	std::vector<Wave> waves;
	if (kind == "waves") {
		double main = rnd(1, 2, seed) * TAU;
		for (int i = 0; i < 6; i++) {
			double ang = main + (rnd(i, 3, seed) - 0.5) * 1.2;
			double mag = scale * (0.6 + 0.8 * rnd(i, 4, seed)) * (1.0 + 0.35 * i);
			int a = int(std::lround(mag * std::cos(ang))), b = int(std::lround(mag * std::sin(ang)));
			if (a == 0 && b == 0) {
				a = 1;
			}
			waves.push_back({ a, b, rnd(i, 5, seed) * TAU, 1.0 / (1.0 + 0.6 * i) });
		}
	}
	// Ripples and craters: centres on the torus.
	struct Spot {
		double x, y, r;
	};
	std::vector<Spot> spots;
	if (kind == "ripples" || kind == "craters") {
		int count = p.count > 0 ? p.count : (kind == "ripples" ? cells : cells * cells / 2 + 1);
		for (int i = 0; i < count; i++) {
			double r = kind == "craters" ? std::min(0.2, (0.3 + 0.7 * rnd(i, 9, seed)) * 0.5 / scale) : 0.0;
			spots.push_back({ rnd(i, 7, seed), rnd(i, 8, seed), r });
		}
	}
	// Dunes: crests across a whole-number direction, so the pattern tiles.
	int dune_a = cells, dune_b = int(std::lround(cells * 0.6 * (rnd(3, 1, seed) - 0.5)));
	const double sharp = std::clamp(p.sharpness, 0.0, 1.0);
	parallel_for(size_t(size), threads, [&](size_t row) {
		for (int col = 0; col < size; col++) {
			double u = (col + 0.5) / size, v = (row + 0.5) / size;
			if (p.warp != 0.0) {
				double wu = warp_x(u, v), wv = warp_y(u, v);
				u += p.warp * wu / cells;
				v += p.warp * wv / cells;
			}
			double h = 0.0;
			switch (k) {
				case 0: // noise
					h = noise(u, v, 0);
					break;
				case 1: // ridged
					h = noise(u, v, 1);
					break;
				case 2: // billow
					h = noise(u, v, 2);
					break;
				case 3: // rock: ridged crests over rolling noise
					h = 0.65 * noise(u, v, 1) + 0.35 * (0.5 + 0.5 * noise(u + 0.37, v + 0.71, 0));
					break;
				case 4: // stones
				case 5: { // cracks
					double edge;
					int ci, cj;
					vor.query(u * cells, v * cells, edge, ci, cj);
					if (k == 4) {
						h = plateau(edge, p.width, p.bevel) * (1.0 - p.variation * rnd(ci, cj, seed + 61u));
					} else {
						h = 1.0 - (1.0 - smoothstep(0.0, std::max(p.width, 1e-4), edge)) * (1.0 - 0.5 * p.variation * rnd(ci, cj, seed + 61u));
					}
					h += p.roughness * fine(u, v, 0);
					break;
				}
				case 6: // bricks
				case 7: { // tiles
					double fr = v * rows;
					int r = int(std::floor(fr));
					double offset = (k == 6 && (wrap(r, rows) & 1)) ? 0.5 : 0.0;
					double fc = u * per_row + offset;
					int c = int(std::floor(fc));
					double fu = fc - c, fv = fr - r;
					// Distances to the border in row heights.
					double dx = std::min(fu, 1.0 - fu) * double(rows) / per_row;
					double dy = std::min(fv, 1.0 - fv);
					h = plateau(std::min(dx, dy), p.width, p.bevel) * (1.0 - p.variation * rnd(wrap(c, per_row), wrap(r, rows), seed + 61u));
					h += p.roughness * fine(u, v, 0);
					break;
				}
				case 8: { // waves
					for (const Wave &w : waves) {
						double s = 0.5 + 0.5 * std::sin(TAU * (w.a * u + w.b * v) + w.phase);
						h += w.amp * std::pow(s, 1.0 + 4.0 * sharp);
					}
					break;
				}
				case 9: { // ripples
					double freq = 3.0 * scale;
					for (const Spot &s : spots) {
						double dx = torus(u - s.x), dy = torus(v - s.y);
						double r = std::sqrt(dx * dx + dy * dy);
						double window = 1.0 - smoothstep(0.3, 0.5, r);
						h += std::cos(TAU * r * freq) * std::exp(-r * 6.0) * window;
					}
					break;
				}
				case 11: { // scales: rows of overlapping discs, half a scale offset per row, each a dome;
					// where discs overlap the lower row's lies on top (as on a fish or a lizard)
					double fr = v * rows;
					int r = int(std::floor(fr));
					bool covered = false;
					for (int rr = r + 1; rr >= r - 1 && !covered; rr--) {
						double offset = (wrap(rr, rows) & 1) ? 0.5 : 0.0;
						double fc = u * per_row - offset;
						int c0 = int(std::floor(fc));
						for (int c = c0 - 1; c <= c0 + 1 && !covered; c++) {
							double du = (fc - (c + 0.5)) / 0.62;
							double dv = (fr - (rr + 0.15)) / 0.85;
							double t2 = du * du + dv * dv;
							if (t2 < 1.0) {
								covered = true;
								h = (0.25 + 0.75 * std::sqrt(1.0 - t2)) * (1.0 - p.variation * rnd(wrap(c, per_row), wrap(rr, rows), seed + 61u));
							}
						}
					}
					h += p.roughness * fine(u, v, 0);
					break;
				}
				case 12: { // dunes: a gentle windward slope and a steep lee face, bent by noise, with
					// fine wind ripples on top
					double w = 0.3 * warp_x(u, v);
					double s = dune_a * u + dune_b * v + w;
					s -= std::floor(s);
					h = s < 0.78 ? smoothstep(0.0, 1.0, s / 0.78) : 1.0 - smoothstep(0.0, 1.0, (s - 0.78) / 0.22);
					h += 0.06 * (0.5 + 0.5 * std::sin(TAU * (7 * dune_a * u + (7 * dune_b + 2) * v + 3.0 * w)));
					h += p.roughness * fine(u, v, 0);
					break;
				}
				case 10: { // craters
					for (const Spot &s : spots) {
						double dx = torus(u - s.x), dy = torus(v - s.y);
						double t = std::sqrt(dx * dx + dy * dy) / s.r;
						if (t > 2.0) {
							continue;
						}
						double bowl = t < 1.0 ? -(1.0 - t * t) : 0.0;
						double rim = 0.35 * std::exp(-((t - 1.0) / 0.25) * ((t - 1.0) / 0.25));
						h += (bowl + rim) * (1.0 - smoothstep(1.5, 2.0, t));
					}
					h += p.roughness * fine(u, v, 0);
					break;
				}
			}
			out[row * size + col] = float(h);
		}
	});
	normalise(out);
	return out;
}

namespace {

double at(const std::vector<float> &h, int w, int ht, int x, int y) {
	return h[size_t(wrap(y, ht)) * w + wrap(x, w)];
}

double bilinear(const std::vector<float> &h, int w, int ht, double x, double y) {
	double xf = std::floor(x), yf = std::floor(y);
	int x0 = int(xf), y0 = int(yf);
	double fx = x - xf, fy = y - yf;
	return lerp(lerp(at(h, w, ht, x0, y0), at(h, w, ht, x0 + 1, y0), fx), lerp(at(h, w, ht, x0, y0 + 1), at(h, w, ht, x0 + 1, y0 + 1), fx), fy);
}

} // namespace

std::vector<float> normal_map(const std::vector<float> &height, int w, int h, double depth_m, double tile_x_m, double tile_y_m, int threads) {
	std::vector<float> out(size_t(w) * h * 3);
	double tx = tile_x_m / w, ty = tile_y_m / h;
	parallel_for(size_t(h), threads, [&](size_t y) {
		for (int x = 0; x < w; x++) {
			double du = (at(height, w, h, x + 1, int(y)) - at(height, w, h, x - 1, int(y))) * depth_m / (2.0 * tx);
			double dv = (at(height, w, h, x, int(y) + 1) - at(height, w, h, x, int(y) - 1)) * depth_m / (2.0 * ty);
			double nx = -du, ny = dv, nz = 1.0;
			double len = std::sqrt(nx * nx + ny * ny + nz * nz);
			size_t i = (y * w + x) * 3;
			out[i] = float(0.5 + 0.5 * nx / len);
			out[i + 1] = float(0.5 + 0.5 * ny / len);
			out[i + 2] = float(0.5 + 0.5 * nz / len);
		}
	});
	return out;
}

std::vector<float> ambient_occlusion(const std::vector<float> &height, int w, int h, double depth_m, double tile_x_m, double tile_y_m, double radius_m, int threads) {
	std::vector<float> out(size_t(w) * h, 1.0f);
	double tx = tile_x_m / w, ty = tile_y_m / h;
	constexpr int DIRECTIONS = 8, STEPS = 12;
	parallel_for(size_t(h), threads, [&](size_t y) {
		for (int x = 0; x < w; x++) {
			double h0 = at(height, w, h, x, int(y));
			double open = 0.0;
			for (int d = 0; d < DIRECTIONS; d++) {
				double a = TAU * (d + 0.5) / DIRECTIONS;
				double cx = std::cos(a), cy = std::sin(a);
				double best = 0.0;
				for (int s = 1; s <= STEPS; s++) {
					double dist = radius_m * std::pow(double(s) / STEPS, 1.5);
					double hs = bilinear(height, w, h, x + cx * dist / tx, y + cy * dist / ty);
					best = std::max(best, (hs - h0) * depth_m / dist);
				}
				open += 1.0 - best / std::sqrt(1.0 + best * best);
			}
			out[y * w + x] = float(open / DIRECTIONS);
		}
	});
	return out;
}

std::vector<float> curvature(const std::vector<float> &height, int w, int h, double radius, double gain, int threads) {
	int r = std::max(1, int(std::lround(radius)));
	// Two box blurs (separable, wrapped): close to a Gaussian of the radius.
	std::vector<float> a = height, b(height.size());
	for (int pass = 0; pass < 2; pass++) {
		parallel_for(size_t(h), threads, [&](size_t y) {
			double sum = 0.0;
			for (int i = -r; i <= r; i++) {
				sum += at(a, w, h, i, int(y));
			}
			for (int x = 0; x < w; x++) {
				b[y * w + x] = float(sum / (2 * r + 1));
				sum += at(a, w, h, x + r + 1, int(y)) - at(a, w, h, x - r, int(y));
			}
		});
		parallel_for(size_t(w), threads, [&](size_t x) {
			double sum = 0.0;
			for (int i = -r; i <= r; i++) {
				sum += at(b, w, h, int(x), i);
			}
			for (int y = 0; y < h; y++) {
				a[size_t(y) * w + x] = float(sum / (2 * r + 1));
				sum += at(b, w, h, int(x), y + r + 1) - at(b, w, h, int(x), y - r);
			}
		});
	}
	std::vector<float> out(height.size());
	for (size_t i = 0; i < out.size(); i++) {
		out[i] = float(std::clamp(0.5 + gain * (height[i] - a[i]), 0.0, 1.0));
	}
	return out;
}

std::vector<float> colorize(const std::vector<float> &height, const std::vector<float> &ao, const std::vector<float> &curv, const float low[3],
		const float high[3], double ao_strength, double cavity_strength) {
	std::vector<float> out(height.size() * 3);
	for (size_t i = 0; i < height.size(); i++) {
		double t = std::clamp(double(height[i]), 0.0, 1.0);
		double shade = 1.0;
		if (i < ao.size()) {
			shade *= 1.0 - ao_strength * (1.0 - std::clamp(double(ao[i]), 0.0, 1.0));
		}
		if (i < curv.size()) {
			shade *= 1.0 - cavity_strength * std::clamp((0.5 - curv[i]) * 2.0, 0.0, 1.0);
		}
		for (int k = 0; k < 3; k++) {
			out[i * 3 + k] = float(std::clamp(lerp(low[k], high[k], t) * shade, 0.0, 1.0));
		}
	}
	return out;
}

std::vector<float> orm(const std::vector<float> &ao, const std::vector<float> &curv, size_t count, double roughness, double variation) {
	std::vector<float> out(count * 3);
	for (size_t i = 0; i < count; i++) {
		double c = i < curv.size() ? (curv[i] - 0.5) * 2.0 : 0.0;
		out[i * 3] = i < ao.size() ? ao[i] : 1.0f;
		out[i * 3 + 1] = float(std::clamp(roughness - variation * c, 0.0, 1.0));
		out[i * 3 + 2] = 0.0f;
	}
	return out;
}

} // namespace gads
