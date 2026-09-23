// Surface Displacement core: parallax occlusion mapping with adaptive steps, bisection refinement,
// mip-correct sampling, distance fade, LIGHT_VERTEX, optional self-shadowing in a Godot-matching
// light() and an opt-in depth write. Used by the generated variants in shaders/variants/ and by
// your own shaders.
//
// Before including, define exactly one mapping:
//     SD_MAPPING_UV          mesh UVs (walls, props; needs tangents)
//     SD_MAPPING_WORLD       world-planar XZ with rotation and offset (ground; no UVs needed)
//     SD_MAPPING_TRIPLANAR   world triplanar (anything; only planes with weight > 0.05 are marched)
// and optionally:
//     SD_POM                 parallax occlusion mapping (without it: plain normal mapping)
//     SD_SELF_SHADOW         self-shadowing from directional lights (requires SD_POM; adds light())
//     SD_DEPTH_WRITE         writes DEPTH at the relief (requires SD_POM; expensive, see README)
//
// Conventions (see docs/ARCHITECTURE.md):
//   - Height texture: red channel, 1 = top. It is remapped with height_remap (x -> 0, y -> 1).
//   - Relief in metres: z = height_m * (h - height_center), measured along the relief axis
//     (the surface normal for UV mapping, world +Y for world-planar, the projection axis for
//     triplanar). height_center = 1: relief below the surface (classic POM, good on walls);
//     height_center = 0: relief above it (required for ground under a DisplacementField3D).
//   - A view ray that leaves the camera and hits the flat surface at P passes relief height z at
//     uv(z) = uv(P) + duv_dz * z, duv_dz = (gu.V, gv.V) * (N.A) / (N.V), where gu/gv are the
//     gradients of u/v along the surface, N the surface normal, A the relief axis and V the unit
//     vector towards the camera. The march walks z from the top of the relief slab downwards.

#ifndef SD_CORE_INCLUDED
#define SD_CORE_INCLUDED

#define SD_MAX_STEPS 64
#define SD_MAX_REFINE 8
#define SD_MAX_SHADOW_STEPS 32
#define SD_MIN_NDOTV 0.05
#define SD_PI 3.14159265358979

// Quality, set by the SurfaceDisplacement node (Project Settings > Shader Globals; the plugin
// registers them). x/y/z/w meanings are listed in core/sd_globals.gd.
global uniform vec4 sd_pom_steps;   // min steps, max steps, bisection steps, unused
global uniform vec4 sd_pom_range;   // fade start (m), fade end (m), LOD bias, highest LOD that is marched
global uniform vec4 sd_shadow;      // steps, max distance (m), softness (0 = hard), strength
global uniform vec4 sd_debug;       // view (0 = off), offset scale (m), unused, unused
global uniform sampler2D sd_dfg;    // Godot's multiple-scattering term, see tools/make_dfg_lut.py

group_uniforms albedo;
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
group_uniforms normal;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_strength : hint_range(0.0, 4.0) = 1.0;
group_uniforms orm;
// Poly Haven "arm" / Godot ORM packing: R = ambient occlusion, G = roughness, B = metallic.
uniform sampler2D orm_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_scale : hint_range(0.0, 2.0) = 1.0;
uniform float metallic_scale : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
group_uniforms height;
uniform sampler2D height_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float height_m : hint_range(0.0, 0.5, 0.0005) = 0.03;
uniform float height_center : hint_range(0.0, 1.0) = 1.0;
uniform vec2 height_remap = vec2(0.0, 1.0);
uniform float pom_steps_scale : hint_range(0.25, 4.0) = 1.0;
uniform float self_shadow_strength : hint_range(0.0, 1.0) = 1.0;
group_uniforms mapping;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform vec2 texture_size_m = vec2(2.0);
uniform float planar_rotation_deg = 0.0;
uniform vec2 planar_offset_m = vec2(0.0);
uniform float triplanar_sharpness : hint_range(1.0, 16.0) = 4.0;
group_uniforms;

