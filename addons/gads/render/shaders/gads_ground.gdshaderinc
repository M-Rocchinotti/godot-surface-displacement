// The ground under a GADSDisplacementField3D, shared by the field and GADSPebbleScatter3D.
//
// ground_mode 0: a flat plane at height ground_rect.w, field layer 0 everywhere.
// ground_mode 1: an GADSGroundBake. ground_data holds one texel per bake cell (RGBA16F, fetched):
//   R, G  height as 16-bit fixed point over [ground_decode.x, ground_decode.x + ground_decode.y]:
//         high byte / 255 and low byte / 255 (exact in half floats)
//   B     layer code (i + 1) / 8 for field layer i, 0 = ground that is none of the layers
//   A     1 where a ground mesh covered the texel, 0 = no ground
// Texel (i, j) is centred on origin + (i + 0.5, j + 0.5) * texel size. A texel is displaceable
// when it and its four neighbours are covered and no neighbour's height differs from its own by
// more than ground_decode.z: a kerb or a step is not a height field, and the field dives under the
// ground there (and draws nothing over it, see gads_ground_cell()). Heights, normals and layer
// weights are bilinear between texel centres. Outside the bake nothing is displaceable and the
// height continues the bake's edge.
//
// GADSGroundBake.sample() and cell() repeat this on the CPU (tests compare the two).

uniform int ground_mode = 0;
uniform sampler2D ground_data : filter_nearest, repeat_disable;
uniform vec4 ground_rect = vec4(0.0, 0.0, 0.1, 0.0);   // origin x, origin z, texel size (m), flat height (m)
uniform vec4 ground_decode = vec4(0.0, 1.0, 0.04, 0.0); // height min (m), height range (m), step limit (m), -

struct GADSGround {
	float height;  // m
	vec3 normal;   // world, from the height's gradient
	vec4 weights;  // per field layer, 0-1; their sum falls below 1 where the ground is not displaceable
};

GADSGround gads_ground(vec2 xz) {
	GADSGround g;
	if (ground_mode == 0) {
		g.height = ground_rect.w;
		g.normal = vec3(0.0, 1.0, 0.0);
		g.weights = vec4(1.0, 0.0, 0.0, 0.0);
		return g;
	}
	ivec2 size = textureSize(ground_data, 0);
	vec2 t = (xz - ground_rect.xy) / ground_rect.z - 0.5;
	ivec2 i0 = ivec2(floor(t));
	vec2 f = t - vec2(i0);
	// The 4 x 4 texels around the bilinear footprint; texel k is i0 + (k % 4 - 1, k / 4 - 1), so
	// the footprint is k = 5, 6, 9, 10 and the neighbours of k are k - 1, k + 1, k - 4, k + 4.
	float h[16];
	bool covered[16];
	int code[16];
	float covered_sum = 0.0;
	float covered_count = 0.0;
	for (int k = 0; k < 16; k++) {
		ivec2 p = i0 + ivec2(k % 4 - 1, k / 4 - 1);
		ivec2 pc = clamp(p, ivec2(0), size - 1);
		vec4 d = texelFetch(ground_data, pc, 0);
		h[k] = ground_decode.x + (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / 65535.0 * ground_decode.y;
		covered[k] = p == pc && d.a > 0.5;
		code[k] = int(round(d.b * 8.0));
		if (covered[k]) {
			covered_sum += h[k];
			covered_count += 1.0;
		}
	}
	// Texels without ground take the mean height of the covered ones around them, so heights and
	// normals stay sane at the ground's edges (they are not displaceable anyway). With no ground in
	// the block at all, the (clamped) fetches stand: beyond the bake its edge continues outwards.
	if (covered_count > 0.0) {
		float fill = covered_sum / covered_count;
		for (int k = 0; k < 16; k++) {
			if (!covered[k]) {
				h[k] = fill;
			}
		}
	}
	int footprint[4] = { 5, 6, 9, 10 };
	vec4 w[4];
	vec2 gradient[4];
	float limit = ground_decode.z;
	for (int j = 0; j < 4; j++) {
		int c = footprint[j];
		float hc = h[c];
		bool ok = covered[c]
				&& covered[c - 1] && abs(h[c - 1] - hc) <= limit
				&& covered[c + 1] && abs(h[c + 1] - hc) <= limit
				&& covered[c - 4] && abs(h[c - 4] - hc) <= limit
				&& covered[c + 4] && abs(h[c + 4] - hc) <= limit;
		w[j] = ok ? vec4(equal(ivec4(code[c]), ivec4(1, 2, 3, 4))) : vec4(0.0);
		gradient[j] = vec2(h[c + 1] - h[c - 1], h[c + 4] - h[c - 4]) / (2.0 * ground_rect.z);
	}
	g.height = mix(mix(h[5], h[6], f.x), mix(h[9], h[10], f.x), f.y);
	vec2 slope = mix(mix(gradient[0], gradient[1], f.x), mix(gradient[2], gradient[3], f.x), f.y);
	g.normal = normalize(vec3(-slope.x, 1.0, -slope.y));
	g.weights = mix(mix(w[0], w[1], f.x), mix(w[2], w[3], f.x), f.y);
	return g;
}

// The bake's 2 x 2 texels around xz (the footprint gads_ground() interpolates; ground_mode 1):
// their bilinear height (texels without ground included as stored), whether all four are ground
// (`covered`) and whether two neighbours among them differ by more than the step limit (`step`).
// Where a cell is not covered or steps, no texel of it is displaceable. GADSGroundBake.cell()
// repeats this on the CPU.
struct GADSGroundCell {
	float height;
	bool covered;
	bool step;
};

GADSGroundCell gads_ground_cell(vec2 xz) {
	GADSGroundCell cell;
	ivec2 size = textureSize(ground_data, 0);
	vec2 t = (xz - ground_rect.xy) / ground_rect.z - 0.5;
	ivec2 i0 = ivec2(floor(t));
	vec2 f = t - vec2(i0);
	float h[4];
	cell.covered = true;
	for (int k = 0; k < 4; k++) {
		ivec2 p = i0 + ivec2(k % 2, k / 2);
		ivec2 pc = clamp(p, ivec2(0), size - 1);
		vec4 d = texelFetch(ground_data, pc, 0);
		h[k] = ground_decode.x + (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / 65535.0 * ground_decode.y;
		cell.covered = cell.covered && p == pc && d.a > 0.5;
	}
	float step_limit = ground_decode.z;
	cell.step = abs(h[1] - h[0]) > step_limit || abs(h[3] - h[2]) > step_limit
			|| abs(h[2] - h[0]) > step_limit || abs(h[3] - h[1]) > step_limit;
	cell.height = mix(mix(h[0], h[1], f.x), mix(h[2], h[3], f.x), f.y);
	return cell;
}
