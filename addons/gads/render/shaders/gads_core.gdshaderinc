// GADS core: parallax occlusion mapping with adaptive steps, bisection refinement,
// mip-correct sampling, distance fade, LIGHT_VERTEX, optional self-shadowing in a Godot-matching
// light() and an opt-in depth write. Used by the generated variants in render/shaders/variants/ and by
// your own shaders.
//
// Before including, define exactly one mapping:
//     GADS_MAPPING_UV          mesh UVs (walls, props; needs tangents)
//     GADS_MAPPING_WORLD       world-planar XZ with rotation and offset (ground; no UVs needed)
//     GADS_MAPPING_TRIPLANAR   world triplanar (anything; only planes with weight > 0.05 are marched)
// and optionally:
//     GADS_POM                 parallax occlusion mapping (without it: plain normal mapping)
//     GADS_SELF_SHADOW         self-shadowing from directional lights, and omni and spot lights when
//                            gads_pom_steps.w is 1 (requires GADS_POM; adds light())
//     GADS_DEPTH_WRITE         writes DEPTH at the relief (requires GADS_POM; expensive, see README)
//
// Conventions (see docs/ARCHITECTURE.md):
//   - Height texture: red channel, 1 = top. It is remapped with height_remap (x -> 0, y -> 1).
//   - Relief in metres: z = height_m * (h - height_center), plus the optional detail layer
//     detail_height_m * (d - 0.5) with d from detail_height_texture repeated detail_scale times
//     per main repeat; measured along the relief axis
//     (the surface normal for UV mapping, world +Y for world-planar, the projection axis for
//     triplanar). height_center = 1: relief below the surface (classic POM, good on walls);
//     height_center = 0: relief above it (required for ground under a GADSDisplacementField3D).
//   - A view ray that leaves the camera and hits the flat surface at P passes relief height z at
//     uv(z) = uv(P) + duv_dz * z, duv_dz = (gu.V, gv.V) * (N.A) / (N.V), where gu/gv are the
//     gradients of u/v along the surface, N the surface normal, A the relief axis and V the unit
//     vector towards the camera. The march walks z from the top of the relief slab downwards.

#ifndef GADS_CORE_INCLUDED
#define GADS_CORE_INCLUDED

#include "res://addons/gads/render/shaders/gads_common.gdshaderinc"

// After a march the hit uv jumps at relief edges, so textures are sampled with the rasterized
// uv's derivatives. Without a march (flat variants of UV and world mapping) the implicit
// derivatives are the same and texture() matches BaseMaterial3D bit for bit.
#if defined(GADS_POM) || defined(GADS_MAPPING_TRIPLANAR)
#define GADS_SAMPLE(tex, uv, ddx, ddy) textureGrad(tex, uv, ddx, ddy)
#else
#define GADS_SAMPLE(tex, uv, ddx, ddy) texture(tex, uv)
#endif

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
group_uniforms detail;
// A second, finer layer on top of the main relief (meso detail: grain on stones, chips in bricks),
// repeated detail_scale times per main repeat. The height layer is off while detail_height_m is 0,
// the normal layer while detail_normal_strength is 0.
uniform sampler2D detail_height_texture : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float detail_height_m : hint_range(0.0, 0.1, 0.0001) = 0.0;
uniform float detail_scale : hint_range(1.0, 64.0) = 8.0;
uniform sampler2D detail_normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_normal_strength : hint_range(0.0, 4.0) = 0.0;
#ifdef GADS_LAYERED
// Layers 1 and 2 cover the layer below where their mask is: a vertex colour channel (or
// everywhere) times layerN_amount, times a band of the surface's up-facing when layerN_slope.y >
// layerN_slope.x (smoothstep of the world normal's y: (0.6, 0.85) = tops only). Within the mask
// the higher relief wins (height-aware blending); layerN_blend_width is the height range of the
// transition. Each layer has its own textures and depth, tiled layerN_scale times per main repeat.
group_uniforms layer1;
uniform sampler2D layer1_albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 layer1_tint : source_color = vec4(1.0);
uniform sampler2D layer1_normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float layer1_normal_strength : hint_range(0.0, 4.0) = 1.0;
uniform sampler2D layer1_orm_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer1_height_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float layer1_height_m : hint_range(0.0, 0.5, 0.0005) = 0.03;
uniform float layer1_scale : hint_range(0.05, 64.0) = 1.0;
uniform int layer1_mask_channel : hint_enum("Vertex R", "Vertex G", "Vertex B", "Vertex A", "Everywhere") = 0;
uniform float layer1_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 layer1_slope = vec2(0.0);
uniform float layer1_blend_width : hint_range(0.001, 1.0) = 0.1;
group_uniforms layer2;
uniform sampler2D layer2_albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 layer2_tint : source_color = vec4(1.0);
uniform sampler2D layer2_normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float layer2_normal_strength : hint_range(0.0, 4.0) = 1.0;
uniform sampler2D layer2_orm_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer2_height_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float layer2_height_m : hint_range(0.0, 0.5, 0.0005) = 0.03;
uniform float layer2_scale : hint_range(0.05, 64.0) = 1.0;
uniform int layer2_mask_channel : hint_enum("Vertex R", "Vertex G", "Vertex B", "Vertex A", "Everywhere") = 1;
uniform float layer2_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 layer2_slope = vec2(0.0);
uniform float layer2_blend_width : hint_range(0.001, 1.0) = 0.1;
#endif
group_uniforms mapping;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform vec2 texture_size_m = vec2(2.0);
uniform float planar_rotation_deg = 0.0;
uniform vec2 planar_offset_m = vec2(0.0);
uniform float triplanar_sharpness : hint_range(1.0, 16.0) = 4.0;
group_uniforms;

