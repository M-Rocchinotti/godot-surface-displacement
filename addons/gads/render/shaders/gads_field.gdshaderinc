// GADSDisplacementField3D: a camera-centred geometry clipmap of the ground with real vertex
// displacement near the camera, blending into parallax occlusion mapping at its edge.
//
// Mesh (built by terrain/gads_displacement_field_3d.gd): L nested square rings of N x N quads; ring k
// has spacing s0 * 2^k. Per vertex: UV = lattice coordinates in units of s0 (integers),
// UV2 = (ring k, seam flag: 1 = on the ring's outer edge, 2 = on its inner edge).
//
// Crack-free seams by construction (geomorphing, after CDLOD): towards its outer edge a ring
// moves its odd lattice vertices onto their even neighbours and samples the height one mip
// coarser, so at the edge (m = 1) its vertices, positions and heights are bit-identical to the
// next ring's (m = 0). Edge vertices force m = 1 / m = 0, whatever the distances say.
//
// Height, "up only": y = ground + lift + fade * relief, where ground and the layer weights w come
// from the baked ground or a flat plane (gads_ground.gdshaderinc) and the relief blends the
// layers' height_m_i * h_i by height, as the layered material does: where layers meet, the higher
// relief wins (stones stick out of sand) instead of an average. h_i is each layer's height map at
// the mip that matches the vertex spacing. Where no layer is
// displaceable, the vertices dive `push_down` below the ground so the original ground mesh hides
// them. The vertices pass the layer weights on to the fragments.
//
// The geometry can only carry relief down to its vertex spacing (4 cm at Ultra): a gravel's
// individual stones are finer than that. So the geometry is a proxy (coverage, silhouettes, real
// depth for SSAO and intersections, the coarse relief) and, with GADS_POM, every fragment still
// marches the full-resolution height field along its true view ray over the whole relief slab,
// exactly as the ground material does. The shading therefore equals the ground's parallax
// shading wherever the two overlap, and the field fades into the ground seamlessly.
//
// Defines: GADS_POM (parallax on the proxy) and GADS_SELF_SHADOW (requires GADS_POM; self-shadowing
// light()).

#include "res://addons/gads/render/shaders/gads_common.gdshaderinc"
#include "res://addons/gads/render/shaders/gads_ground.gdshaderinc"

#define GADS_FIELD_MAX_LEVELS 8
#define GADS_FIELD_LAYERS 4

// Set every frame / on change by GADSDisplacementField3D.
uniform vec3 field_origin;        // world position of lattice (0, 0) (snapped)
uniform vec3 field_camera;        // tracked camera, world
uniform float base_spacing = 0.02;
uniform vec4 level_morph[GADS_FIELD_MAX_LEVELS]; // per ring: morph start (m), morph end (m)
uniform vec2 amp_fade = vec2(10.0, 12.0);      // relief fades out between these distances (m)
uniform float lift = 0.002;
uniform float push_down = 0.1;
// Layers (copied from the ground materials).
uniform int layer_count = 1;
// One array texture per channel (all layers share a resolution; built by the GDScript): one texture
// unit each instead of one per layer, so the fragment shader fits the Compatibility 16-unit limit.
uniform sampler2DArray layer_height : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray layer_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_orm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 layer_a[GADS_FIELD_LAYERS]; // height_m, remap low, remap high, normal strength
uniform vec4 layer_b[GADS_FIELD_LAYERS]; // 1 / size x, 1 / size z, offset x, offset z
uniform vec4 layer_c[GADS_FIELD_LAYERS]; // cos(rotation), sin(rotation), ao strength, roughness scale
uniform vec4 layer_d[GADS_FIELD_LAYERS]; // albedo tint rgb, metallic scale
uniform vec4 layer_e[GADS_FIELD_LAYERS]; // specular, steps scale, self-shadow strength, -log2(texel size in m)
uniform vec4 layer_anim[GADS_FIELD_LAYERS]; // flow (texture tiles / s) x, y, pulse amount, pulse rate (Hz)
// Each layer material's surface effects (see gads_core.gdshaderinc), blended by the weights.
uniform vec4 layer_fx_cover_color[GADS_FIELD_LAYERS]; // cover colour rgb, cover roughness
uniform vec4 layer_fx_cover[GADS_FIELD_LAYERS];       // cover amount, slope from, slope to, height bias
uniform vec4 layer_fx_water[GADS_FIELD_LAYERS];       // wetness, puddle level, weather response, cover sharpness
uniform vec4 layer_fx_cavity[GADS_FIELD_LAYERS];      // cavity colour rgb, amount
uniform vec4 layer_fx_edge[GADS_FIELD_LAYERS];        // edge colour rgb, amount
uniform vec4 layer_fx_radius[GADS_FIELD_LAYERS];      // cavity radius (mip levels), unused x3

