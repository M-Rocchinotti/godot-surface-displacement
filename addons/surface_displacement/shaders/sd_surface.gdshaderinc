// vertex(), fragment() and light() of the Surface Displacement surface shaders. The variants in
// shaders/variants/ are two lines each: their #defines, then this include. See sd_core.gdshaderinc
// for the defines and conventions.

#include "res://addons/surface_displacement/shaders/sd_core.gdshaderinc"

// After a march the hit uv jumps at relief edges, so textures are sampled with the rasterized
// uv's derivatives. Without a march (flat variants of UV and world mapping) the implicit
// derivatives are the same and texture() matches BaseMaterial3D bit for bit.
#if defined(SD_POM) || defined(SD_MAPPING_TRIPLANAR)
#define SD_SAMPLE(tex, uv, ddx, ddy) textureGrad(tex, uv, ddx, ddy)
#else
#define SD_SAMPLE(tex, uv, ddx, ddy) texture(tex, uv)
#endif

void vertex() {
	sd_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	sd_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
#ifdef SD_DEPTH_WRITE
	// Writing VERTEX (even unchanged) stops the engine from drawing this material's depth
	// pre-pass with its shared flat-depth material. The pre-pass must run this fragment() so it
	// writes the same relief depth that the colour pass then tests for EQUAL.
	VERTEX = VERTEX;
#endif
}

// Marches one projection. Frame space: view space for UV mapping, world space otherwise.
// Returns the hit's offset from the rasterized point (frame space) and writes its uv and height.
vec3 sd_resolve_plane(SDPlane p, vec3 n, vec3 v, float amp, float fade, float lod, out vec2 uv_hit,
		out float z_hit, inout float steps_used) {
	uv_hit = p.uv;
	z_hit = 0.0;
#ifdef SD_POM
	if (amp > 1e-5 && lod < sd_pom_range.w && !IN_SHADOW_PASS) {
		vec2 duv_dz = sd_duv_dz(p, n, v);
		float z_top = (1.0 - height_center) * amp;
		float z_bot = -height_center * amp;
		int steps = sd_step_count(dot(n, v), fade);
		z_hit = sd_march(p.uv, duv_dz, z_top, z_bot, amp, lod, steps, int(sd_pom_steps.z), uv_hit, steps_used);
	}
#endif
	// Moving z along the relief axis moves the ray point by z * (N.A) / (N.V) towards the camera.
	return v * (z_hit * dot(n, p.axis) / max(dot(n, v), SD_MIN_NDOTV));
}

