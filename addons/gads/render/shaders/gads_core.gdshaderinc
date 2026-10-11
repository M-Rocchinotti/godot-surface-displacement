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
//   - Custom hooks (define the macro and the function; see README, Custom shaders):
//       GADS_CUSTOM_HEIGHT       float gads_custom_height(vec2 uv, float h): reshapes the main
//                                remapped height (0..1) wherever it is read (march, self-shadow,
//                                effects). Define it before including this file. Parallax only: a
//                                bake reads the height texture itself.
//       GADS_CUSTOM_SURFACE      void gads_custom_surface(vec2 uv, vec3 world_pos, vec3 world_normal,
//                                float height, inout vec3 albedo, inout float roughness,
//                                inout float metallic, inout float ao): after the textures and
//                                effects. Define it after this file, before gads_surface.
//       GADS_CUSTOM_LAYER_MASKS  vec3 gads_custom_layer_masks(vec3 masks, vec3 world_pos,
//                                vec3 world_normal): the layered variants' extra-layer masks.
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
// Displacement mask: a vertex colour channel scales the relief (0 flat, 1 full depth), painted
// with the Paint tools; the bake follows it.
uniform int relief_vertex_mask : hint_enum("None", "Vertex R", "Vertex G", "Vertex B", "Vertex A") = 0;
group_uniforms detail;
// A second, finer layer on top of the main relief (meso detail: grain on stones, chips in bricks),
// repeated detail_scale times per main repeat. The height layer is off while detail_height_m is 0,
// the normal layer while detail_normal_strength is 0.
uniform sampler2D detail_height_texture : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float detail_height_m : hint_range(0.0, 0.1, 0.0001) = 0.0;
uniform float detail_scale : hint_range(1.0, 64.0) = 8.0;
uniform sampler2D detail_normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_normal_strength : hint_range(0.0, 4.0) = 0.0;
#ifdef GADS_MAPPING_UV
group_uniforms vector_displacement;
// Vector displacement: an XYZ offset per texel, for baked meshes only. A GADSMeshInstance3D bake
// moves vertices by it (tangent space: x along +u, y along the texture's up (-v), z along the
// normal; or object space), on top of the height map. Shading does not use it (the bake's normals
// carry it). Off while vector_displacement_m is 0.
uniform sampler2D vector_displacement_texture : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float vector_displacement_m : hint_range(0.0, 1.0, 0.0005) = 0.0;
uniform int vector_displacement_space : hint_enum("Tangent", "Object") = 0;
// Signed: texel values are offsets as they are (an EXR or HDR); unsigned: 0..1 maps to -1..1.
uniform bool vector_displacement_signed = false;
#endif
group_uniforms effects;
// Optional surface effects on top of the textures. They change only the shading (albedo,
// roughness, metallic, AO, how much of the normal map shows), never the relief or a bake, and
// read the main height map at the hit. All off by default, and then free (one uniform branch).
// - Cover (snow, dust, sand): on surfaces facing up (cover_slope: band of the world normal's y),
//   on relief tops first (cover_height_bias > 0) or in hollows first (< 0).
// - Wetness: darker and glossier. Puddles: flat water where the relief lies below
//   puddle_level on level ground.
// - Cavity / edge: a colour in the relief's hollows (dirt, moss) / on its crests (wear),
//   against the relief within cavity_radius mip levels around (3 = 8 texels).
// The global gads_weather (GADSManager: rain, snow, puddles) adds to every material, scaled by
// weather_response; effects_vertex_mask limits all of it to a painted vertex colour channel.
uniform vec4 cover_color : source_color = vec4(0.92, 0.94, 0.97, 1.0);
uniform float cover_amount : hint_range(0.0, 1.0) = 0.0;
uniform float cover_roughness : hint_range(0.0, 1.0) = 0.65;
uniform vec2 cover_slope = vec2(0.35, 0.75);
uniform float cover_height_bias : hint_range(-1.0, 1.0) = 0.5;
uniform float cover_sharpness : hint_range(1.0, 64.0) = 8.0;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float puddle_level : hint_range(0.0, 1.0) = 0.0;
uniform vec4 cavity_color : source_color = vec4(0.16, 0.14, 0.1, 1.0);
uniform float cavity_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 edge_color : source_color = vec4(0.85, 0.82, 0.76, 1.0);
uniform float edge_amount : hint_range(0.0, 1.0) = 0.0;
uniform float cavity_radius : hint_range(1.0, 6.0) = 3.0;
uniform int effects_vertex_mask : hint_enum("None", "Vertex R", "Vertex G", "Vertex B", "Vertex A") = 0;
uniform float weather_response : hint_range(0.0, 1.0) = 1.0;
#ifdef GADS_LAYERED
// Up to GADS_LAYERED_LAYERS extra layers on top of the main one (base + 3 = 4 total, matching the
// field's GADS_FIELD_LAYERS). Each covers the layer below where its mask is: a vertex colour channel
// (or everywhere, layer_mask_channel[i]) times layer_amount[i], times a band of the surface's
// up-facing when layer_slope[i].y > layer_slope[i].x (smoothstep of the world normal's y:
// (0.6, 0.85) = tops only). Within the mask the higher relief wins (height-aware blending);
// layer_blend_width[i] is the height range of the transition. Each layer has its own slice of the
// texture arrays and its own depth, tiled layer_scale[i] times per main repeat.
#define GADS_LAYERED_LAYERS 3
group_uniforms layers;
// One array texture per channel (all layers share a resolution; built by GADSMaterials from the
// per-material textures): one texture unit each instead of one per layer, so the fragment shader
// stays within the Compatibility renderer's 16-unit limit and the layer count is no longer capped
// by it. The hints match the main maps and the field (gads_field.gdshaderinc).
uniform sampler2DArray layer_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_orm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_height : filter_linear_mipmap, repeat_enable;
// Per-layer scalars (one element each; set by GADSMaterials). Array uniforms carry no shader
// default, so GADSMaterials.get_layer_param supplies the default a material never set. layer_tint
// is linearised in the GDScript, as the field does, because an array uniform cannot carry the
// source_color hint the single-layer tint had.
uniform float layer_height_m[GADS_LAYERED_LAYERS];
uniform float layer_scale[GADS_LAYERED_LAYERS];
uniform int layer_mask_channel[GADS_LAYERED_LAYERS];
uniform float layer_amount[GADS_LAYERED_LAYERS];
uniform vec2 layer_slope[GADS_LAYERED_LAYERS];
uniform float layer_blend_width[GADS_LAYERED_LAYERS];
uniform float layer_normal_strength[GADS_LAYERED_LAYERS];
uniform vec4 layer_tint[GADS_LAYERED_LAYERS];
#endif
group_uniforms mapping;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform vec2 texture_size_m = vec2(2.0);
uniform float planar_rotation_deg = 0.0;
uniform vec2 planar_offset_m = vec2(0.0);
uniform float triplanar_sharpness : hint_range(1.0, 16.0) = 4.0;
group_uniforms animation;
// Animated relief (lava, flowing water, breathing surfaces): every map moves along flow_speed
// (texture tiles per second), the relief, its shading and its shadows together, and the relief's
// depth breathes between height_m and (1 - pulse_amount) x height_m, pulse_rate times a second.
// Parallax and the near-camera field animate; a baked mesh keeps the relief at rest.
uniform vec2 flow_speed = vec2(0.0);
uniform float pulse_amount : hint_range(0.0, 1.0) = 0.0;
uniform float pulse_rate : hint_range(0.0, 10.0) = 0.5;
group_uniforms;