varying vec3 f_base_normal;
varying float f_ground;
varying float f_level;
varying vec4 f_weights;        // normalised layer weights
varying float f_displaceable;  // 0 = no layer here (the vertices dove under the ground)

#ifdef GADS_SELF_SHADOW
varying vec2 f_ss_xz;
varying float f_ss_z;
varying vec3 f_ss_n;       // view space
varying vec3 f_ss_x;       // world +X in view space
varying vec3 f_ss_z_axis;  // world +Z in view space
varying vec3 f_ss_up;      // world +Y in view space
varying vec4 f_ss_weights;
varying vec4 f_ss_params;  // lod (log2 m per pixel), amplitude, strength, specular
#endif

// Layer uv at world xz (same mapping as gads_world_plane in gads_core.gdshaderinc).
vec2 gads_layer_uv(int i, vec2 xz) {
	vec2 q = xz - layer_b[i].zw;
	vec2 cs = layer_c[i].xy;
	return vec2(cs.x * q.x - cs.y * q.y, cs.y * q.x + cs.x * q.y) * layer_b[i].xy - layer_anim[i].xy * TIME;
}

float gads_layer_h(int i, vec2 xz, float lod) {
	float h = GADS_LAYER_LOD(layer_height, i, gads_layer_uv(i, xz), lod).r;
	return gads_remap_height(h, layer_a[i].yz);
}

// The transition between two layers' reliefs (normalised heights), as gads_core's
// gads_height_blend: the weight of `above` over `below` for its share m of the weights, the
// higher relief winning in between, over a transition `width` high.
#define GADS_FIELD_BLEND_WIDTH 0.1
float gads_field_height_blend(float below, float above, float m, float width) {
	if (m <= 0.0) {
		return 0.0;
	}
	if (m >= 1.0) {
		return 1.0;
	}
	return smoothstep(-width, width, above - below + (2.0 * m - 1.0) * (1.0 + width));
}

// The layers' relief above the ground (m) at world xz, blended by height: each layer lies over
// the ones before it by its share of their weights so far, the higher relief winning in between;
// scaled by the weights' sum (the distance fade passes scaled weights). `eff`: the weight the
// blend gives each layer, for the shading. `lod` is log2 of metres per sample; each layer adds
// -log2 of its texel size.
float gads_field_layers(vec2 xz, float lod, vec4 w, out vec4 eff) {
	eff = vec4(0.0);
	float relief = 0.0;
	float h_acc = 0.0;
	float acc = 0.0;
	for (int i = 0; i < GADS_FIELD_LAYERS; i++) {
		if (i >= layer_count) {
			break;
		}
		if (w[i] <= 0.001) {
			continue;
		}
		float h = gads_layer_h(i, xz, max(lod + layer_e[i].w, 0.0));
		acc += w[i];
		float t = gads_field_height_blend(h_acc, h, w[i] / acc, GADS_FIELD_BLEND_WIDTH);
		relief = mix(relief, layer_a[i].x * gads_pulse(layer_anim[i].z, layer_anim[i].w) * h, t);
		h_acc = mix(h_acc, h, t);
		eff *= 1.0 - t;
		eff[i] = t;
	}
	return relief * acc;
}