varying vec3 sd_world_pos;
varying vec3 sd_world_normal;

#ifdef SD_SELF_SHADOW
// Handed from fragment() to light(), view space.
varying vec2 sd_ss_uv;
varying float sd_ss_z;
varying vec3 sd_ss_gu;
varying vec3 sd_ss_gv;
varying vec3 sd_ss_n;
varying vec3 sd_ss_axis;
varying vec4 sd_ss_params; // lod, amplitude, height_center, strength (0 = off)
#endif

// One projection of the relief: a 2D texture parameterisation plus the frame the march needs.
struct SDPlane {
	vec2 uv;      // uv at the rasterized point (relief height z = 0)
	vec2 ddx;     // screen-space uv derivatives (sampling after the march)
	vec2 ddy;
	vec3 gu;      // gradient of u along the surface (1/m), frame space
	vec3 gv;      // gradient of v along the surface (1/m)
	vec3 axis;    // relief axis (unit, outward)
	float weight;
};

float sd_remap(float h) {
	return clamp((h - height_remap.x) / max(height_remap.y - height_remap.x, 1e-5), 0.0, 1.0);
}

// Relief height (m) at uv for amplitude amp, on an explicit mip level.
float sd_relief(vec2 uv, float lod, float amp) {
	return amp * (sd_remap(textureLod(height_texture, uv, lod).r) - height_center);
}

// The mip level the march samples: the level the hardware would pick for the rasterized uv
// (isotropic, from derivatives taken before any divergent control flow), plus a bias.
float sd_march_lod(SDPlane p) {
	vec2 size = vec2(textureSize(height_texture, 0));
	vec2 dx = p.ddx * size;
	vec2 dy = p.ddy * size;
	float rho2 = max(dot(dx, dx), dot(dy, dy));
	return max(0.5 * log2(max(rho2, 1e-12)) + sd_pom_range.z, 0.0);
}

// uv change per metre of relief height along the view ray (see the header comment).
vec2 sd_duv_dz(SDPlane p, vec3 n, vec3 v) {
	float nv = max(dot(n, v), SD_MIN_NDOTV);
	return vec2(dot(p.gu, v), dot(p.gv, v)) * (dot(n, p.axis) / nv);
}

// Walks the view ray from z_top down to z_bot in `steps` equal steps, brackets the first crossing
// below the relief, refines the bracket by `refine` bisection steps and places the hit by a final
// secant (linear interpolation of the ray-minus-relief function). Returns the hit height z and
// writes its uv. When the ray reaches z_bot without crossing (only possible for z_bot above the
// lowest relief) it returns z_bot.
float sd_march(vec2 uv0, vec2 duv_dz, float z_top, float z_bot, float amp, float lod, int steps, int refine,
		out vec2 uv_hit, inout float steps_used) {
	float dz = (z_top - z_bot) / float(steps);
	float z_above = z_top;
	float f_above = z_top - sd_relief(uv0 + duv_dz * z_top, lod, amp);
	float z_below = z_bot;
	float f_below = 0.0;
	bool hit = f_above <= 0.0;
	if (hit) {
		z_below = z_top;
		f_below = f_above;
	}
	for (int i = 1; i <= SD_MAX_STEPS; i++) {
		if (hit || i > steps) {
			break;
		}
		float z = z_top - dz * float(i);
		float f = z - sd_relief(uv0 + duv_dz * z, lod, amp);
		steps_used += 1.0;
		if (f <= 0.0) {
			hit = true;
			z_below = z;
			f_below = f;
		} else {
			z_above = z;
			f_above = f;
		}
	}
	if (!hit) {
		uv_hit = uv0 + duv_dz * z_bot;
		return z_bot;
	}
	for (int j = 0; j < SD_MAX_REFINE; j++) {
		if (j >= refine) {
			break;
		}
		float zm = 0.5 * (z_above + z_below);
		float fm = zm - sd_relief(uv0 + duv_dz * zm, lod, amp);
		steps_used += 1.0;
		if (fm <= 0.0) {
			z_below = zm;
			f_below = fm;
		} else {
			z_above = zm;
			f_above = fm;
		}
	}
	float denom = f_above - f_below;
	float z_hit = denom > 1e-9 ? z_above - f_above * (z_above - z_below) / denom : z_below;
	uv_hit = uv0 + duv_dz * z_hit;
	return z_hit;
}

