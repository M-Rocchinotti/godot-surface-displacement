// GADS shared pieces: the quality globals, constants, the Godot-matching direct
// lighting used by the self-shadowing light() functions, and the normal-map helper. Included by
// gads_core.gdshaderinc (surface materials) and gads_field.gdshaderinc (GADSDisplacementField3D).

#ifndef GADS_COMMON_INCLUDED
#define GADS_COMMON_INCLUDED

#define GADS_MAX_STEPS 64
#define GADS_MAX_REFINE 8
#define GADS_MAX_SHADOW_STEPS 32
#define GADS_MIN_NDOTV 0.05
#define GADS_PI 3.14159265358979

// Quality, set by the GADSManager node (Project Settings > Shader Globals; the plugin
// registers them). x/y/z/w meanings are listed in core/gads_globals.gd.
global uniform vec4 gads_pom_steps;   // min steps, max steps, bisection steps, 1 = omni / spot lights self-shadow too
global uniform vec4 gads_pom_range;   // fade start (m), fade end (m), LOD bias, highest LOD that is marched
global uniform vec4 gads_shadow;      // steps, max distance (m), softness (0 = hard), strength
global uniform vec4 gads_debug;       // view (0 = off), scale (m), reference height (m) of the field's world-height view, unused
global uniform sampler2D gads_dfg;    // Godot's multiple-scattering term, see tools/make_dfg_lut.py
global uniform sampler2D gads_deform;        // runtime deformation: r = depth when stamped (m, down), g = stamp time (s)
global uniform vec4 gads_deform_params;      // window origin x, z (m), window side (m), deepest deformation (m; 0 = off)
global uniform vec4 gads_deform_time;        // now (s), recovery (m/s), unused, unused

// Distance fade of the relief (1 near, 0 beyond the fade end).
float gads_fade(float view_distance) {
	return 1.0 - smoothstep(gads_pom_range.x, max(gads_pom_range.y, gads_pom_range.x + 1e-3), view_distance);
}

// One texel of the deformation map, wrapped (the window is addressed toroidally: a world cell
// keeps its texel while the window moves), with its recovery since the stamp applied.
float gads_deform_texel(ivec2 c, int n) {
	vec2 rg = texelFetch(gads_deform, ivec2(((c.x % n) + n) % n, ((c.y % n) + n) % n), 0).rg;
	float recovered = max(abs(rg.r) - gads_deform_time.y * max(gads_deform_time.x - rg.g, 0.0), 0.0);
	return sign(rg.r) * recovered;
}

// How far the ground is pressed down (m, negative = raised) at world xz by GADSDeformationField:
// bilinear between texel centres, 0 outside the window or without a field.
float gads_deformation(vec2 xz) {
	if (gads_deform_params.w <= 0.0) {
		return 0.0;
	}
	vec2 rel = xz - gads_deform_params.xy;
	if (rel.x < 0.0 || rel.y < 0.0 || rel.x >= gads_deform_params.z || rel.y >= gads_deform_params.z) {
		return 0.0;
	}
	int n = textureSize(gads_deform, 0).x;
	vec2 f = xz / gads_deform_params.z * float(n) - 0.5;
	vec2 cell = floor(f);
	vec2 t = f - cell;
	ivec2 c = ivec2(cell);
	float a = gads_deform_texel(c, n);
	float b = gads_deform_texel(c + ivec2(1, 0), n);
	float d = gads_deform_texel(c + ivec2(0, 1), n);
	float e = gads_deform_texel(c + ivec2(1, 1), n);
	return mix(mix(a, b, t.x), mix(d, e, t.x), t.y);
}

// Height map value h remapped so remap.x -> 0 and remap.y -> 1, clamped; remap.x > remap.y inverts
// the map.
float gads_remap_height(float h, vec2 remap) {
	float span = remap.y - remap.x;
	span = abs(span) < 1e-5 ? 1e-5 : span;
	return clamp((h - remap.x) / span, 0.0, 1.0);
}

// Unpacks an OpenGL-convention normal map sample exactly like BaseMaterial3D (z rebuilt from xy,
// which also makes two-channel BC5 imports work) and bends normal n towards it by `strength`.
// t and image_up: the directions in which u grows and v shrinks (the image's right and up).
vec3 gads_apply_normal_map(vec3 sample_rgb, vec3 t, vec3 image_up, vec3 n, float strength) {
	vec2 xy = sample_rgb.xy * 2.0 - 1.0;
	float z = sqrt(max(0.0, 1.0 - dot(xy, xy)));
	// Tangent frame on the surface (Gram-Schmidt against the geometric normal). A planar mapping
	// seen edge-on (a world-planar texture on a vertical face) has no frame on the surface: any
	// tangent will do there, the texture is a smear anyway, but it must not become NaN.
	vec3 tt = t - n * dot(n, t);
	if (dot(tt, tt) < 1e-12) {
		tt = abs(n.y) < 0.999 ? cross(vec3(0.0, 1.0, 0.0), n) : vec3(1.0, 0.0, 0.0);
	}
	tt = normalize(tt);
	vec3 bb = image_up - n * dot(n, image_up) - tt * dot(tt, image_up);
	bb = dot(bb, bb) < 1e-12 ? cross(n, tt) : normalize(bb);
	return normalize(mix(n, tt * xy.x + bb * xy.y + n * z, strength));
}