// Relief above the ground (m) at world xz, minus the runtime deformation there.
float gads_field_relief(vec2 xz, float lod, vec4 w) {
	vec4 eff;
	return gads_field_layers(xz, lod, w, eff) - gads_deformation(xz);
}

// The deepest relief the weighted layers can show (the march's slab): the highest active layer's
// depth (blended by height, the relief reaches any of them), scaled like the relief.
float gads_field_amp(vec4 w) {
	float a = 0.0;
	float acc = 0.0;
	for (int i = 0; i < GADS_FIELD_LAYERS; i++) {
		if (i < layer_count && w[i] > 0.001) {
			a = max(a, layer_a[i].x);
			acc += w[i];
		}
	}
	return a * acc;
}

// Normalised layer weights from the ground's, and how displaceable the point is (0 = not at all).
vec4 gads_field_weights(vec4 ground_weights, out float displaceable) {
	vec4 w = ground_weights;
	vec4 mask = vec4(0.0);
	for (int i = 0; i < GADS_FIELD_LAYERS; i++) {
		mask[i] = i < layer_count ? 1.0 : 0.0;
	}
	w *= mask;
	float sum = w.x + w.y + w.z + w.w;
	displaceable = smoothstep(0.35, 0.65, sum);
	return sum > 1e-4 ? w / sum : vec4(1.0, 0.0, 0.0, 0.0) * mask.x;
}

float gads_field_fade(vec2 xz) {
	return 1.0 - smoothstep(amp_fade.x, amp_fade.y, distance(xz, field_camera.xz));
}

// The march's pass-through argument carries the layer weights here.
#define GADS_RELIEF(coord, lod, weights) gads_field_relief(coord, lod, weights)
#define GADS_RELIEF_ARG vec4
#include "res://addons/gads/render/shaders/gads_march.gdshaderinc"

// Linear steps: the surfaces' formula (gads_step_count) with the layers' steps scale.
int gads_field_step_count(float n_dot_v, float fade, vec4 w) {
	float scale = 0.0;
	for (int i = 0; i < GADS_FIELD_LAYERS; i++) {
		if (i < layer_count) {
			scale += w[i] * layer_e[i].y;
		}
	}
	float n = mix(gads_pom_steps.y, gads_pom_steps.x, clamp(n_dot_v, 0.0, 1.0)) * scale * fade;
	return clamp(int(ceil(n)), 1, GADS_MAX_STEPS);
}

vec3 gads_ring_color(int level) {
	if (level <= 0) {
		return vec3(1.0, 0.25, 0.2);
	} else if (level == 1) {
		return vec3(0.2, 0.9, 0.3);
	} else if (level == 2) {
		return vec3(0.25, 0.45, 1.0);
	}
	return vec3(1.0, 0.85, 0.2);
}

