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

#include "res://addons/surface_displacement/shaders/sd_common.gdshaderinc"

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

#define SD_RELIEF(coord, lod, amp) sd_relief(coord, lod, amp)
#include "res://addons/surface_displacement/shaders/sd_march.gdshaderinc"

// Number of linear steps: more at grazing angles, scaled by the fade and the material.
int sd_step_count(float n_dot_v, float fade) {
	float n = mix(sd_pom_steps.y, sd_pom_steps.x, clamp(n_dot_v, 0.0, 1.0)) * pom_steps_scale * fade;
	return clamp(int(ceil(n)), 1, SD_MAX_STEPS);
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