void fragment() {
	float view_distance = length(VERTEX);
	mat3 view_to_world = mat3(INV_VIEW_MATRIX);
	mat3 world_to_view = mat3(VIEW_MATRIX);
	float fade = sd_fade(view_distance);
	float amp = height_m * fade;
	float steps_used = 0.0;
	float planes_marched = 0.0;
	vec3 offset_view = vec3(0.0);
	vec3 albedo_sum = vec3(0.0);
	vec3 orm_sum = vec3(0.0);
	vec3 normal_world = vec3(0.0, 1.0, 0.0);
	// The dominant plane (for self-shadowing and debug output).
	SDPlane main_plane;
	vec2 main_uv = vec2(0.0);
	float main_z = 0.0;
	float main_lod = 0.0;
	vec3 main_n = vec3(0.0, 1.0, 0.0);

#ifdef SD_MAPPING_UV
	// Frame space = view space. Gradients of u and v along the surface from screen-space
	// derivatives (cotangent frame): exact on every triangle, no tangent sign conventions.
	vec3 n = NORMAL;
	vec3 v = VIEW;
	SDPlane p;
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
	float lod = sd_march_lod(p);
	vec2 uv_hit;
	float z_hit;
	float amp_uv = inv_det != 0.0 ? amp : 0.0;
	offset_view = sd_resolve_plane(p, n, v, amp_uv, fade, lod, uv_hit, z_hit, steps_used);
	planes_marched = steps_used > 0.0 ? 1.0 : 0.0;
	albedo_sum = SD_SAMPLE(albedo_texture, uv_hit, p.ddx, p.ddy).rgb;
	orm_sum = SD_SAMPLE(orm_texture, uv_hit, p.ddx, p.ddy).rgb;
	NORMAL_MAP = SD_SAMPLE(normal_texture, uv_hit, p.ddx, p.ddy).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	normal_world = view_to_world * n;
	main_plane = p;
	main_uv = uv_hit;
	main_z = z_hit;
	main_lod = lod;
	main_n = n;
#endif

#ifdef SD_MAPPING_WORLD
	// Frame space = world space.
	vec3 n = normalize(sd_world_normal);
	vec3 v = view_to_world * VIEW;
	SDPlane p = sd_world_plane(sd_world_pos);
	// uv is linear in the world position, so its screen derivatives follow from the position's.
	vec3 dpdx = dFdx(sd_world_pos);
	vec3 dpdy = dFdy(sd_world_pos);
	p.ddx = vec2(dot(p.gu, dpdx), dot(p.gv, dpdx));
	p.ddy = vec2(dot(p.gu, dpdy), dot(p.gv, dpdy));
	float lod = sd_march_lod(p);
	vec2 uv_hit;
	float z_hit;
	vec3 offset_world = sd_resolve_plane(p, n, v, amp, fade, lod, uv_hit, z_hit, steps_used);
	planes_marched = steps_used > 0.0 ? 1.0 : 0.0;
	offset_view = world_to_view * offset_world;
	albedo_sum = SD_SAMPLE(albedo_texture, uv_hit, p.ddx, p.ddy).rgb;
	orm_sum = SD_SAMPLE(orm_texture, uv_hit, p.ddx, p.ddy).rgb;
	vec3 nm = SD_SAMPLE(normal_texture, uv_hit, p.ddx, p.ddy).rgb;
	normal_world = sd_apply_normal_map(nm, normalize(p.gu), -normalize(p.gv), n, normal_strength);
	NORMAL = normalize(world_to_view * normal_world);
	main_plane = p;
	main_uv = uv_hit;
	main_z = z_hit;
	main_lod = lod;
	main_n = n;
#endif

#ifdef SD_MAPPING_TRIPLANAR
	vec3 n = normalize(sd_world_normal);
	vec3 v = view_to_world * VIEW;
	vec3 w = sd_triplanar_weights(n);
	// Derivatives are taken here, in uniform control flow; each plane's uv is linear in the world
	// position, so its derivatives follow exactly from these (see the loop).
	vec3 dpdx = dFdx(sd_world_pos);
	vec3 dpdy = dFdy(sd_world_pos);
	vec3 offset_world = vec3(0.0);
	vec3 nsum = vec3(0.0);
	float main_w = -1.0;
	for (int axis_index = 0; axis_index < 3; axis_index++) {
		float wa = w[axis_index];
		if (wa <= 0.0) {
			continue; // Zero-weight planes are neither marched nor sampled.
		}
		SDPlane p = sd_triplanar_plane(sd_world_pos, n, axis_index, wa);
		p.ddx = vec2(dot(p.gu, dpdx), dot(p.gv, dpdx));
		p.ddy = vec2(dot(p.gu, dpdy), dot(p.gv, dpdy));
		float lod = sd_march_lod(p);
		vec2 uv_hit;
		float z_hit;
		float before = steps_used;
		offset_world += wa * sd_resolve_plane(p, n, v, amp, fade, lod, uv_hit, z_hit, steps_used);
		planes_marched += steps_used > before ? 1.0 : 0.0;
		albedo_sum += wa * SD_SAMPLE(albedo_texture, uv_hit, p.ddx, p.ddy).rgb;
		orm_sum += wa * SD_SAMPLE(orm_texture, uv_hit, p.ddx, p.ddy).rgb;
		vec3 nm = SD_SAMPLE(normal_texture, uv_hit, p.ddx, p.ddy).rgb;
		nsum += wa * sd_apply_normal_map(nm, normalize(p.gu), -normalize(p.gv), n, normal_strength);
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

	ALBEDO = albedo_sum * albedo_tint.rgb;
	AO = mix(1.0, orm_sum.r, ao_strength);
	ROUGHNESS = clamp(orm_sum.g * roughness_scale, 0.0, 1.0);
	METALLIC = clamp(orm_sum.b * metallic_scale, 0.0, 1.0);
	SPECULAR = specular;
#ifdef SD_POM
	LIGHT_VERTEX = VERTEX + offset_view;
#endif
#ifdef SD_DEPTH_WRITE
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

#ifdef SD_SELF_SHADOW
	{
#ifdef SD_MAPPING_UV
		mat3 to_view = mat3(1.0);
#else
		mat3 to_view = world_to_view;
#endif
		float in_range = 1.0 - smoothstep(0.8 * sd_shadow.y, sd_shadow.y, view_distance);
		sd_ss_uv = main_uv;
		sd_ss_z = main_z;
		sd_ss_gu = to_view * main_plane.gu;
		sd_ss_gv = to_view * main_plane.gv;
		sd_ss_n = normalize(to_view * main_n);
		sd_ss_axis = normalize(to_view * main_plane.axis);
		sd_ss_params = vec4(main_lod, steps_used > 0.0 ? amp : 0.0, height_center, sd_shadow.w * self_shadow_strength * in_range);
	}
#endif

	// Debug views (sd_debug.x): 1 = hit offset (world, 0.5 + offset / (2 * sd_debug.y)),
	// 2 = cost (steps / 64, planes marched / 3, LOD / 8), 3 = relief height in the slab,
	// 4 = world normal, 5 = self-shadow factor of directional lights (written by light()).
	// Output through EMISSION with black, non-reflective ALBEDO/SPECULAR; view 5 through a white,
	// non-reflective ALBEDO that light() fills.
	int debug_view = int(sd_debug.x + 0.5);
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
			debug_color = 0.5 + off_world / (2.0 * max(sd_debug.y, 1e-6));
		} else if (debug_view == 2) {
			debug_color = vec3(steps_used / 64.0, planes_marched / 3.0, main_lod / 8.0);
		} else if (debug_view == 3) {
			debug_color = vec3(amp > 0.0 ? main_z / amp + height_center : 0.0);
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

#ifdef SD_SELF_SHADOW
void light() {
	// Debug view 5 shows the self-shadow factor alone (the fragment set a white, non-reflective
	// ALBEDO); `return` is not allowed in light(), hence the branches.
	bool shadow_view = int(sd_debug.x + 0.5) == 5;
	float attenuation = ATTENUATION;
	// Omni and spot lights only when the settings ask for it (sd_pom_steps.w): each one costs a
	// march on every pixel it lights. For them LIGHT points from the relief hit (LIGHT_VERTEX)
	// towards the light, which is the shadow ray. The debug view shows directional lights only.
	if (LIGHT_IS_DIRECTIONAL || sd_pom_steps.w > 0.5) {
		float self_shadow = sd_self_shadow(LIGHT);
		if (shadow_view && LIGHT_IS_DIRECTIONAL) {
			DIFFUSE_LIGHT += vec3(self_shadow);
		}
		attenuation *= self_shadow;
	}
	if (!shadow_view) {
		sd_brdf(NORMAL, LIGHT, VIEW, LIGHT_COLOR, attenuation, LIGHT_IS_DIRECTIONAL, ALBEDO, ROUGHNESS, METALLIC,
			specular, SPECULAR_AMOUNT, DIFFUSE_LIGHT, SPECULAR_LIGHT);
	}
}
#endif