void vertex() {
	vec2 lattice = UV;
	float level = UV2.x;
	float flag = UV2.y;
	float spacing_units = exp2(level);
	vec2 xz0 = field_origin.xz + lattice * base_spacing;
	vec4 morph = level_morph[int(level + 0.5)];
	float m = clamp((distance(xz0, field_camera.xz) - morph.x) / max(morph.y - morph.x, 1e-4), 0.0, 1.0);
	if (flag > 1.5) {
		m = 0.0;
	} else if (flag > 0.5) {
		m = 1.0;
	}
	// Odd vertices of this ring slide onto their lower even neighbour (exact in lattice units).
	vec2 odd = mod(lattice / spacing_units, 2.0);
	vec2 lattice_m = lattice - odd * spacing_units * m;
	vec2 local_xz = lattice_m * base_spacing;
	vec2 xz = field_origin.xz + local_xz;
	// log2 of the metres between vertices: one level coarser at m = 1, as the next ring samples.
	float lod = log2(base_spacing) + (level + m);
	GADSGround g = gads_ground(xz);
	float displaceable;
	vec4 w = gads_field_weights(g.weights, displaceable);
	float ground = g.height;
	// The field's own fade towards its edge, times the parallax distance fade the materials use,
	// so the geometry never shows more relief than the parallax shading around it.
	float view_distance = distance(vec3(xz.x, ground, xz.y), field_camera);
	// The relief fades with distance; the runtime deformation does not (the ground around the field
	// shows it at every distance).
	float deform = gads_deformation(xz);
	// Before / after view: vertices left of the split keep to the ground.
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(local_xz.x, ground - field_origin.y, local_xz.y, 1.0));
	float split = clip.w > 0.0 ? gads_split(clip.x / clip.w * 0.5 + 0.5) : 1.0;
	float y = ground + lift + gads_field_fade(xz) * gads_fade(view_distance) * split * (gads_field_relief(xz, lod, w) + deform) - deform;
	y = mix(ground - push_down, y, displaceable);
	VERTEX = vec3(local_xz.x, y - field_origin.y, local_xz.y);
	f_base_normal = g.normal;
	NORMAL = f_base_normal;
	f_ground = ground;
	f_level = level + m;
	f_weights = w;
	f_displaceable = displaceable;
}