// 1 on a GADSMeshInstance3D that draws its baked mesh: the geometry already carries the relief,
// so nothing is marched, textures are mapped where each vertex was before it moved, and the
// normal map adds only the detail finer than the triangles (gads_detail_normal). The bake stores
// CUSTOM0 = rest position, mip level of the vertex's footprint; CUSTOM1 = rest normal, level / 32.
instance uniform float gads_baked = 0.0;
// Per-node variation of a shared material (GeometryInstance3D instance shader parameters): the
// relief's depth times gads_relief_scale (a GADSMeshInstance3D bakes with it) and the albedo
// times gads_tint, so many props can share one material, and its batching, and still differ.
instance uniform float gads_relief_scale = 1.0;
// The cluster a GADSMeshInstance3D's internal node draws (1, 2, ...; 0: not clustered), for the
// Clusters debug view.
instance uniform float gads_cluster = 0.0;
instance uniform vec4 gads_tint : source_color = vec4(1.0);
// A plain-uniform twin of gads_baked for the Compatibility (OpenGL/WebGL) renderer, which ignores
// instance uniforms: GADSMeshInstance3D sets this (on a per-mesh material) there instead. Use
// gads_baked_amount() rather than gads_baked so both renderers agree.
uniform float gads_baked_u = 0.0;