// 1 on a GADSMeshInstance3D that draws its baked mesh: the geometry already carries the relief,
// so nothing is marched, textures are mapped where each vertex was before it moved, and the
// normal map adds only the detail finer than the triangles (gads_detail_normal). The bake stores
// CUSTOM0 = rest position, mip level of the vertex's footprint; CUSTOM1 = rest normal, level / 32.
instance uniform float gads_baked = 0.0;

varying vec3 gads_world_pos;      // where textures are mapped (a baked mesh: the rest position)
varying vec3 gads_world_normal;   // the normal projections use (a baked mesh: the rest normal)
varying vec3 gads_geom_normal;    // the surface's own normal, the base of normal mapping
varying vec2 gads_tess;           // baked vertex: refinement level, footprint mip (height-map texels)

#ifdef GADS_SELF_SHADOW
// Handed from fragment() to light(), view space.
varying vec2 gads_ss_uv;
varying float gads_ss_z;
varying vec3 gads_ss_gu;
varying vec3 gads_ss_gv;
varying vec3 gads_ss_n;
varying vec3 gads_ss_axis;
varying vec4 gads_ss_params; // lod, amplitude, height_center, strength (0 = off)
#ifdef GADS_LAYERED
varying vec3 gads_ss_arg;    // the relief argument (fade, layer masks) of the hit
#endif
#endif

#ifdef GADS_LAYERED
// Relief argument: x = scale (the distance fade, 0 on a baked mesh), y / z = masks of layers 1, 2.
#define GADS_RELIEF_ARG vec3
varying vec2 gads_layer_masks; // vertex colour channel x amount of layers 1 and 2
#else
// Relief argument: the main amplitude (height_m x distance fade, 0 on a baked mesh).
#define GADS_RELIEF_ARG float
#endif

// One projection of the relief: a 2D texture parameterisation plus the frame the march needs.
struct GADSPlane {
	vec2 uv;      // uv at the rasterized point (relief height z = 0)
	vec2 ddx;     // screen-space uv derivatives (sampling after the march)
	vec2 ddy;
	vec3 gu;      // gradient of u along the surface (1/m), frame space
	vec3 gv;      // gradient of v along the surface (1/m)
	vec3 axis;    // relief axis (unit, outward)
	float weight;
};

float gads_remap(float h) {
	return gads_remap_height(h, height_remap);
}

// The detail layer's depth relative to the main one (0 = off), so the distance fade, which
// scales the main amplitude, fades both.
float gads_detail_ratio() {
	return detail_height_m > 0.0 ? detail_height_m / max(height_m, 1e-6) : 0.0;
}

