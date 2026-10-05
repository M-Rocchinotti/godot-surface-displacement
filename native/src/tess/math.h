// Small double-precision vector math for the tessellator (no engine types, so the algorithm can
// be built and tested on its own).
#pragma once

#include <cmath>
#include <cstdint>

namespace gads {

struct V2 {
	double x = 0.0, y = 0.0;
	V2() = default;
	V2(double p_x, double p_y) : x(p_x), y(p_y) {}
	V2 operator+(const V2 &o) const { return V2(x + o.x, y + o.y); }
	V2 operator-(const V2 &o) const { return V2(x - o.x, y - o.y); }
	V2 operator*(double s) const { return V2(x * s, y * s); }
};

struct V3 {
	double x = 0.0, y = 0.0, z = 0.0;
	V3() = default;
	V3(double p_x, double p_y, double p_z) : x(p_x), y(p_y), z(p_z) {}
	V3 operator+(const V3 &o) const { return V3(x + o.x, y + o.y, z + o.z); }
	V3 operator-(const V3 &o) const { return V3(x - o.x, y - o.y, z - o.z); }
	V3 operator*(double s) const { return V3(x * s, y * s, z * s); }
	V3 operator-() const { return V3(-x, -y, -z); }
	V3 &operator+=(const V3 &o) {
		x += o.x;
		y += o.y;
		z += o.z;
		return *this;
	}
	double dot(const V3 &o) const { return x * o.x + y * o.y + z * o.z; }
	V3 cross(const V3 &o) const { return V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x); }
	double length_squared() const { return dot(*this); }
	double length() const { return std::sqrt(length_squared()); }
	V3 normalized(const V3 &fallback = V3(0.0, 1.0, 0.0)) const {
		double l = length();
		return l > 1e-20 ? *this * (1.0 / l) : fallback;
	}
};

// Row-major 3 x 3 matrix and an affine transform (object -> world).
struct M3 {
	double m[3][3] = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
	V3 xform(const V3 &v) const {
		return V3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
				m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
				m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z);
	}
	M3 transposed() const {
		M3 r;
		for (int i = 0; i < 3; i++) {
			for (int j = 0; j < 3; j++) {
				r.m[i][j] = m[j][i];
			}
		}
		return r;
	}
	double determinant() const {
		return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
				m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
	}
	M3 inverse() const {
		double d = determinant();
		double s = std::fabs(d) > 1e-300 ? 1.0 / d : 0.0;
		M3 r;
		r.m[0][0] = (m[1][1] * m[2][2] - m[1][2] * m[2][1]) * s;
		r.m[0][1] = (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * s;
		r.m[0][2] = (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * s;
		r.m[1][0] = (m[1][2] * m[2][0] - m[1][0] * m[2][2]) * s;
		r.m[1][1] = (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * s;
		r.m[1][2] = (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * s;
		r.m[2][0] = (m[1][0] * m[2][1] - m[1][1] * m[2][0]) * s;
		r.m[2][1] = (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * s;
		r.m[2][2] = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * s;
		return r;
	}
};

struct Xform {
	M3 basis;
	V3 origin;
	V3 xform(const V3 &p) const { return basis.xform(p) + origin; }
};

inline uint64_t pair_key(uint32_t a, uint32_t b) {
	return a < b ? (uint64_t(a) << 32) | b : (uint64_t(b) << 32) | a;
}

} // namespace gads
