// PebbleScatter3D pebbles: coloured by the ground layer they lie on (its albedo and roughness
// sampled at the pebble's position, with a per-pebble tint), a little darker where it meets the ground.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#define SD_FIELD_LAYERS 4

uniform sampler2D layer_albedo[SD_FIELD_LAYERS] : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_orm[SD_FIELD_LAYERS] : filter_linear_mipmap, repeat_enable;
uniform vec4 layer_b[SD_FIELD_LAYERS];
uniform vec4 layer_c[SD_FIELD_LAYERS];
uniform vec4 layer_d[SD_FIELD_LAYERS];
uniform float albedo_lod = 4.0;

varying vec3 pebble_centre;
varying float local_height;
varying flat int pebble_layer;
varying float pebble_tint;

vec2 sd_layer_uv(int i, vec2 xz) {
	vec2 q = xz - layer_b[i].zw;
	vec2 cs = layer_c[i].xy;
	return vec2(cs.x * q.x - cs.y * q.y, cs.y * q.x + cs.x * q.y) * layer_b[i].xy;
}

void vertex() {
	pebble_centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	local_height = VERTEX.y;
	pebble_layer = clamp(int(INSTANCE_CUSTOM.x + 0.5), 0, SD_FIELD_LAYERS - 1);
	pebble_tint = COLOR.r;
}

void fragment() {
	vec2 uv = sd_layer_uv(pebble_layer, pebble_centre.xz);
	vec3 albedo = vec3(0.5);
	vec3 orm = vec3(1.0);
	// Constant index per draw is not guaranteed, so branch explicitly.
	for (int i = 0; i < SD_FIELD_LAYERS; i++) {
		if (i == pebble_layer) {
			albedo = textureLod(layer_albedo[i], uv, albedo_lod).rgb * layer_d[i].rgb;
			orm = textureLod(layer_orm[i], uv, albedo_lod).rgb;
		}
	}
	// A few pixels wide, a pebble is shaded like the mip-mapped ground around it: its normals
	// bend towards the ground's (up) between 1 and 4 m. Otherwise its side facing the camera,
	// unlit when the sun is behind it, makes it a dark speck on the averaged, lit gravel.
	float far = smoothstep(1.0, 4.0, length(VERTEX));
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz, far));
	ALBEDO = albedo * pebble_tint * mix(0.8, 1.0, smoothstep(-0.5, 0.3, local_height));
	ROUGHNESS = clamp(orm.g, 0.3, 1.0);
	AO = mix(0.7, 1.0, smoothstep(-0.5, 0.2, local_height));
}
