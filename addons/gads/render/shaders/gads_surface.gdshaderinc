// vertex(), fragment() and light() of the GADS surface shaders. The variants in
// render/shaders/variants/ are two lines each: their #defines, then this include. See gads_core.gdshaderinc
// for the defines and conventions.

#include "res://addons/gads/render/shaders/gads_core.gdshaderinc"

void vertex() {
	bool baked = gads_baked > 0.5;
	gads_geom_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	gads_world_pos = (MODEL_MATRIX * vec4(baked ? CUSTOM0.xyz : VERTEX, 1.0)).xyz;
	gads_world_normal = baked ? normalize(MODEL_NORMAL_MATRIX * CUSTOM1.xyz) : gads_geom_normal;
	gads_tess = baked ? vec2(CUSTOM1.w * 32.0, CUSTOM0.w) : vec2(0.0);
#ifdef GADS_LAYERED
	gads_layer_masks = vec2(gads_mask_channel(COLOR, layer1_mask_channel) * layer1_amount,
			gads_mask_channel(COLOR, layer2_mask_channel) * layer2_amount);
#endif
#ifdef GADS_DEPTH_WRITE
	// Writing VERTEX (even unchanged) stops the engine from drawing this material's depth
	// pre-pass with its shared flat-depth material. The pre-pass must run this fragment() so it
	// writes the same relief depth that the colour pass then tests for EQUAL.
	VERTEX = VERTEX;
#endif
}

// Marches one projection. Frame space: view space for UV mapping, world space otherwise.
// Returns the hit's offset from the rasterized point (frame space) and writes its uv and height.
vec3 gads_resolve_plane(GADSPlane p, vec3 n, vec3 v, GADS_RELIEF_ARG arg, float fade, float lod, out vec2 uv_hit,
		out float z_hit, inout float steps_used) {
	uv_hit = p.uv;
	z_hit = 0.0;
#ifdef GADS_POM
	if (gads_relief_amp(arg) > 1e-5 && lod < gads_pom_range.w && !IN_SHADOW_PASS) {
		vec2 duv_dz = gads_duv_dz(p, n, v);
		float z_top = gads_slab_top(arg);
		float z_bot = gads_slab_bottom(arg);
		int steps = gads_step_count(dot(n, v), fade);
		z_hit = gads_march(p.uv, duv_dz, z_top, z_bot, arg, lod, steps, int(gads_pom_steps.z), uv_hit, steps_used);
	}
#endif
	// Moving z along the relief axis moves the ray point by z * (N.A) / (N.V) towards the camera.
	return v * (z_hit * dot(n, p.axis) / max(dot(n, v), GADS_MIN_NDOTV));
}