// Distance fade of the relief (1 near, 0 beyond the fade end).
float sd_fade(float view_distance) {
	return 1.0 - smoothstep(sd_pom_range.x, max(sd_pom_range.y, sd_pom_range.x + 1e-3), view_distance);
}

// Number of linear steps: more at grazing angles, scaled by the fade and the material.
int sd_step_count(float n_dot_v, float fade) {
	float n = mix(sd_pom_steps.y, sd_pom_steps.x, clamp(n_dot_v, 0.0, 1.0)) * pom_steps_scale * fade;
	return clamp(int(ceil(n)), 1, SD_MAX_STEPS);
}

// Unpacks an OpenGL-convention normal map sample exactly like BaseMaterial3D (z rebuilt from xy,
// which also makes two-channel BC5 imports work) and bends normal n towards it.
vec3 sd_apply_normal_map(vec3 sample_rgb, vec3 t, vec3 image_up, vec3 n) {
	vec2 xy = sample_rgb.xy * 2.0 - 1.0;
	float z = sqrt(max(0.0, 1.0 - dot(xy, xy)));
	// Tangent frame on the surface (Gram-Schmidt against the geometric normal).
	vec3 tt = normalize(t - n * dot(n, t));
	vec3 bb = normalize(image_up - n * dot(n, image_up) - tt * dot(tt, image_up));
	return normalize(mix(n, tt * xy.x + bb * xy.y + n * z, normal_strength));
}

#ifdef SD_MAPPING_WORLD
// World-planar XZ projection, rotated by planar_rotation_deg around +Y and shifted by
// planar_offset_m, one texture tile per texture_size_m. Frame space = world.
SDPlane sd_world_plane(vec3 wpos) {
	float a = radians(planar_rotation_deg);
	float c = cos(a);
	float s = sin(a);
	SDPlane p;
	p.gu = vec3(c, 0.0, -s) / texture_size_m.x;
	p.gv = vec3(s, 0.0, c) / texture_size_m.y;
	vec3 q = wpos - vec3(planar_offset_m.x, 0.0, planar_offset_m.y);
	p.uv = vec2(dot(p.gu, q), dot(p.gv, q));
	p.ddx = vec2(0.0); // Set by the caller from the position's derivatives.
	p.ddy = vec2(0.0);
	p.axis = vec3(0.0, 1.0, 0.0);
	p.weight = 1.0;
	return p;
}
#endif

#ifdef SD_MAPPING_TRIPLANAR
// Plane `axis_index` (0 = X, 1 = Y, 2 = Z) of a world triplanar projection facing along the sign of
// the normal's component. Orientation: the image's right and up directions form a right-handed
// frame with the outward axis on every face, so normal maps read correctly on all six sides.
SDPlane sd_triplanar_plane(vec3 wpos, vec3 n, int axis_index, float weight) {
	SDPlane p;
	vec3 right;
	vec3 image_up;
	if (axis_index == 0) {
		float sg = n.x >= 0.0 ? 1.0 : -1.0;
		p.axis = vec3(sg, 0.0, 0.0);
		right = vec3(0.0, 0.0, -sg);
		image_up = vec3(0.0, 1.0, 0.0);
	} else if (axis_index == 1) {
		float sg = n.y >= 0.0 ? 1.0 : -1.0;
		p.axis = vec3(0.0, sg, 0.0);
		right = vec3(1.0, 0.0, 0.0);
		image_up = vec3(0.0, 0.0, -sg);
	} else {
		float sg = n.z >= 0.0 ? 1.0 : -1.0;
		p.axis = vec3(0.0, 0.0, sg);
		right = vec3(sg, 0.0, 0.0);
		image_up = vec3(0.0, 1.0, 0.0);
	}
	// v grows downwards in the image, so its gradient is -image_up.
	p.gu = right / texture_size_m.x;
	p.gv = -image_up / texture_size_m.y;
	vec3 q = wpos - vec3(planar_offset_m.x, 0.0, planar_offset_m.y);
	p.uv = vec2(dot(p.gu, q), dot(p.gv, q));
	p.ddx = vec2(0.0); // Set by the caller from the position's derivatives.
	p.ddy = vec2(0.0);
	p.weight = weight;
	return p;
}