// The main layer's relief (m) at uv for scale 1 and its remapped height, on mip level lod of the
// main map (may be negative, see gads_march_lod; the detail map is sampled at the matching level
// of its own texels).
float gads_main_relief(vec2 uv, float lod, out float h) {
	h = gads_remap(textureLod(height_texture, uv, max(lod, 0.0)).r);
	float relief = height_m * (h - height_center);
	if (detail_height_m > 0.0) {
		float texels = detail_scale * float(textureSize(detail_height_texture, 0).x) / float(textureSize(height_texture, 0).x);
		float detail = textureLod(detail_height_texture, uv * detail_scale, max(lod + log2(texels), 0.0)).r;
		relief += detail_height_m * (detail - 0.5);
	}
	return relief;
}

#ifdef GADS_LAYERED
// The mip level of a layer's map that matches level lod of the main height map.
float gads_layer_lod(float lod, vec2 layer_size, float scale) {
	return max(lod + log2(scale * layer_size.x / float(textureSize(height_texture, 0).x)), 0.0);
}

// Weight of a layer of height `above` over the layer below of height `below`, for mask m: 0 at
// m = 0 and 1 at m = 1 wherever the heights are; in between the higher relief wins, with a
// transition `width` high.
float gads_height_blend(float below, float above, float m, float width) {
	if (m <= 0.0) {
		return 0.0;
	}
	if (m >= 1.0) {
		return 1.0;
	}
	return smoothstep(-width, width, above - below + (2.0 * m - 1.0) * (1.0 + width));
}

// Blend weights (t1, t2) of layers 1 and 2 at uv, and the blended relief (m, scale 1).
float gads_layered_relief(vec2 uv, float lod, vec3 arg, out vec2 t) {
	float h;
	float relief = gads_main_relief(uv, lod, h);
	t = vec2(0.0);
	if (arg.y > 0.0) {
		float h1 = textureLod(layer1_height_texture, uv * layer1_scale,
				gads_layer_lod(lod, vec2(textureSize(layer1_height_texture, 0)), layer1_scale)).r;
		t.x = gads_height_blend(h, h1, arg.y, layer1_blend_width);
		relief = mix(relief, layer1_height_m * (h1 - height_center), t.x);
		h = mix(h, h1, t.x);
	}
	if (arg.z > 0.0) {
		float h2 = textureLod(layer2_height_texture, uv * layer2_scale,
				gads_layer_lod(lod, vec2(textureSize(layer2_height_texture, 0)), layer2_scale)).r;
		t.y = gads_height_blend(h, h2, arg.z, layer2_blend_width);
		relief = mix(relief, layer2_height_m * (h2 - height_center), t.y);
	}
	return relief;
}

// The deepest relief the active layers have (m).
float gads_layered_depth(vec3 arg) {
	float depth = height_m;
	depth = arg.y > 0.0 ? max(depth, layer1_height_m) : depth;
	return arg.z > 0.0 ? max(depth, layer2_height_m) : depth;
}

// The vertex colour channel a layer's mask comes from (4 = everywhere).
float gads_mask_channel(vec4 c, int channel) {
	return channel == 0 ? c.r : channel == 1 ? c.g : channel == 2 ? c.b : channel == 3 ? c.a : 1.0;
}

float gads_slope_band(vec2 band, float up) {
	return band.y > band.x ? smoothstep(band.x, band.y, up) : 1.0;
}
#endif

// Relief height (m) at uv on mip level lod of the main map, for relief argument arg.
float gads_relief(vec2 uv, float lod, GADS_RELIEF_ARG arg) {
#ifdef GADS_LAYERED
	vec2 t;
	return arg.x * gads_layered_relief(uv, lod, arg, t);
#else
	// Kept as it was before the layers so the single-layer variants draw bit for bit the same.
	float relief = arg * (gads_remap(textureLod(height_texture, uv, max(lod, 0.0)).r) - height_center);
	if (detail_height_m > 0.0) {
		float texels = detail_scale * float(textureSize(detail_height_texture, 0).x) / float(textureSize(height_texture, 0).x);
		float detail = textureLod(detail_height_texture, uv * detail_scale, max(lod + log2(texels), 0.0)).r;
		relief += arg * gads_detail_ratio() * (detail - 0.5);
	}
	return relief;
#endif
}