void fragment() {
	mat3 view_to_world = mat3(INV_VIEW_MATRIX);
	mat3 world_to_view = mat3(VIEW_MATRIX);
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 v = view_to_world * VIEW;
	vec3 n = normalize(f_base_normal);
	float displaceable = f_displaceable;
	vec4 w = f_weights;
	float pom_fade = gads_fade(length(VERTEX)) * gads_split(FRAGCOORD.x / VIEWPORT_SIZE.x);
	float amp = gads_field_amp(w) * pom_fade;
	// log2 of metres per pixel on the ground (uniform control flow). The footprint is taken on the
	// ground plane under the proxy: the view ray's point there is the same for every point of the
	// ray, so its derivatives are smooth across the proxy's bumps and silhouettes (the proxy's own
	// derivatives jump there and would blur the march and the textures), and equal the ground
	// material's around the field.
	vec2 plane_xz = wpos.xz - v.xz * (n.y / max(dot(n, v), GADS_MIN_NDOTV)) * (wpos.y - f_ground);
	vec2 dpdx = dFdx(plane_xz);
	vec2 dpdy = dFdy(plane_xz);
	float pix_m = max(length(dpdx), length(dpdy));
	float lod = log2(max(pix_m, 1e-6)) + gads_pom_range.z;
	int main_layer = 0;
	for (int i = 1; i < GADS_FIELD_LAYERS; i++) {
		if (i < layer_count && w[i] > w[main_layer]) {
			main_layer = i;
		}
	}
	vec2 xz_hit = wpos.xz;
	// Height of this fragment above the ground. The relief is measured from the ground itself, as
	// the ground material measures it: `lift` only raises the proxy geometry (so the ground mesh
	// cannot poke through), it does not shift the marched surface.
	float z_hit = wpos.y - f_ground;
	vec3 hit = wpos;
	float steps_used = 0.0;
#ifdef GADS_POM
	// March the full-resolution relief over the whole slab [0, amp] along the true view ray,
	// parameterised by the height z above the ground; the ray passes this fragment at z_hit.
	if (amp > 1e-5 && displaceable > 0.5 && lod + layer_e[main_layer].w < gads_pom_range.w && !IN_SHADOW_PASS) {
		float nv = max(dot(n, v), GADS_MIN_NDOTV);
		vec2 dxz_dz = v.xz * (n.y / nv);
		int steps = gads_field_step_count(dot(n, v), pom_fade, w);
		vec2 base_xz = wpos.xz - dxz_dz * z_hit;
		float z_proxy = z_hit;
		// The slab reaches down to the deepest runtime deformation (0 without one).
		z_hit = gads_march(base_xz, dxz_dz, amp, -max(gads_deform_params.w, 0.0), w * pom_fade, lod, steps, int(gads_pom_steps.z), xz_hit,
				steps_used);
		// The hit on the view ray (on sloped ground the ground height under xz_hit differs from
		// f_ground, so it is not rebuilt from xz_hit and z_hit).
		hit = wpos + v * ((z_hit - z_proxy) * n.y / nv);
	}
#endif
	if (layer_count > 1) {
		// The shading follows the height-aware blend at the hit, as the relief does.
		vec4 eff;
		gads_field_layers(xz_hit, lod, w, eff);
		w = eff;
	}
	vec3 albedo = vec3(0.0);
	vec3 orm = vec3(0.0);
	vec3 nsum = vec3(0.0);
	float spec = 0.0;
	for (int i = 0; i < GADS_FIELD_LAYERS; i++) {
		if (i >= layer_count || w[i] <= 0.001) {
			continue;
		}
		vec2 uv = gads_layer_uv(i, xz_hit);
		vec2 ddx = gads_layer_uv(i, wpos.xz + dpdx) - gads_layer_uv(i, wpos.xz);
		vec2 ddy = gads_layer_uv(i, wpos.xz + dpdy) - gads_layer_uv(i, wpos.xz);
		albedo += w[i] * GADS_LAYER_GRAD(layer_albedo, i, uv, ddx, ddy).rgb * layer_d[i].rgb;
		vec3 o = GADS_LAYER_GRAD(layer_orm, i, uv, ddx, ddy).rgb;
		orm += w[i] * vec3(mix(1.0, o.r, layer_c[i].z), o.g * layer_c[i].w, o.b * layer_d[i].a);
		vec3 right = vec3(layer_c[i].x, 0.0, -layer_c[i].y);
		vec3 image_up = -vec3(layer_c[i].y, 0.0, layer_c[i].x);
		nsum += w[i] * gads_apply_normal_map(GADS_LAYER_GRAD(layer_normal, i, uv, ddx, ddy).rgb, right, image_up, n, layer_a[i].w);
		spec += w[i] * layer_e[i].x;
	}
	float ao_out = orm.r;
	float roughness_out = clamp(orm.g, 0.0, 1.0);
	float metallic_out = clamp(orm.b, 0.0, 1.0);
	vec3 normal_world = normalize(nsum + n * 1e-6);
	// Surface effects: the layers' parameters blended by weight, the main layer's height.
	GADSEffects e;
	e.cover_color = vec4(0.0);
	e.cover = vec4(0.0);
	e.sharpness = 0.0;
	e.wetness = 0.0;
	e.puddle = 0.0;
	e.cavity = vec4(0.0);
	e.edge = vec4(0.0);
	float response = 0.0;
	float radius = 0.0;
	float effects_keep = 1.0; // how much relief detail (normal map, self-shadow) cover and water leave
	float wsum = 0.0;
	for (int i = 0; i < GADS_FIELD_LAYERS; i++) {
		if (i >= layer_count || w[i] <= 0.001) {
			continue;
		}
		wsum += w[i];
		e.cover_color += w[i] * layer_fx_cover_color[i];
		e.cover += w[i] * layer_fx_cover[i];
		e.wetness += w[i] * layer_fx_water[i].x;
		e.puddle += w[i] * layer_fx_water[i].y;
		response += w[i] * layer_fx_water[i].z;
		e.sharpness += w[i] * layer_fx_water[i].w;
		e.cavity += w[i] * layer_fx_cavity[i];
		e.edge += w[i] * layer_fx_edge[i];
		radius += w[i] * layer_fx_radius[i].x;
	}
	if (wsum > 0.0) {
		float inv = 1.0 / wsum;
		e.cover_color *= inv;
		e.cover *= inv;
		e.sharpness *= inv;
		e.wetness *= inv;
		e.puddle *= inv;
		e.cavity *= inv;
		e.edge *= inv;
		response *= inv;
		radius *= inv;
	}
	e.cover.x = max(e.cover.x, gads_weather.y * response);
	e.wetness = max(e.wetness, gads_weather.x * response);
	e.puddle = max(e.puddle, gads_weather.z * response);
	if (gads_effects_on(e)) {
		vec2 uv = gads_layer_uv(main_layer, xz_hit);
		float elod = max(lod + layer_e[main_layer].w, 0.0);
		vec2 remap = layer_a[main_layer].yz;
		float h = gads_remap_height(GADS_LAYER_LOD(layer_height, main_layer, uv, elod).r, remap);
		float around = e.cavity.a > 0.0 || e.edge.a > 0.0 ? gads_remap_height(GADS_LAYER_LOD(layer_height, main_layer, uv, elod + radius).r, remap) : h;
		gads_apply_effects(e, h, around, normalize(n).y, 1.0, albedo, roughness_out, metallic_out, ao_out, effects_keep);
		normal_world = normalize(mix(n, normal_world, effects_keep));
	}
	ALBEDO = albedo;
	AO = ao_out;
	ROUGHNESS = roughness_out;
	METALLIC = metallic_out;
	SPECULAR = spec;
	NORMAL = normalize(world_to_view * normal_world);
	vec3 offset_world = hit - wpos;
	LIGHT_VERTEX = VERTEX + world_to_view * offset_world;

#ifdef GADS_SELF_SHADOW
	{
		float in_range = 1.0 - smoothstep(0.8 * gads_shadow.y, gads_shadow.y, length(VERTEX));
		float strength = 0.0;
		for (int i = 0; i < GADS_FIELD_LAYERS; i++) {
			if (i < layer_count) {
				strength += w[i] * layer_e[i].z;
			}
		}
		// The shadow starts on the full relief (the true surface), not on the interpolated mesh.
		f_ss_xz = xz_hit;
		f_ss_z = steps_used > 0.0 ? z_hit : gads_field_relief(xz_hit, lod, w * pom_fade);
		f_ss_n = normalize(world_to_view * n);
		f_ss_x = world_to_view * vec3(1.0, 0.0, 0.0);
		f_ss_z_axis = world_to_view * vec3(0.0, 0.0, 1.0);
		f_ss_up = world_to_view * vec3(0.0, 1.0, 0.0);
		f_ss_weights = w * pom_fade;
		f_ss_params = vec4(lod, amp * displaceable, gads_shadow.w * strength * in_range * effects_keep, spec);
	}
#endif

	int debug_view = int(gads_debug.x + 0.5);
	if (debug_view == 5) {
		ALBEDO = vec3(1.0);
		SPECULAR = 0.0;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		AO = 1.0;
	} else if (debug_view == 10) {
		EMISSION += gads_split_line(FRAGCOORD.xy, VIEWPORT_SIZE);
	} else if (debug_view > 0) {
		vec3 debug_color = vec3(0.0);
		if (debug_view == 1) {
			debug_color = 0.5 + offset_world / (2.0 * max(gads_debug.y, 1e-6));
		} else if (debug_view == 2) {
			debug_color = vec3(steps_used / 64.0, 0.0, max(lod, 0.0) / 8.0);
		} else if (debug_view == 3) {
			debug_color = vec3(amp > 0.0 ? z_hit / amp : 0.0);
		} else if (debug_view == 4) {
			debug_color = normal_world * 0.5 + 0.5;
		} else if (debug_view == 6) {
			// World height of the (marched) surface point relative to gads_debug.z, in units of
			// gads_debug.y: the vertex height where no march runs, else the relief hit on the view
			// ray (tests read both exactly).
			debug_color = vec3((hit.y - gads_debug.z) / max(gads_debug.y, 1e-6), fract(f_level), f_level / 8.0);
		} else if (debug_view == 7) {
			debug_color = vec3(1.0);
		} else if (debug_view == 11) {
			debug_color = gads_heat(max(lod, 0.0) / 8.0);
		} else if (debug_view == 12) {
			debug_color = vec3(0.45) * (0.35 + 0.65 * normal_world.y);
		} else if (debug_view == 8) {
			// Rings: a colour per level (level + morph blends between them).
			int l0 = int(floor(f_level));
			debug_color = mix(gads_ring_color(l0), gads_ring_color(l0 + 1), fract(f_level)) * (0.35 + 0.65 * normal_world.y);
		}
		ALBEDO = vec3(0.0);
		SPECULAR = 0.0;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		AO = 1.0;
		EMISSION = debug_color;
	}
}

