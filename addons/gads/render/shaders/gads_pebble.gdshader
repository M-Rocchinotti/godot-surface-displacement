// GADSPebbleScatter3D pebbles: coloured by the ground layer they lie on (its albedo and roughness
// sampled at the pebble's position, with a per-pebble tint), a little darker where it meets the ground;
// covered and wetted like that layer (its cover and wetness, and the weather).
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#define GADS_FIELD_LAYERS 4

uniform sampler2DArray layer_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray layer_orm : filter_linear_mipmap, repeat_enable;
uniform vec4 layer_b[GADS_FIELD_LAYERS];
uniform vec4 layer_c[GADS_FIELD_LAYERS];
uniform vec4 layer_d[GADS_FIELD_LAYERS];
uniform vec4 layer_fx_cover_color[GADS_FIELD_LAYERS]; // cover colour rgb, cover roughness
uniform vec4 layer_fx_cover[GADS_FIELD_LAYERS];       // cover amount, slope from, slope to, height bias
uniform vec4 layer_fx_water[GADS_FIELD_LAYERS];       // wetness, puddle level, weather response, cover sharpness
uniform float albedo_lod = 4.0;
global uniform vec4 gads_weather; // rain wetness, snow cover, puddle level, unused

varying vec3 pebble_centre;
varying float local_height;
varying flat int pebble_layer;
varying float pebble_tint;

vec2 gads_layer_uv(int i, vec2 xz) {
	vec2 q = xz - layer_b[i].zw;
	vec2 cs = layer_c[i].xy;
	return vec2(cs.x * q.x - cs.y * q.y, cs.y * q.x + cs.x * q.y) * layer_b[i].xy;
}

void vertex() {
	pebble_centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	local_height = VERTEX.y;
	pebble_layer = clamp(int(INSTANCE_CUSTOM.x + 0.5), 0, GADS_FIELD_LAYERS - 1);
	pebble_tint = COLOR.r;
}

void fragment() {
	vec2 uv = gads_layer_uv(pebble_layer, pebble_centre.xz);
	// A sampler2DArray indexes dynamically on every renderer, so no per-layer branch is needed.
	vec3 albedo = textureLod(layer_albedo, vec3(uv, float(pebble_layer)), albedo_lod).rgb * layer_d[pebble_layer].rgb;
	vec3 orm = textureLod(layer_orm, vec3(uv, float(pebble_layer)), albedo_lod).rgb;
	// A few pixels wide, a pebble is shaded like the mip-mapped ground around it: its normals
	// bend towards the ground's (up) between 1 and 4 m. Otherwise its side facing the camera,
	// unlit when the sun is behind it, makes it a dark speck on the averaged, lit gravel.
	float far = smoothstep(1.0, 4.0, length(VERTEX));
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz, far));
	albedo = albedo * pebble_tint * mix(0.8, 1.0, smoothstep(-0.5, 0.3, local_height));
	float roughness = clamp(orm.g, 0.3, 1.0);
	// The layer's surface effects: a pebble is a top of the relief, so the cover's height bias
	// favours it as much as it can.
	vec4 water = layer_fx_water[pebble_layer];
	vec4 cover = layer_fx_cover[pebble_layer];
	float wet = max(water.x, gads_weather.x * water.z);
	float snow = max(cover.x, gads_weather.y * water.z);
	if (wet > 0.0) {
		albedo *= mix(1.0, 0.5, wet);
		roughness = mix(roughness, 0.25, wet);
	}
	if (snow > 0.0) {
		float up = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
		float facing = cover.z > cover.y ? smoothstep(cover.y, cover.z, up) : 1.0;
		float c = smoothstep(1.0 - snow, 1.0 - snow + 1.0 / max(water.w, 1.0), facing);
		albedo = mix(albedo, layer_fx_cover_color[pebble_layer].rgb, c);
		roughness = mix(roughness, layer_fx_cover_color[pebble_layer].a, c);
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	AO = mix(0.7, 1.0, smoothstep(-0.5, 0.2, local_height));
}