// The amplitude (m) of the relief argument: the largest relief depth after the fade.
float gads_relief_amp(GADS_RELIEF_ARG arg) {
#ifdef GADS_LAYERED
	return arg.x * gads_layered_depth(arg);
#else
	return arg;
#endif
}

// The relief slab: the highest and lowest relief height for the relief argument.
float gads_slab_top(GADS_RELIEF_ARG arg) {
#ifdef GADS_LAYERED
	return arg.x * (gads_layered_depth(arg) * (1.0 - height_center) + 0.5 * detail_height_m);
#else
	return arg * (1.0 - height_center + 0.5 * gads_detail_ratio());
#endif
}

float gads_slab_bottom(GADS_RELIEF_ARG arg) {
#ifdef GADS_LAYERED
	return -arg.x * (gads_layered_depth(arg) * height_center + 0.5 * detail_height_m);
#else
	return -arg * (height_center + 0.5 * gads_detail_ratio());
#endif
}

// Albedo (tinted), ORM and normal-map sample (packed) at uv with derivatives ddx, ddy: the main
// layer's, or the layers blended with the weights their heights give at level lod.
void gads_sample_surface(vec2 uv, vec2 ddx, vec2 ddy, float lod, GADS_RELIEF_ARG arg, out vec3 albedo, out vec3 orm,
		out vec3 nm) {
	albedo = GADS_SAMPLE(albedo_texture, uv, ddx, ddy).rgb;
	orm = GADS_SAMPLE(orm_texture, uv, ddx, ddy).rgb;
	nm = GADS_SAMPLE(normal_texture, uv, ddx, ddy).rgb;
#ifdef GADS_LAYERED
	albedo *= albedo_tint.rgb;
	vec2 t;
	gads_layered_relief(uv, lod, arg, t);
	vec3 n = vec3(nm.xy * 2.0 - 1.0, 0.0);
	n.xy *= normal_strength;
	if (t.x > 0.0) {
		vec2 s = layer1_scale * vec2(1.0);
		albedo = mix(albedo, textureGrad(layer1_albedo_texture, uv * s, ddx * s, ddy * s).rgb * layer1_tint.rgb, t.x);
		orm = mix(orm, textureGrad(layer1_orm_texture, uv * s, ddx * s, ddy * s).rgb, t.x);
		n.xy = mix(n.xy, (textureGrad(layer1_normal_texture, uv * s, ddx * s, ddy * s).rg * 2.0 - 1.0) * layer1_normal_strength, t.x);
	}
	if (t.y > 0.0) {
		vec2 s = layer2_scale * vec2(1.0);
		albedo = mix(albedo, textureGrad(layer2_albedo_texture, uv * s, ddx * s, ddy * s).rgb * layer2_tint.rgb, t.y);
		orm = mix(orm, textureGrad(layer2_orm_texture, uv * s, ddx * s, ddy * s).rgb, t.y);
		n.xy = mix(n.xy, (textureGrad(layer2_normal_texture, uv * s, ddx * s, ddy * s).rg * 2.0 - 1.0) * layer2_normal_strength, t.y);
	}
	// Strengths are applied here, so the caller uses strength 1.
	n.xy = n.xy / max(1.0, length(n.xy));
	nm = vec3(n.xy * 0.5 + 0.5, 1.0);
#endif
}

// The normal-map sample (packed) averaged over a footprint of level lod of the main height map:
// the main layer's, or the layers blended.
vec3 gads_normal_at_lod(vec2 uv, float lod, GADS_RELIEF_ARG arg) {
	float main_lod = max(lod + log2(float(textureSize(normal_texture, 0).x) / float(textureSize(height_texture, 0).x)), 0.0);
	vec3 nm = textureLod(normal_texture, uv, main_lod).rgb;
#ifdef GADS_LAYERED
	vec2 t;
	gads_layered_relief(uv, lod, arg, t);
	vec2 n = (nm.xy * 2.0 - 1.0) * normal_strength;
	if (t.x > 0.0) {
		float l1 = gads_layer_lod(lod, vec2(textureSize(layer1_normal_texture, 0)), layer1_scale);
		n = mix(n, (textureLod(layer1_normal_texture, uv * layer1_scale, l1).rg * 2.0 - 1.0) * layer1_normal_strength, t.x);
	}
	if (t.y > 0.0) {
		float l2 = gads_layer_lod(lod, vec2(textureSize(layer2_normal_texture, 0)), layer2_scale);
		n = mix(n, (textureLod(layer2_normal_texture, uv * layer2_scale, l2).rg * 2.0 - 1.0) * layer2_normal_strength, t.y);
	}
	n = n / max(1.0, length(n));
	nm = vec3(n * 0.5 + 0.5, 1.0);
#endif
	return nm;
}