#ifdef GADS_SELF_SHADOW
// Height-field shadow towards light direction l (view space) over the full relief; hard or
// contact-hardening like the surface shaders (gads_core.gdshaderinc).
float gads_field_self_shadow(vec3 l) {
	float strength = f_ss_params.z;
	float amp = f_ss_params.y;
	if (strength <= 0.0 || amp <= 0.0) {
		return 1.0;
	}
	float n_dot_l = dot(f_ss_n, l);
	if (n_dot_l <= 0.0) {
		return 1.0;
	}
	float na = dot(f_ss_n, f_ss_up);
	vec2 dxz_dz = vec2(dot(f_ss_x, l), dot(f_ss_z_axis, l)) * (na / max(n_dot_l, GADS_MIN_NDOTV));
	float z_top = amp;
	if (f_ss_z >= z_top) {
		return 1.0;
	}
	int steps = clamp(int(gads_shadow.x), 1, GADS_MAX_SHADOW_STEPS);
	float dz = (z_top - f_ss_z) / float(steps);
	float metres_per_z = na / max(n_dot_l, GADS_MIN_NDOTV);
	float softness = gads_shadow.z;
	float bias = 0.01 * amp;
	float occlusion = 0.0;
	vec4 weights = f_ss_weights; // Varyings cannot be passed to functions from light().
	for (int i = 1; i <= GADS_MAX_SHADOW_STEPS; i++) {
		if (i > steps) {
			break;
		}
		float z = f_ss_z + dz * float(i);
		float relief = gads_field_relief(f_ss_xz + dxz_dz * (z - f_ss_z), f_ss_params.x, weights);
		float above = relief - z - bias;
		if (softness <= 0.0) {
			if (above > 0.0) {
				occlusion = 1.0;
				break;
			}
		} else {
			float distance_m = (z - f_ss_z) * metres_per_z;
			occlusion = max(occlusion, above * softness / max(distance_m, 1e-4));
		}
	}
	return mix(1.0, 1.0 - clamp(occlusion, 0.0, 1.0), strength);
}