float gads_baked_amount() {
	return max(gads_baked, gads_baked_u);
}

// How far the maps have moved (texture tiles) and the relief's depth factor now (see flow_speed,
// pulse_amount); at rest on a baked mesh, whose geometry cannot follow.
vec2 gads_flow() {
	return gads_baked_amount() > 0.5 ? vec2(0.0) : flow_speed * TIME;
}

float gads_pulse_now() {
	return gads_baked_amount() > 0.5 ? 1.0 : gads_pulse(pulse_amount, pulse_rate);
}

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
varying vec4 gads_ss_arg;    // the relief argument (fade, extra-layer masks) of the hit, for light()
#endif
#endif

#ifdef GADS_LAYERED
// Relief argument: x = scale (the distance fade, 0 on a baked mesh), y / z / w = masks of the up to
// GADS_LAYERED_LAYERS extra layers. The masks are computed per fragment from COLOR (a fragment
// built-in) and the slope band, so no vertex->fragment varying carries them: the old gads_layer_masks
// vec2 is gone, and with it the two-layer cap its width imposed. light() cannot read COLOR, so the
// self-shadow still carries the whole argument in gads_ss_arg (one varying, as before).
#define GADS_RELIEF_ARG vec4
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

// The main height map's remapped height (0..1) at uv on mip level lod, through the custom height
// hook when there is one.
float gads_main_height(vec2 uv, float lod) {
	float h = gads_remap(textureLod(height_texture, uv, max(lod, 0.0)).r);
#ifdef GADS_CUSTOM_HEIGHT
	h = clamp(gads_custom_height(uv, h), 0.0, 1.0);
#endif
	return h;
}

// The vertex colour channel a mask comes from (4 = everywhere).
float gads_mask_channel(vec4 c, int channel) {
	return channel == 0 ? c.r : channel == 1 ? c.g : channel == 2 ? c.b : channel == 3 ? c.a : 1.0;
}

// The relief_vertex_mask at a vertex colour (1 without one).
float gads_relief_mask(vec4 color) {
	return relief_vertex_mask == 0 ? 1.0 : gads_mask_channel(color, relief_vertex_mask - 1);
}