// The strength the caller applies to gads_sample_surface()'s normal-map sample.
float gads_normal_strength() {
#ifdef GADS_LAYERED
	return 1.0;
#else
	return normal_strength;
#endif
}

// Adds the detail normal layer to a main normal-map sample (both packed like samples), by
// Reoriented Normal Mapping (Barre-Brisebois and Hill 2012).
vec3 gads_add_detail_normal(vec3 main_rgb, vec2 uv, vec2 ddx, vec2 ddy) {
	if (detail_normal_strength <= 0.0) {
		return main_rgb;
	}
	vec3 b = main_rgb * 2.0 - 1.0;
	b.z = sqrt(max(0.0, 1.0 - dot(b.xy, b.xy)));
	vec2 dxy = (textureGrad(detail_normal_texture, uv * detail_scale, ddx * detail_scale, ddy * detail_scale).rg * 2.0 - 1.0)
			* detail_normal_strength;
	vec3 d = normalize(vec3(dxy, sqrt(max(0.0, 1.0 - min(dot(dxy, dxy), 0.9999)))));
	vec3 t = vec3(b.xy, b.z + 1.0);
	vec3 u = vec3(-d.xy, d.z);
	return normalize(t * dot(t, u) / t.z - u) * 0.5 + 0.5;
}

// The mip level of the main height map the march samples: the level the hardware would pick for
// the rasterized uv (isotropic, from derivatives taken before any divergent control flow), plus
// a bias. Negative where the map is magnified: each sample clamps it to its own map, so the
// detail layer (finer texels) keeps its own level.
float gads_march_lod(GADSPlane p) {
	vec2 size = vec2(textureSize(height_texture, 0));
	vec2 dx = p.ddx * size;
	vec2 dy = p.ddy * size;
	float rho2 = max(dot(dx, dx), dot(dy, dy));
	return 0.5 * log2(max(rho2, 1e-12)) + gads_pom_range.z;
}

// uv change per metre of relief height along the view ray (see the header comment).
vec2 gads_duv_dz(GADSPlane p, vec3 n, vec3 v) {
	float nv = max(dot(n, v), GADS_MIN_NDOTV);
	return vec2(dot(p.gu, v), dot(p.gv, v)) * (dot(n, p.axis) / nv);
}

// A baked mesh's geometry carries the relief down to the mip level of its triangles' footprint;
// the normal map supplies what lies below. Returns the part of the normal-map sample `fine` (at
// p's uv derivatives) that the geometry does not carry: `fine` seen from the frame of the normal
// map averaged over the footprint (Reoriented Normal Mapping run backwards, Barre-Brisebois and
// Hill 2012), packed like a sample. Where the triangles are smaller than a pixel both samples are
// the same and the detail is flat: the geometry's own normal shades.
vec3 gads_detail_normal(vec3 fine, GADSPlane p, vec2 uv, GADS_RELIEF_ARG arg) {
	vec2 size = vec2(textureSize(height_texture, 0));
	vec2 dx = p.ddx * size;
	vec2 dy = p.ddy * size;
	float pixel_lod = 0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1e-12));
	vec3 c = gads_normal_at_lod(uv, max(gads_tess.y, pixel_lod), arg) * 2.0 - 1.0;
	c.z = sqrt(max(0.0, 1.0 - dot(c.xy, c.xy)));
	vec3 f = fine * 2.0 - 1.0;
	f.z = sqrt(max(0.0, 1.0 - dot(f.xy, f.xy)));
	// The rotation that takes c to +Z is the one that takes +Z to (-c.x, -c.y, c.z).
	vec3 t = vec3(-c.xy, c.z + 1.0);
	vec3 u = vec3(-f.xy, f.z);
	return normalize(t * dot(t, u) / t.z - u) * 0.5 + 0.5;
}