// ---------------------------------------------------------------------------------------------
// Godot-matching direct lighting for light(). Mirrors light_compute() in Godot 4.7.2
// (servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl) for the default
// diffuse_burley + specular_schlick_ggx modes, including the multiple-scattering energy
// compensation that the engine derives from its DFG texture (gads_dfg holds the same values).
// Not available to light() and therefore not reproduced: the soft-light size term A that
// shifts N.L by at most a few thousandths for lights with a size or angular diameter.
// Area lights never reach light(): the engine shades them with its own code as long as a
// shader does not read LIGHT_IS_AREA or the area multipliers, and this one does not.

float gads_schlick_fresnel(float u) {
	float m = 1.0 - u;
	float m2 = m * m;
	return m2 * m2 * m;
}

// The engine wraps D and V in saturateHalf(), which is not a [0, 1] clamp: it only caps at the
// largest half float on FP16 builds and does nothing on FP32 ones (half_inc.glsl).
float gads_d_ggx(float n_dot_h, float roughness) {
	float a = n_dot_h * roughness;
	float k = roughness / (1.0 - n_dot_h * n_dot_h + a * a);
	return k * k * (1.0 / GADS_PI);
}

float gads_v_ggx(float n_dot_l, float n_dot_v, float alpha) {
	return 0.5 / mix(2.0 * n_dot_l * n_dot_v, n_dot_l + n_dot_v, alpha);
}

// Bilinear lookup of E(n.v, roughness) with clamp-to-edge, as the engine's sampler does.
float gads_dfg_e(float n_dot_v, float roughness) {
	vec2 size = vec2(textureSize(gads_dfg, 0));
	vec2 t = clamp(vec2(n_dot_v, roughness) * size - 0.5, vec2(0.0), size - 1.0);
	ivec2 i0 = ivec2(floor(t));
	ivec2 i1 = min(i0 + 1, ivec2(size) - 1);
	vec2 f = t - vec2(i0);
	float a = texelFetch(gads_dfg, i0, 0).r;
	float b = texelFetch(gads_dfg, ivec2(i1.x, i0.y), 0).r;
	float c = texelFetch(gads_dfg, ivec2(i0.x, i1.y), 0).r;
	float d = texelFetch(gads_dfg, i1, 0).r;
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void gads_brdf(vec3 n, vec3 l, vec3 v, vec3 light_color, float attenuation, bool is_directional,
		vec3 albedo, float roughness, float metallic, float specular, float specular_amount,
		inout vec3 diffuse_light, inout vec3 specular_light) {
	float n_dot_l = min(dot(n, l), 1.0);
	float c_n_dot_v = max(dot(n, v), 1e-4);
	// HALF_FLT_MIN of the engine's FP32 path (on FP16 builds it is 6.1e-5; the difference is
	// invisible).
	if (!(is_directional || attenuation > 1.175494351e-38)) {
		return;
	}
	float c_n_dot_l = max(n_dot_l, 0.0);
	vec3 h = normalize(v + l);
	float c_l_dot_h = clamp(dot(l, h), 0.0, 1.0);
	if (metallic < 1.0) {
		float fd90_minus_1 = 2.0 * c_l_dot_h * c_l_dot_h * roughness - 0.5;
		float fd_v = 1.0 + fd90_minus_1 * gads_schlick_fresnel(c_n_dot_v);
		float fd_l = 1.0 + fd90_minus_1 * gads_schlick_fresnel(c_n_dot_l);
		float diffuse_brdf_nl = (1.0 / GADS_PI) * fd_v * fd_l * c_n_dot_l;
		diffuse_light += light_color * diffuse_brdf_nl * attenuation;
	}
	if (roughness > 0.0) {
		float c_n_dot_h = clamp(dot(n, h), 0.0, 1.0);
		float alpha_ggx = roughness * roughness;
		float d = gads_d_ggx(c_n_dot_h, alpha_ggx);
		float g = gads_v_ggx(c_n_dot_l, c_n_dot_v, alpha_ggx);
		float c_l_dot_h5 = gads_schlick_fresnel(c_l_dot_h);
		vec3 f0 = mix(vec3(0.16 * specular * specular), albedo, vec3(metallic));
		float f90 = clamp(dot(f0, vec3(50.0 * 0.33)), metallic, 1.0);
		vec3 fresnel = f0 + (f90 - f0) * c_l_dot_h5;
		float e = gads_dfg_e(clamp(dot(n, v), 0.0001, 1.0), roughness);
		vec3 energy_compensation = 1.0 + f0 * (1.0 / max(e, 1e-4) - 1.0);
		vec3 specular_brdf_nl = energy_compensation * c_n_dot_l * d * fresnel * g;
		specular_light += specular_brdf_nl * light_color * attenuation * specular_amount;
	}
}

#endif // GADS_COMMON_INCLUDED