// Surface effects (see the effects uniforms, plus the weather) at the hit uv (main map mip lod)
// on a surface whose world normal has y = up. normal_keep: how much of the normal map stays.
void gads_surface_effects(vec2 uv, float lod, float up, vec4 vertex_color,
		inout vec3 albedo, inout float roughness, inout float metallic, inout float ao, out float normal_keep) {
	normal_keep = 1.0;
	GADSEffects e;
	e.cover_color = vec4(cover_color.rgb, cover_roughness);
	e.cover = vec4(max(cover_amount, gads_weather.y * weather_response), cover_slope, cover_height_bias);
	e.sharpness = cover_sharpness;
	e.wetness = max(wetness, gads_weather.x * weather_response);
	e.puddle = max(puddle_level, gads_weather.z * weather_response);
	e.cavity = vec4(cavity_color.rgb, cavity_amount);
	e.edge = vec4(edge_color.rgb, edge_amount);
	if (!gads_effects_on(e)) {
		return;
	}
	float mask = effects_vertex_mask == 0 ? 1.0 : gads_mask_channel(vertex_color, effects_vertex_mask - 1);
	float h = gads_main_height(uv, lod);
	float around = cavity_amount > 0.0 || edge_amount > 0.0 ? gads_main_height(uv, max(lod, 0.0) + cavity_radius) : h;
	gads_apply_effects(e, h, around, up, mask, albedo, roughness, metallic, ao, normal_keep);
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
	h = gads_main_height(uv, lod);
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

float gads_slope_band(vec2 band, float up) {
	return band.y > band.x ? smoothstep(band.x, band.y, up) : 1.0;
}

// The mask of extra layer i at vertex colour `color` on a surface whose world normal has y = up:
// its vertex-colour channel (gads_mask_channel) times layer_amount[i], times the slope band. It is
// constant over the pixel, so it is recomputed wherever needed (fragment() and the self-shadow)
// rather than carried in a varying.
float gads_layer_mask(int i, vec4 color, float up) {
	return gads_mask_channel(color, layer_mask_channel[i]) * layer_amount[i] * gads_slope_band(layer_slope[i], up);
}

// Optional per-texel control map (Stage 2 of the terrain-parity plan): the seam the
// GADS_CUSTOM_LAYER_MASKS hook was reserved for. An RGB weight texture sampled by world XZ, R/G/B =
// the three extra layers' masks (0..1), so layer boundaries are crisp per fragment instead of
// limited to the per-vertex vertex colours. control_rect = (origin.x, origin.z, 1/size.x, 1/size.z)
// in world metres (origin = the map's min corner); .z <= 0 means no map is bound, so the incoming
// vertex-colour + slope/height-rule masks stand unchanged (backward compatible) -- the whole thing
// is a runtime branch, not a shader variant, so the variant table and the sampler budget (one extra
// unit, well within WebGL's 16) are untouched. Where a map is bound and the fragment lies inside it,
// the map is authoritative for the per-texel layer selection, but each layer still rides its own
// amount and slope band (gads_layer_mask's modifiers), so a layer can be limited to slopes or
// switched off (an unused layer has amount 0, so the control map cannot turn it on). filter_linear
// keeps the boundary one texel wide; the map carries no mips, so textureLod(..., 0.0) is safe in the
// in-bounds branch. The near-camera GADSDisplacementField3D samples the same map the same way
// (gads_field.gdshaderinc), so the field and the chunks agree at a boundary. A custom shader may
// still provide its own gads_custom_layer_masks by defining GADS_CUSTOM_LAYER_MASKS before this file.
#ifndef GADS_CUSTOM_LAYER_MASKS
#define GADS_CUSTOM_LAYER_MASKS
uniform sampler2D control_map : filter_linear, repeat_disable;
uniform vec4 control_rect = vec4(0.0);

vec3 gads_custom_layer_masks(vec3 masks, vec3 world_pos, vec3 world_normal) {
	if (control_rect.z <= 0.0) {
		return masks; // no control map: the vertex-colour + slope/height-rule masks stand
	}
	vec2 uv = (world_pos.xz - control_rect.xy) * control_rect.zw;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return masks; // outside the map: keep the incoming masks (rules continue past its edge)
	}
	vec3 c = textureLod(control_map, uv, 0.0).rgb;
	float up = world_normal.y;
	vec3 m;
	for (int i = 0; i < GADS_LAYERED_LAYERS; i++) {
		m[i] = c[i] * layer_amount[i] * gads_slope_band(layer_slope[i], up);
	}
	return m;
}
#endif

