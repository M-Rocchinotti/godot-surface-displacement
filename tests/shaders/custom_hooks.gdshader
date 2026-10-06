// Test fixture: a GADS surface shader with the custom hooks (tests/render_tests.gd).
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#define GADS_MAPPING_UV
#define GADS_POM
#define GADS_CUSTOM_HEIGHT
#define GADS_CUSTOM_SURFACE

// A height hook is defined before the library (its functions call it); it may use its own
// uniforms, not the library's.
uniform float flatten = 0.0;
float gads_custom_height(vec2 uv, float h) {
	return mix(h, 1.0, flatten);
}

#include "res://addons/gads/render/shaders/gads_core.gdshaderinc"

// A surface hook is defined after the core library and before the surface shader: it may use the
// library's uniforms and functions.
uniform vec4 paint : source_color = vec4(1.0, 0.0, 0.0, 1.0);
uniform float paint_amount = 0.0;
void gads_custom_surface(vec2 uv, vec3 world_pos, vec3 world_normal, float height,
		inout vec3 albedo, inout float roughness, inout float metallic, inout float ao) {
	albedo = mix(albedo, paint.rgb, paint_amount);
}

#include "res://addons/gads/render/shaders/gads_surface.gdshaderinc"
