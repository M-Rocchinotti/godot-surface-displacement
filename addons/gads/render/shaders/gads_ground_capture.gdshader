// Top-down capture of the ground for GADSGroundBake: writes the world height as a 16-bit fixed-point
// value split over red and green (exact in the half-float capture target) and the field layer as
// blue ((index + 1) / 8, 0 = ground that is not displaced). Alpha stays 0 where there is no ground.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, ambient_light_disabled, fog_disabled;

uniform float height_min = 0.0;
uniform float height_range = 1.0;
uniform float layer_code = 0.0;

varying float world_y;

void vertex() {
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	float q = clamp((world_y - height_min) / height_range, 0.0, 1.0);
	float v = floor(q * 65535.0 + 0.5);
	float hi = floor(v / 256.0);
	float lo = v - hi * 256.0;
	ALBEDO = vec3(hi / 255.0, lo / 255.0, layer_code);
}