// Blend weights: |n|^sharpness, planes below 0.05 dropped, renormalised.
vec3 sd_triplanar_weights(vec3 n) {
	vec3 w = pow(abs(n), vec3(triplanar_sharpness));
	w /= max(w.x + w.y + w.z, 1e-6);
	w = mix(w, vec3(0.0), lessThan(w, vec3(0.05)));
	return w / max(w.x + w.y + w.z, 1e-6);
}
#endif

// ---------------------------------------------------------------------------------------------
// Godot-matching direct lighting for light(). Mirrors light_compute() in Godot 4.7.2
// (servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl) for the default
// diffuse_burley + specular_schlick_ggx modes, including the multiple-scattering energy
// compensation that the engine derives from its DFG texture (sd_dfg holds the same values).
// Not available to light() and therefore not reproduced: the soft-light size term A that
// shifts N.L by at most a few thousandths for lights with a size or angular diameter.
// Area lights never reach light(): the engine shades them with its own code as long as a
// shader does not read LIGHT_IS_AREA or the area multipliers, and this one does not.

float sd_schlick_fresnel(float u) {
	float m = 1.0 - u;
	float m2 = m * m;
	return m2 * m2 * m;
}

float sd_d_ggx(float n_dot_h, float roughness) {
	float a = n_dot_h * roughness;
	float k = roughness / (1.0 - n_dot_h * n_dot_h + a * a);
	return clamp(k * k * (1.0 / SD_PI), 0.0, 1.0);
}

float sd_v_ggx(float n_dot_l, float n_dot_v, float alpha) {
	float v = 0.5 / mix(2.0 * n_dot_l * n_dot_v, n_dot_l + n_dot_v, alpha);
	return clamp(v, 0.0, 1.0);
}

