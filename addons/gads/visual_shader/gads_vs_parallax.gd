@tool
class_name GADSVisualShaderNodeParallax
extends VisualShaderNodeCustom
## GADS Parallax UV: parallax occlusion mapping in a visual shader (spatial, fragment). Marches
## the height map (red channel, 1 = top) from the rasterized uv along the view ray, through a
## relief [code]depth_m[/code] metres deep below the surface, and returns the uv where the ray
## hits it and the height there. Sample the other textures at that uv. The march uses the same
## cotangent frame as the GADS materials (no tangents needed), more steps at grazing angles, and
## a secant step at the end.


func _get_name() -> String:
	return "GADSParallaxUV"


func _get_category() -> String:
	return "GADS"


func _get_description() -> String:
	return "Parallax occlusion mapping: the uv where the view ray hits the height map's relief, and the height there."


func _get_return_icon_type() -> PortType:
	return PORT_TYPE_VECTOR_2D


func _get_input_port_count() -> int:
	return 5


func _get_input_port_name(port: int) -> String:
	return ["height_map", "uv", "depth_m", "min_steps", "max_steps"][port]


func _get_input_port_type(port: int) -> PortType:
	return [PORT_TYPE_SAMPLER, PORT_TYPE_VECTOR_2D, PORT_TYPE_SCALAR, PORT_TYPE_SCALAR, PORT_TYPE_SCALAR][port]


func _get_input_port_default_value(port: int) -> Variant:
	return [null, Vector2.ZERO, 0.03, 8.0, 24.0][port]


func _is_input_port_default(port: int, _mode: Shader.Mode) -> bool:
	return port == 1 # uv: the mesh's UV when not connected


func _get_output_port_count() -> int:
	return 2


func _get_output_port_name(port: int) -> String:
	return ["uv", "height"][port]


func _get_output_port_type(port: int) -> PortType:
	return [PORT_TYPE_VECTOR_2D, PORT_TYPE_SCALAR][port]


func _is_available(mode: Shader.Mode, type: VisualShader.Type) -> bool:
	return mode == Shader.MODE_SPATIAL and type == VisualShader.TYPE_FRAGMENT


func _get_global_code(_mode: Shader.Mode) -> String:
	return """
// GADS Parallax UV: the uv where the view ray meets the relief of `tex` (1 = top at the surface,
// 0 = depth metres below), from the rasterized uv; frame from screen-space derivatives.
void gads_vs_parallax(sampler2D tex, vec2 uv, float depth, float min_steps, float max_steps, vec3 vertex, vec3 n,
		vec3 view, out vec2 uv_out, out float h_out) {
	vec2 ddx = dFdx(uv);
	vec2 ddy = dFdy(uv);
	vec3 dp1 = dFdx(vertex);
	vec3 dp2 = dFdy(vertex);
	vec3 dp2perp = cross(dp2, n);
	vec3 dp1perp = cross(n, dp1);
	float det = dot(dp1, dp2perp);
	float inv_det = abs(det) > 1e-20 ? 1.0 / det : 0.0;
	vec3 gu = (dp2perp * ddx.x + dp1perp * ddy.x) * inv_det;
	vec3 gv = (dp2perp * ddx.y + dp1perp * ddy.y) * inv_det;
	float nv = max(dot(n, view), 1e-3);
	// uv at relief height z (m, negative below the surface) along the ray.
	vec2 duv_dz = vec2(dot(gu, view), dot(gv, view)) / nv;
	int steps = int(clamp(mix(max_steps, min_steps, nv), 1.0, 128.0));
	float dz = depth / float(steps);
	float z = 0.0;
	float prev_gap = 0.0;
	float gap = 0.0;
	vec2 hit = uv;
	for (int i = 0; i <= steps; i++) {
		hit = uv + duv_dz * z;
		float surface = depth * (textureGrad(tex, hit, ddx, ddy).r - 1.0);
		gap = z - surface; // > 0 while the ray is above the relief
		if (gap <= 0.0) {
			break;
		}
		prev_gap = gap;
		z -= dz;
	}
	if (gap <= 0.0 && z < 0.0) {
		// Secant step between the last point above and the first below.
		float t = prev_gap / max(prev_gap - gap, 1e-6);
		z = z + dz * (1.0 - t);
		hit = uv + duv_dz * z;
	}
	uv_out = hit;
	h_out = textureGrad(tex, hit, ddx, ddy).r;
}
"""


func _get_code(input_vars: Array[String], output_vars: Array[String], _mode: Shader.Mode, _type: VisualShader.Type) -> String:
	var uv := _arg(input_vars, 1, "UV")
	if input_vars[0].is_empty():
		return "%s = %s;\n%s = 1.0;" % [output_vars[0], uv, output_vars[1]]
	return "gads_vs_parallax(%s, %s, %s, %s, %s, VERTEX, NORMAL, VIEW, %s, %s);" % [
		input_vars[0], uv, _arg(input_vars, 2, "0.03"), _arg(input_vars, 3, "8.0"), _arg(input_vars, 4, "24.0"), output_vars[0], output_vars[1]]


## input_vars[i], or [param fallback] (GLSL) when the port is not connected and has no value.
static func _arg(input_vars: Array[String], i: int, fallback: String) -> String:
	return input_vars[i] if i < input_vars.size() and not input_vars[i].is_empty() else fallback
