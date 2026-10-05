// A height map as the shaders sample it (repeat wrap, bilinear between texel centres), plus two
// pyramids: the average (trilinear sampling at a footprint, like hardware mipmaps) and the
// minimum / maximum (a conservative bound of the heights under any rectangle of texels).
#pragma once

#include "math.h"

#include <vector>

namespace gads {

class HeightMap {
public:
	struct Level {
		int w = 0, h = 0;
		std::vector<float> avg, lo, hi;
	};

	// Raw values (red channel), row-major, mip 0.
	HeightMap(int p_width, int p_height, std::vector<float> p_data);

	int width() const { return levels_[0].w; }
	int height() const { return levels_[0].h; }
	int level_count() const { return int(levels_.size()); }

	// Bilinear sample with repeat wrap at uv (1 = one texture repeat) on mip level `level`.
	double sample(V2 uv, int level = 0) const;
	// Trilinear sample at a fractional level (clamped to the pyramid).
	double sample_lod(V2 uv, double lod) const;
	// Lowest and highest raw value any bilinear sample inside the uv rectangle can return.
	void range(V2 uv_min, V2 uv_max, double &r_lo, double &r_hi) const;

private:
	std::vector<Level> levels_;
	static int wrap(int i, int n) {
		int r = i % n;
		return r < 0 ? r + n : r;
	}
};

} // namespace gads
