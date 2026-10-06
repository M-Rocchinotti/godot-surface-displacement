// GADSPebbleScatter3D pebbles: coloured by the ground layer they lie on (its albedo and roughness
// sampled at the pebble's position, with a per-pebble tint), a little darker where it meets the ground.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#define GADS_FIELD_LAYERS 4

uniform sampler2D layer_albedo[GADS_FIELD_LAYERS] : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D layer_orm[GADS_FIELD_LAYERS] : filter_linear_mipmap, repeat_enable;
uniform vec4 layer_b[GADS_FIELD_LAYERS];
uniform vec4 layer_c[GADS_FIELD_LAYERS];
uniform vec4 layer_d[GADS_FIELD_LAYERS];
uniform float albedo_lod = 4.0;

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
	vec3 albedo = vec3(0.5);
	vec3 orm = vec3(1.0);
	// Constant index per draw is not guaranteed, so branch explicitly (with constant indices: the
	// Compatibility renderer indexes sampler arrays with nothing else).
	if (pebble_layer == 0) {
		albedo = textureLod(layer_albedo[0], uv, albedo_lod).rgb * layer_d[0].rgb;
		orm = textureLod(layer_orm[0], uv, albedo_lod).rgb;
	} else if (pebble_layer == 1) {
		albedo = textureLod(layer_albedo[1], uv, albedo_lod).rgb * layer_d[1].rgb;
		orm = textureLod(layer_orm[1], uv, albedo_lod).rgb;
	} else if (pebble_layer == 2) {
		albedo = textureLod(layer_albedo[2], uv, albedo_lod).rgb * layer_d[2].rgb;
		orm = textureLod(layer_orm[2], uv, albedo_lod).rgb;
	} else if (pebble_layer == 3) {
		albedo = textureLod(layer_albedo[3], uv, albedo_lod).rgb * layer_d[3].rgb;
		orm = textureLod(layer_orm[3], uv, albedo_lod).rgb;
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