// Bilinear lookup of E(n.v, roughness) with clamp-to-edge, as the engine's sampler does.
float sd_dfg_e(float n_dot_v, float roughness) {
	vec2 size = vec2(textureSize(sd_dfg, 0));
	vec2 t = clamp(vec2(n_dot_v, roughness) * size - 0.5, vec2(0.0), size - 1.0);
	ivec2 i0 = ivec2(floor(t));
	ivec2 i1 = min(i0 + 1, ivec2(size) - 1);
	vec2 f = t - vec2(i0);
	float a = texelFetch(sd_dfg, i0, 0).r;
	float b = texelFetch(sd_dfg, ivec2(i1.x, i0.y), 0).r;
	float c = texelFetch(sd_dfg, ivec2(i0.x, i1.y), 0).r;
	float d = texelFetch(sd_dfg, i1, 0).r;
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void sd_brdf(vec3 n, vec3 l, vec3 v, vec3 light_color, float attenuation, bool is_directional,
		vec3 albedo, float roughness, float metallic, float specular_amount,
		inout vec3 diffuse_light, inout vec3 specular_light) {
	float n_dot_l = min(dot(n, l), 1.0);
	float c_n_dot_v = max(dot(n, v), 1e-4);
	if (!(is_directional || attenuation > 6.10352e-5)) {
		return;
	}
	float c_n_dot_l = max(n_dot_l, 0.0);
	vec3 h = normalize(v + l);
	float c_l_dot_h = clamp(dot(l, h), 0.0, 1.0);
	if (metallic < 1.0) {
		float fd90_minus_1 = 2.0 * c_l_dot_h * c_l_dot_h * roughness - 0.5;
		float fd_v = 1.0 + fd90_minus_1 * sd_schlick_fresnel(c_n_dot_v);
		float fd_l = 1.0 + fd90_minus_1 * sd_schlick_fresnel(c_n_dot_l);
		float diffuse_brdf_nl = (1.0 / SD_PI) * fd_v * fd_l * c_n_dot_l;
		diffuse_light += light_color * diffuse_brdf_nl * attenuation;
	}
	if (roughness > 0.0) {
		float c_n_dot_h = clamp(dot(n, h), 0.0, 1.0);
		float alpha_ggx = roughness * roughness;
		float d = sd_d_ggx(c_n_dot_h, alpha_ggx);
		float g = sd_v_ggx(c_n_dot_l, c_n_dot_v, alpha_ggx);
		float c_l_dot_h5 = sd_schlick_fresnel(c_l_dot_h);
		vec3 f0 = mix(vec3(0.16 * specular * specular), albedo, vec3(metallic));
		float f90 = clamp(dot(f0, vec3(50.0 * 0.33)), metallic, 1.0);
		vec3 fresnel = f0 + (f90 - f0) * c_l_dot_h5;
		float e = sd_dfg_e(clamp(dot(n, v), 0.0001, 1.0), roughness);
		vec3 energy_compensation = 1.0 + f0 * (1.0 / max(e, 1e-4) - 1.0);
		vec3 specular_brdf_nl = energy_compensation * c_n_dot_l * d * fresnel * g;
		specular_light += specular_brdf_nl * light_color * attenuation * specular_amount;
	}
}

#ifdef SD_SELF_SHADOW
// Height-field shadow towards directional light l (view space) from the hit found in fragment().
// Hard (softness 0): 0 behind any relief above the light ray. Contact-hardening (softness k > 0,
// after Tatarchuk 2006): the largest (relief - ray) * k / distance over the samples, so occluders
// close to the receiver cast sharp shadows and distant ones soft shadows.
float sd_self_shadow(vec3 l) {
	float strength = sd_ss_params.w;
	float amp = sd_ss_params.y;
	if (strength <= 0.0 || amp <= 0.0) {
		return 1.0;
	}
	float n_dot_l = dot(sd_ss_n, l);
	if (n_dot_l <= 0.0) {
		return 1.0; // Unlit side: the BRDF already returns zero.
	}
	float na = dot(sd_ss_n, sd_ss_axis);
	vec2 duv_dz = vec2(dot(sd_ss_gu, l), dot(sd_ss_gv, l)) * (na / max(n_dot_l, SD_MIN_NDOTV));
	float center = sd_ss_params.z;
	float z_top = (1.0 - center) * amp;
	if (sd_ss_z >= z_top) {
		return 1.0;
	}
	int steps = clamp(int(sd_shadow.x), 1, SD_MAX_SHADOW_STEPS);
	float dz = (z_top - sd_ss_z) / float(steps);
	float metres_per_z = na / max(n_dot_l, SD_MIN_NDOTV);
	float softness = sd_shadow.z;
	float bias = 0.01 * amp;
	float occlusion = 0.0;
	for (int i = 1; i <= SD_MAX_SHADOW_STEPS; i++) {
		if (i > steps) {
			break;
		}
		float z = sd_ss_z + dz * float(i);
		float relief = sd_relief(sd_ss_uv + duv_dz * (z - sd_ss_z), sd_ss_params.x, amp);
		float above = relief - z - bias;
		if (softness <= 0.0) {
			if (above > 0.0) {
				occlusion = 1.0;
				break;
			}
		} else {
			float distance_m = (z - sd_ss_z) * metres_per_z;
			occlusion = max(occlusion, above * softness / max(distance_m, 1e-4));
		}
	}
	return mix(1.0, 1.0 - clamp(occlusion, 0.0, 1.0), strength);
}
#endif

#endif // SD_CORE_INCLUDED