void light() {
	// Debug view 5 shows the self-shadow factor alone (the fragment set a white, non-reflective
	// ALBEDO); `return` is not allowed in light(), hence the branches.
	bool shadow_view = int(gads_debug.x + 0.5) == 5;
	float attenuation = ATTENUATION;
	// Omni and spot lights only when the settings ask for it (gads_pom_steps.w): each one costs a
	// march on every pixel it lights. For them LIGHT points from the relief hit (LIGHT_VERTEX)
	// towards the light, which is the shadow ray. The debug view shows directional lights only.
	if (LIGHT_IS_DIRECTIONAL || gads_pom_steps.w > 0.5) {
		float self_shadow = gads_field_self_shadow(LIGHT);
		if (shadow_view && LIGHT_IS_DIRECTIONAL) {
			DIFFUSE_LIGHT += vec3(self_shadow);
		}
		attenuation *= self_shadow;
	}
	if (!shadow_view) {
		gads_brdf(NORMAL, LIGHT, VIEW, LIGHT_COLOR, attenuation, LIGHT_IS_DIRECTIONAL, ALBEDO, ROUGHNESS, METALLIC,
			f_ss_params.w, SPECULAR_AMOUNT, DIFFUSE_LIGHT, SPECULAR_LIGHT);
	}
}
#endif