#define GADS_RELIEF(coord, lod, amp) gads_relief(coord, lod, amp)
#include "res://addons/gads/render/shaders/gads_march.gdshaderinc"

// Number of linear steps: more at grazing angles, scaled by the fade and the material.
int gads_step_count(float n_dot_v, float fade) {
	float n = mix(gads_pom_steps.y, gads_pom_steps.x, clamp(n_dot_v, 0.0, 1.0)) * pom_steps_scale * fade;
	return clamp(int(ceil(n)), 1, GADS_MAX_STEPS);
}

#ifdef GADS_MAPPING_WORLD
// World-planar XZ projection, rotated by planar_rotation_deg around +Y and shifted by
// planar_offset_m, one texture tile per texture_size_m. Frame space = world.
GADSPlane gads_world_plane(vec3 wpos) {
	float a = radians(planar_rotation_deg);
	float c = cos(a);
	float s = sin(a);
	GADSPlane p;
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

#ifdef GADS_MAPPING_TRIPLANAR
// Plane `axis_index` (0 = X, 1 = Y, 2 = Z) of a world triplanar projection facing along the sign of
// the normal's component. Orientation: the image's right and up directions form a right-handed
// frame with the outward axis on every face, so normal maps read correctly on all six sides.
GADSPlane gads_triplanar_plane(vec3 wpos, vec3 n, int axis_index, float weight) {
	GADSPlane p;
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
vec3 gads_triplanar_weights(vec3 n) {
	vec3 w = pow(abs(n), vec3(triplanar_sharpness));
	w /= max(w.x + w.y + w.z, 1e-6);
	w = mix(w, vec3(0.0), lessThan(w, vec3(0.05)));
	return w / max(w.x + w.y + w.z, 1e-6);
}
#endif

#ifdef GADS_SELF_SHADOW
// Height-field shadow towards light direction l (view space) from the hit found in fragment().
// Hard (softness 0): 0 behind any relief above the light ray. Contact-hardening (softness k > 0,
// after Tatarchuk 2006): the largest (relief - ray) * k / distance over the samples, so occluders
// close to the receiver cast sharp shadows and distant ones soft shadows.
float gads_self_shadow(vec3 l) {
	float strength = gads_ss_params.w;
	float amp = gads_ss_params.y;
	if (strength <= 0.0 || amp <= 0.0) {
		return 1.0;
	}
	float n_dot_l = dot(gads_ss_n, l);
	if (n_dot_l <= 0.0) {
		return 1.0; // Unlit side: the BRDF already returns zero.
	}
	float na = dot(gads_ss_n, gads_ss_axis);
	vec2 duv_dz = vec2(dot(gads_ss_gu, l), dot(gads_ss_gv, l)) * (na / max(n_dot_l, GADS_MIN_NDOTV));
#ifdef GADS_LAYERED
	GADS_RELIEF_ARG arg = gads_ss_arg;
#else
	GADS_RELIEF_ARG arg = amp;
#endif
	float z_top = gads_slab_top(arg);
	if (gads_ss_z >= z_top) {
		return 1.0;
	}
	int steps = clamp(int(gads_shadow.x), 1, GADS_MAX_SHADOW_STEPS);
	float dz = (z_top - gads_ss_z) / float(steps);
	float metres_per_z = na / max(n_dot_l, GADS_MIN_NDOTV);
	float softness = gads_shadow.z;
	float bias = 0.01 * amp;
	float occlusion = 0.0;
	for (int i = 1; i <= GADS_MAX_SHADOW_STEPS; i++) {
		if (i > steps) {
			break;
		}
		float z = gads_ss_z + dz * float(i);
		float relief = gads_relief(gads_ss_uv + duv_dz * (z - gads_ss_z), gads_ss_params.x, arg);
		float above = relief - z - bias;
		if (softness <= 0.0) {
			if (above > 0.0) {
				occlusion = 1.0;
				break;
			}
		} else {
			float distance_m = (z - gads_ss_z) * metres_per_z;
			occlusion = max(occlusion, above * softness / max(distance_m, 1e-4));
		}
	}
	return mix(1.0, 1.0 - clamp(occlusion, 0.0, 1.0), strength);
}
#endif

#endif // GADS_CORE_INCLUDED
