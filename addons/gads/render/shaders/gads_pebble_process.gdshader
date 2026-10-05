// GADSPebbleScatter3D placement: every particle is a pebble slot. A window of cells follows the camera;
// slot `INDEX` belongs to window cell INDEX / per_cell and takes its position, size and rotation
// from a hash of the cell's WORLD coordinates and the slot, so a pebble stays where it is while
// the window moves and cells that leave on one side come back on the other with their own
// pebbles. Density comes from the ground's layer weights (per-layer density, normalised and
// faded like the field's) and prefers the height map's valleys, where loose stones settle.
// Nothing is read back to the CPU.
shader_type particles;
render_mode disable_velocity, disable_force;

#define GADS_FIELD_LAYERS 4

#include "res://addons/gads/render/shaders/gads_common.gdshaderinc"
// Ground (ground_mode, ground_data, ground_rect, ground_decode), copied from the parent field.
#include "res://addons/gads/render/shaders/gads_ground.gdshaderinc"

uniform vec3 camera_position;
uniform vec2 window_cell;          // world cell index of the window's first cell
uniform int window_cells = 21;     // cells per side
uniform int per_cell = 16;
uniform float cell_size = 1.0;
uniform float radius = 10.0;
uniform float density = 1.0;
uniform vec2 size_range = vec2(0.012, 0.035);
uniform float valley_bias = 2.0;
uniform float lift = 0.002;
uniform float base_spacing = 0.02;
// Layers, copied from the parent GADSDisplacementField3D.
uniform int layer_count = 1;
uniform sampler2D layer_height[GADS_FIELD_LAYERS] : filter_linear_mipmap, repeat_enable;
uniform vec4 layer_a[GADS_FIELD_LAYERS];
uniform vec4 layer_b[GADS_FIELD_LAYERS];
uniform vec4 layer_c[GADS_FIELD_LAYERS];
uniform vec4 layer_e[GADS_FIELD_LAYERS];
uniform vec4 layer_density = vec4(1.0, 0.0, 0.0, 0.0);

uint gads_hash(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

float gads_rand(inout uint state) {
	state = gads_hash(state + 0x9e3779b9u);
	return float(state >> 8u) / 16777216.0;
}

vec2 gads_layer_uv(int i, vec2 xz) {
	vec2 q = xz - layer_b[i].zw;
	vec2 cs = layer_c[i].xy;
	return vec2(cs.x * q.x - cs.y * q.y, cs.y * q.x + cs.x * q.y) * layer_b[i].xy;
}

void process() {
	int slot = int(INDEX) % per_cell;
	int cell = int(INDEX) / per_cell;
	ivec2 cell_xy = ivec2(cell % window_cells, cell / window_cells);
	ivec2 world_cell = ivec2(window_cell) + cell_xy;
	uint state = gads_hash(uint(world_cell.x) * 73856093u ^ uint(world_cell.y) * 19349663u ^ uint(slot) * 83492791u);
	vec2 xz = (vec2(world_cell) + vec2(gads_rand(state), gads_rand(state))) * cell_size;
	float accept = gads_rand(state);
	GADSGround g = gads_ground(xz);
	// The field's weights (gads_field_weights): only its layers, normalised, faded where the ground
	// is only partly displaceable.
	vec4 w = g.weights * vec4(lessThan(ivec4(0, 1, 2, 3), ivec4(layer_count)));
	float w_sum = w.x + w.y + w.z + w.w;
	float displaceable = smoothstep(0.35, 0.65, w_sum);
	w = w_sum > 1e-4 ? w / w_sum : vec4(0.0);
	float wanted = 0.0;
	float relief = 0.0;
	float relief_proxy = 0.0;
	int layer = 0;
	float best = -1.0;
	float h_main = 0.0;
	for (int i = 0; i < GADS_FIELD_LAYERS; i++) {
		if (i >= layer_count || w[i] <= 0.001) {
			continue;
		}
		vec2 uv = gads_layer_uv(i, xz);
		float h = textureLod(layer_height[i], uv, 0.0).r;
		h = gads_remap_height(h, layer_a[i].yz);
		// The field's innermost geometry samples one texel per vertex; pebbles must not sink
		// below it (its depth hides them even where the parallax shows a deeper gap).
		float hp = textureLod(layer_height[i], uv, max(log2(base_spacing) + layer_e[i].w, 0.0)).r;
		hp = gads_remap_height(hp, layer_a[i].yz);
		relief += w[i] * layer_a[i].x * h;
		relief_proxy += w[i] * layer_a[i].x * hp;
		wanted += w[i] * layer_density[i];
		if (w[i] > best) {
			best = w[i];
			layer = i;
			h_main = h;
		}
	}
	// Valleys (low h) collect loose stones: acceptance falls with height (max(): pow(0, 0) is
	// undefined in GLSL, and valley_bias may be 0).
	wanted *= density * displaceable * pow(max(1.0 - h_main, 1e-4), valley_bias);
	float d = distance(xz, camera_position.xz);
	// Pebbles shrink away between half the radius and the radius: beyond a few metres a 3 cm stone
	// is a few pixels and reads as noise.
	float fade = 1.0 - smoothstep(0.5 * radius, radius, d);
	float size = mix(size_range.x, size_range.y, gads_rand(state)) * fade;
	// Rejected slots stay alive with a zero transform (nothing is rasterized): a particle that is
	// deactivated is not processed again until it is re-emitted, so it could not come back when
	// the window moves on.
	ACTIVE = true;
	if (accept >= wanted || size < 1e-4) {
		TRANSFORM = mat4(vec4(0.0), vec4(0.0), vec4(0.0), vec4(xz.x, -1e4, xz.y, 1.0));
	} else {
		float yaw = gads_rand(state) * 6.2831853;
		float tilt = (gads_rand(state) - 0.5) * 0.6;
		vec3 s = size * vec3(1.0 + 0.4 * gads_rand(state), 0.45 + 0.2 * gads_rand(state), 0.8 + 0.3 * gads_rand(state));
		mat3 r_yaw = mat3(vec3(cos(yaw), 0.0, -sin(yaw)), vec3(0.0, 1.0, 0.0), vec3(sin(yaw), 0.0, cos(yaw)));
		mat3 r_tilt = mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, cos(tilt), sin(tilt)), vec3(0.0, -sin(tilt), cos(tilt)));
		mat3 basis = r_yaw * r_tilt * mat3(vec3(s.x, 0.0, 0.0), vec3(0.0, s.y, 0.0), vec3(0.0, 0.0, s.z));
		// Resting on the relief (or the field's coarser surface where that is higher), sunk in to
		// about 40 % of its height: a pebble standing on top of the gravel shows mostly its side,
		// which reads as a dark speck against the lit stone tops when the sun is behind it.
		float y = g.height + lift + max(relief, relief_proxy) + s.y * 0.1;
		TRANSFORM = mat4(vec4(basis[0], 0.0), vec4(basis[1], 0.0), vec4(basis[2], 0.0), vec4(xz.x, y, xz.y, 1.0));
		COLOR = vec4(vec3(0.8 + 0.35 * gads_rand(state)), 1.0);
		CUSTOM = vec4(float(layer), gads_rand(state), 0.0, 0.0);
	}
	VELOCITY = vec3(0.0);
}
