#include "height_map.h"

#include <algorithm>
#include <cmath>

namespace gads {

HeightMap::HeightMap(int p_width, int p_height, std::vector<float> p_data) {
	Level base;
	base.w = std::max(p_width, 1);
	base.h = std::max(p_height, 1);
	base.avg = std::move(p_data);
	base.avg.resize(size_t(base.w) * base.h, 0.0f);
	base.lo = base.avg;
	base.hi = base.avg;
	levels_.push_back(std::move(base));
	// Each level halves (rounding up); a texel covers the 2 x 2 texels below it, wrapped.
	while (levels_.back().w > 1 || levels_.back().h > 1) {
		const Level &src = levels_.back();
		Level dst;
		dst.w = std::max((src.w + 1) / 2, 1);
		dst.h = std::max((src.h + 1) / 2, 1);
		dst.avg.resize(size_t(dst.w) * dst.h);
		dst.lo.resize(dst.avg.size());
		dst.hi.resize(dst.avg.size());
		for (int y = 0; y < dst.h; y++) {
			for (int x = 0; x < dst.w; x++) {
				double sum = 0.0;
				float lo = 1e30f, hi = -1e30f;
				for (int dy = 0; dy < 2; dy++) {
					for (int dx = 0; dx < 2; dx++) {
						size_t i = size_t(wrap(y * 2 + dy, src.h)) * src.w + wrap(x * 2 + dx, src.w);
						sum += src.avg[i];
						lo = std::min(lo, src.lo[i]);
						hi = std::max(hi, src.hi[i]);
					}
				}
				size_t o = size_t(y) * dst.w + x;
				dst.avg[o] = float(sum * 0.25);
				dst.lo[o] = lo;
				dst.hi[o] = hi;
			}
		}
		levels_.push_back(std::move(dst));
	}
}

double HeightMap::sample(V2 uv, int level) const {
	const Level &l = levels_[std::clamp(level, 0, level_count() - 1)];
	double x = uv.x * l.w - 0.5;
	double y = uv.y * l.h - 0.5;
	double fx0 = std::floor(x), fy0 = std::floor(y);
	double fx = x - fx0, fy = y - fy0;
	// The wrap of a large uv must not lose precision: reduce the integer part first.
	long long ix = (long long)fx0, iy = (long long)fy0;
	int x0 = int(((ix % l.w) + l.w) % l.w), y0 = int(((iy % l.h) + l.h) % l.h);
	int x1 = x0 + 1 == l.w ? 0 : x0 + 1, y1 = y0 + 1 == l.h ? 0 : y0 + 1;
	double a = l.avg[size_t(y0) * l.w + x0], b = l.avg[size_t(y0) * l.w + x1];
	double c = l.avg[size_t(y1) * l.w + x0], d = l.avg[size_t(y1) * l.w + x1];
	return (a + (b - a) * fx) * (1.0 - fy) + (c + (d - c) * fx) * fy;
}

double HeightMap::sample_lod(V2 uv, double lod) const {
	lod = std::clamp(lod, 0.0, double(level_count() - 1));
	int l0 = int(std::floor(lod));
	double f = lod - l0;
	double a = sample(uv, l0);
	return f > 0.0 ? a + (sample(uv, l0 + 1) - a) * f : a;
}

// Base-texel interval [a, b] (any integers) as at most two intervals inside [0, n).
static int wrap_interval(long long a, long long b, int n, long long r_out[2][2]) {
	if (b - a + 1 >= n) {
		r_out[0][0] = 0;
		r_out[0][1] = n - 1;
		return 1;
	}
	long long a_w = ((a % n) + n) % n;
	long long b_w = a_w + (b - a);
	if (b_w < n) {
		r_out[0][0] = a_w;
		r_out[0][1] = b_w;
		return 1;
	}
	r_out[0][0] = a_w;
	r_out[0][1] = n - 1;
	r_out[1][0] = 0;
	r_out[1][1] = b_w - n;
	return 2;
}

void HeightMap::range(V2 uv_min, V2 uv_max, double &r_lo, double &r_hi) const {
	const Level &base = levels_[0];
	// The texels a bilinear sample anywhere in the rectangle can touch, wrapped into the tile
	// first (a coarser level's texel covers the base texels below it only inside the tile).
	long long x0 = (long long)std::floor(uv_min.x * base.w - 0.5), x1 = (long long)std::floor(uv_max.x * base.w - 0.5) + 1;
	long long y0 = (long long)std::floor(uv_min.y * base.h - 0.5), y1 = (long long)std::floor(uv_max.y * base.h - 0.5) + 1;
	long long xs[2][2], ys[2][2];
	int nx = wrap_interval(x0, x1, base.w, xs);
	int ny = wrap_interval(y0, y1, base.h, ys);
	double lo = 1e30, hi = -1e30;
	for (int i = 0; i < nx; i++) {
		for (int j = 0; j < ny; j++) {
			// The coarsest level at which this piece spans at most 4 texels per side.
			long long span = std::max(xs[i][1] - xs[i][0] + 1, ys[j][1] - ys[j][0] + 1);
			int level = 0;
			while (level + 1 < level_count() && (span >> level) > 4) {
				level++;
			}
			const Level &l = levels_[level];
			for (long long y = ys[j][0] >> level; y <= (ys[j][1] >> level); y++) {
				for (long long x = xs[i][0] >> level; x <= (xs[i][1] >> level); x++) {
					size_t k = size_t(y) * l.w + size_t(x);
					lo = std::min(lo, double(l.lo[k]));
					hi = std::max(hi, double(l.hi[k]));
				}
			}
		}
	}
	r_lo = lo;
	r_hi = hi;
}

} // namespace gads