void fragment() {
	float view_distance = length(VERTEX);
	mat3 view_to_world = mat3(INV_VIEW_MATRIX);
	mat3 world_to_view = mat3(VIEW_MATRIX);
	float fade = gads_fade(view_distance);
	// A baked mesh's geometry already carries the relief.
#ifdef GADS_LAYERED
	float up = normalize(gads_world_normal).y;
	GADS_RELIEF_ARG arg = vec3(gads_baked > 0.5 ? 0.0 : fade, gads_layer_masks.x * gads_slope_band(layer1_slope, up),
			gads_layer_masks.y * gads_slope_band(layer2_slope, up));
	// Masks for the texture blend, also on a baked mesh (whose relief scale is 0).
	GADS_RELIEF_ARG sample_arg = vec3(1.0, arg.yz);
#else
	GADS_RELIEF_ARG arg = gads_baked > 0.5 ? 0.0 : height_m * fade;
	GADS_RELIEF_ARG sample_arg = arg;
#endif
	float amp = gads_relief_amp(arg);
	float steps_used = 0.0;
	float planes_marched = 0.0;
	vec3 offset_view = vec3(0.0);
	vec3 albedo_sum = vec3(0.0);
	vec3 orm_sum = vec3(0.0);
	vec3 normal_world = vec3(0.0, 1.0, 0.0);
	// The dominant plane (for self-shadowing and debug output).
	GADSPlane main_plane;
	vec2 main_uv = vec2(0.0);
	float main_z = 0.0;
	float main_lod = 0.0;
	vec3 main_n = vec3(0.0, 1.0, 0.0);

#ifdef GADS_MAPPING_UV
	// Frame space = view space. Gradients of u and v along the surface from screen-space
	// derivatives (cotangent frame): exact on every triangle, no tangent sign conventions.
	vec3 n = NORMAL;
	vec3 v = VIEW;
	GADSPlane p;
	p.uv = UV * uv_scale + uv_offset;
	p.ddx = dFdx(p.uv);
	p.ddy = dFdy(p.uv);
	vec3 dp1 = dFdx(VERTEX);
	vec3 dp2 = dFdy(VERTEX);
	vec3 dp2perp = cross(dp2, n);
	vec3 dp1perp = cross(n, dp1);
	float det = dot(dp1, dp2perp);
	float inv_det = abs(det) > 1e-20 ? 1.0 / det : 0.0;
	p.gu = (dp2perp * p.ddx.x + dp1perp * p.ddy.x) * inv_det;
	p.gv = (dp2perp * p.ddx.y + dp1perp * p.ddy.y) * inv_det;
	p.axis = n;
	p.weight = 1.0;
	float lod = gads_march_lod(p);
	vec2 uv_hit;
	float z_hit;
	GADS_RELIEF_ARG arg_uv = inv_det != 0.0 ? arg : arg * 0.0;
	offset_view = gads_resolve_plane(p, n, v, arg_uv, fade, lod, uv_hit, z_hit, steps_used);
	planes_marched = steps_used > 0.0 ? 1.0 : 0.0;
	vec3 nm;
	gads_sample_surface(uv_hit, p.ddx, p.ddy, lod, sample_arg, albedo_sum, orm_sum, nm);
	if (gads_baked > 0.5) {
		nm = gads_detail_normal(nm, p, uv_hit, sample_arg);
	}
	nm = gads_add_detail_normal(nm, uv_hit, p.ddx, p.ddy);
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = gads_normal_strength();
	normal_world = view_to_world * n;
	main_plane = p;
	main_uv = uv_hit;
	main_z = z_hit;
	main_lod = lod;
	main_n = n;
#endif

#ifdef GADS_MAPPING_WORLD
	// Frame space = world space.
	vec3 n = normalize(gads_world_normal);
	vec3 v = view_to_world * VIEW;
	GADSPlane p = gads_world_plane(gads_world_pos);
	// uv is linear in the world position, so its screen derivatives follow from the position's.
	vec3 dpdx = dFdx(gads_world_pos);
	vec3 dpdy = dFdy(gads_world_pos);
	p.ddx = vec2(dot(p.gu, dpdx), dot(p.gv, dpdx));
	p.ddy = vec2(dot(p.gu, dpdy), dot(p.gv, dpdy));
	float lod = gads_march_lod(p);
	vec2 uv_hit;
	float z_hit;
	vec3 offset_world = gads_resolve_plane(p, n, v, arg, fade, lod, uv_hit, z_hit, steps_used);
	planes_marched = steps_used > 0.0 ? 1.0 : 0.0;
	offset_view = world_to_view * offset_world;
	vec3 nm;
	gads_sample_surface(uv_hit, p.ddx, p.ddy, lod, sample_arg, albedo_sum, orm_sum, nm);
	if (gads_baked > 0.5) {
		nm = gads_detail_normal(nm, p, uv_hit, sample_arg);
	}
	nm = gads_add_detail_normal(nm, uv_hit, p.ddx, p.ddy);
	normal_world = gads_apply_normal_map(nm, normalize(p.gu), -normalize(p.gv), normalize(gads_geom_normal), gads_normal_strength());
	NORMAL = normalize(world_to_view * normal_world);
	main_plane = p;
	main_uv = uv_hit;
	main_z = z_hit;
	main_lod = lod;
	main_n = n;
#endif

#ifdef GADS_MAPPING_TRIPLANAR
	vec3 n = normalize(gads_world_normal);
	vec3 v = view_to_world * VIEW;
	vec3 w = gads_triplanar_weights(n);
	// Derivatives are taken here, in uniform control flow; each plane's uv is linear in the world
	// position, so its derivatives follow exactly from these (see the loop).
	vec3 dpdx = dFdx(gads_world_pos);
	vec3 dpdy = dFdy(gads_world_pos);
	vec3 offset_world = vec3(0.0);
	vec3 nsum = vec3(0.0);
	float main_w = -1.0;
	for (int axis_index = 0; axis_index < 3; axis_index++) {
		float wa = w[axis_index];
		if (wa <= 0.0) {
			continue; // Zero-weight planes are neither marched nor sampled.
		}
		GADSPlane p = gads_triplanar_plane(gads_world_pos, n, axis_index, wa);
		p.ddx = vec2(dot(p.gu, dpdx), dot(p.gv, dpdx));
		p.ddy = vec2(dot(p.gu, dpdy), dot(p.gv, dpdy));
		float lod = gads_march_lod(p);
		vec2 uv_hit;
		float z_hit;
		float before = steps_used;
		offset_world += wa * gads_resolve_plane(p, n, v, arg, fade, lod, uv_hit, z_hit, steps_used);
		planes_marched += steps_used > before ? 1.0 : 0.0;
		vec3 albedo_p;
		vec3 orm_p;
		vec3 nm;
		gads_sample_surface(uv_hit, p.ddx, p.ddy, lod, sample_arg, albedo_p, orm_p, nm);
		albedo_sum += wa * albedo_p;
		orm_sum += wa * orm_p;
		if (gads_baked > 0.5) {
			nm = gads_detail_normal(nm, p, uv_hit, sample_arg);
		}
		nm = gads_add_detail_normal(nm, uv_hit, p.ddx, p.ddy);
		nsum += wa * gads_apply_normal_map(nm, normalize(p.gu), -normalize(p.gv), normalize(gads_geom_normal), gads_normal_strength());
		if (wa > main_w) {
			main_w = wa;
			main_plane = p;
			main_uv = uv_hit;
			main_z = z_hit;
			main_lod = lod;
		}
	}
	main_n = n;
	normal_world = normalize(nsum);
	NORMAL = normalize(world_to_view * normal_world);
	offset_view = world_to_view * offset_world;
#endif

#ifdef GADS_LAYERED
	ALBEDO = albedo_sum; // Each layer's tint is applied in gads_sample_surface().
#else
	ALBEDO = albedo_sum * albedo_tint.rgb;
#endif
	AO = mix(1.0, orm_sum.r, ao_strength);
	ROUGHNESS = clamp(orm_sum.g * roughness_scale, 0.0, 1.0);
	METALLIC = clamp(orm_sum.b * metallic_scale, 0.0, 1.0);
	SPECULAR = specular;
#ifdef GADS_POM
	LIGHT_VERTEX = VERTEX + offset_view;
#endif
#ifdef GADS_DEPTH_WRITE
	// With the depth pre-pass on, the colour pass keeps a fragment only if its depth EQUALS the
	// pre-pass depth, and the two passes are separately compiled shaders whose arithmetic can
	// differ in the last bit (1.3 % of the pixels in the depth test). Rounding the depth to 12
	// mantissa bits (0.25 mm at 2 m) makes the two agree except where a value falls right on a
	// rounding step: a few pixels per million (README, Limitations).
	vec4 clip = PROJECTION_MATRIX * vec4(VERTEX + offset_view, 1.0);
	float depth = clip.z / clip.w;
	float depth_step = exp2(floor(log2(max(depth, 1e-30))) - 12.0);
	DEPTH = round(depth / depth_step) * depth_step;
	if (IN_SHADOW_PASS) {
		// Shadow maps get the rasterized depth: the march does not run there (no offset), and
		// the rounding would only quantize the caster (by centimetres over a long cascade).
		DEPTH = FRAGCOORD.z;
	}
#endif

#ifdef GADS_SELF_SHADOW
	{
#ifdef GADS_MAPPING_UV
		mat3 to_view = mat3(1.0);
#else
		mat3 to_view = world_to_view;
#endif
		float in_range = 1.0 - smoothstep(0.8 * gads_shadow.y, gads_shadow.y, view_distance);
		gads_ss_uv = main_uv;
		gads_ss_z = main_z;
		gads_ss_gu = to_view * main_plane.gu;
		gads_ss_gv = to_view * main_plane.gv;
		gads_ss_n = normalize(to_view * main_n);
		gads_ss_axis = normalize(to_view * main_plane.axis);
		gads_ss_params = vec4(main_lod, steps_used > 0.0 ? amp : 0.0, height_center, gads_shadow.w * self_shadow_strength * in_range);
#ifdef GADS_LAYERED
		gads_ss_arg = arg;
#endif
	}
#endif

	// Debug views (gads_debug.x): 1 = hit offset (world, 0.5 + offset / (2 * gads_debug.y)),
	// 2 = cost (steps / 64, planes marched / 3, LOD / 8), 3 = relief height in the slab,
	// 4 = world normal, 5 = self-shadow factor of directional lights (written by light()),
	// 9 = tessellation of a baked mesh (refinement level: blue 0, green 8, yellow 16, red 24+).
	// Output through EMISSION with black, non-reflective ALBEDO/SPECULAR; view 5 through a white,
	// non-reflective ALBEDO that light() fills.
	int debug_view = int(gads_debug.x + 0.5);
	if (debug_view == 5) {
		ALBEDO = vec3(1.0);
		SPECULAR = 0.0;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		AO = 1.0;
	} else if (debug_view > 0) {
		vec3 off_world = view_to_world * offset_view;
		vec3 debug_color = vec3(0.0);
		if (debug_view == 1) {
			debug_color = 0.5 + off_world / (2.0 * max(gads_debug.y, 1e-6));
		} else if (debug_view == 2) {
			debug_color = vec3(steps_used / 64.0, planes_marched / 3.0, max(main_lod, 0.0) / 8.0);
		} else if (debug_view == 3) {
			debug_color = vec3(amp > 0.0 ? main_z / amp + height_center : 0.0);
		} else if (debug_view == 9) {
			float t = clamp(gads_tess.x / 24.0, 0.0, 1.0) * 3.0;
			debug_color = t < 1.0 ? mix(vec3(0.1, 0.25, 1.0), vec3(0.1, 0.9, 0.2), t)
					: t < 2.0 ? mix(vec3(0.1, 0.9, 0.2), vec3(1.0, 0.9, 0.1), t - 1.0)
					: mix(vec3(1.0, 0.9, 0.1), vec3(1.0, 0.15, 0.1), t - 2.0);
		} else {
			debug_color = normal_world * 0.5 + 0.5;
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
void light() {
	// Debug view 5 shows the self-shadow factor alone (the fragment set a white, non-reflective
	// ALBEDO); `return` is not allowed in light(), hence the branches.
	bool shadow_view = int(gads_debug.x + 0.5) == 5;
	float attenuation = ATTENUATION;
	// Omni and spot lights only when the settings ask for it (gads_pom_steps.w): each one costs a
	// march on every pixel it lights. For them LIGHT points from the relief hit (LIGHT_VERTEX)
	// towards the light, which is the shadow ray. The debug view shows directional lights only.
	if (LIGHT_IS_DIRECTIONAL || gads_pom_steps.w > 0.5) {
		float self_shadow = gads_self_shadow(LIGHT);
		if (shadow_view && LIGHT_IS_DIRECTIONAL) {
			DIFFUSE_LIGHT += vec3(self_shadow);
		}
		attenuation *= self_shadow;
	}
	if (!shadow_view) {
		gads_brdf(NORMAL, LIGHT, VIEW, LIGHT_COLOR, attenuation, LIGHT_IS_DIRECTIONAL, ALBEDO, ROUGHNESS, METALLIC,
			specular, SPECULAR_AMOUNT, DIFFUSE_LIGHT, SPECULAR_LIGHT);
	}
}
#endif