// Blend weights t[i] of the extra layers at uv, and the blended relief (m, scale 1): each active
// layer (mask arg[i + 1] > 0) lies over the result so far by its height-aware weight, the higher
// relief winning in between (gads_height_blend) -- the same sequential blend layers 1 and 2 did
// unrolled, now over GADS_LAYERED_LAYERS layers.
float gads_layered_relief(vec2 uv, float lod, vec4 arg, out vec3 t) {
	float h;
	float relief = gads_main_relief(uv, lod, h);
	t = vec3(0.0);
	for (int i = 0; i < GADS_LAYERED_LAYERS; i++) {
		float m = arg[i + 1];
		if (m <= 0.0) {
			continue;
		}
		float hi = textureLod(layer_height, vec3(uv * layer_scale[i], float(i)),
				gads_layer_lod(lod, vec2(textureSize(layer_height, 0).xy), layer_scale[i])).r;
		t[i] = gads_height_blend(h, hi, m, layer_blend_width[i]);
		relief = mix(relief, layer_height_m[i] * (hi - height_center), t[i]);
		h = mix(h, hi, t[i]);
	}
	return relief;
}

// The deepest relief the active extra layers -- or the main one -- can show (m).
float gads_layered_depth(vec4 arg) {
	float depth = height_m;
	for (int i = 0; i < GADS_LAYERED_LAYERS; i++) {
		if (arg[i + 1] > 0.0) {
			depth = max(depth, layer_height_m[i]);
		}
	}
	return depth;
}
#endif

// Relief height (m) at uv on mip level lod of the main map, for relief argument arg.
float gads_relief(vec2 uv, float lod, GADS_RELIEF_ARG arg) {
#ifdef GADS_LAYERED
	vec3 t;
	return arg.x * gads_layered_relief(uv, lod, arg, t);
#else
	// Kept as it was before the layers so the single-layer variants draw bit for bit the same.
	float relief = arg * (gads_main_height(uv, lod) - height_center);
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
	vec3 t;
	gads_layered_relief(uv, lod, arg, t);
	vec3 n = vec3(nm.xy * 2.0 - 1.0, 0.0);
	n.xy *= normal_strength;
	for (int i = 0; i < GADS_LAYERED_LAYERS; i++) {
		if (t[i] <= 0.0) {
			continue;
		}
		vec2 s = layer_scale[i] * vec2(1.0);
		vec3 coord = vec3(uv * s, float(i));
		albedo = mix(albedo, textureGrad(layer_albedo, coord, ddx * s, ddy * s).rgb * layer_tint[i].rgb, t[i]);
		orm = mix(orm, textureGrad(layer_orm, coord, ddx * s, ddy * s).rgb, t[i]);
		n.xy = mix(n.xy, (textureGrad(layer_normal, coord, ddx * s, ddy * s).rg * 2.0 - 1.0) * layer_normal_strength[i], t[i]);
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
	vec3 t;
	gads_layered_relief(uv, lod, arg, t);
	vec2 n = (nm.xy * 2.0 - 1.0) * normal_strength;
	for (int i = 0; i < GADS_LAYERED_LAYERS; i++) {
		if (t[i] <= 0.0) {
			continue;
		}
		float li = gads_layer_lod(lod, vec2(textureSize(layer_normal, 0).xy), layer_scale[i]);
		n = mix(n, (textureLod(layer_normal, vec3(uv * layer_scale[i], float(i)), li).rg * 2.0 - 1.0) * layer_normal_strength[i], t[i]);
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
	p.uv = vec2(dot(p.gu, q), dot(p.gv, q)) - gads_flow();
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
	p.uv = vec2(dot(p.gu, q), dot(p.gv, q)) - gads_flow();
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
