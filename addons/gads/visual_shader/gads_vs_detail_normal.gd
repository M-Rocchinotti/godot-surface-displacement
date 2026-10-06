@tool
class_name GADSVisualShaderNodeDetailNormal
extends VisualShaderNodeCustom
## GADS Detail Normal: a detail normal map on top of a base one by Reoriented Normal Mapping
## (Barre-Brisebois and Hill 2012), both as packed samples (0..1, OpenGL convention), the detail
## scaled by [code]strength[/code]. The result is packed too: connect it to NORMAL_MAP.


func _get_name() -> String:
	return "GADSDetailNormal"


func _get_category() -> String:
	return "GADS"


func _get_description() -> String:
	return "Reoriented Normal Mapping of a detail normal map onto a base normal map."


func _get_return_icon_type() -> PortType:
	return PORT_TYPE_VECTOR_3D


func _get_input_port_count() -> int:
	return 3


func _get_input_port_name(port: int) -> String:
	return ["base", "detail", "strength"][port]


func _get_input_port_type(port: int) -> PortType:
	return [PORT_TYPE_VECTOR_3D, PORT_TYPE_VECTOR_3D, PORT_TYPE_SCALAR][port]


func _get_input_port_default_value(port: int) -> Variant:
	return [Vector3(0.5, 0.5, 1.0), Vector3(0.5, 0.5, 1.0), 1.0][port]


func _get_output_port_count() -> int:
	return 1


func _get_output_port_name(_port: int) -> String:
	return "normal_map"


func _get_output_port_type(_port: int) -> PortType:
	return PORT_TYPE_VECTOR_3D


func _get_global_code(_mode: Shader.Mode) -> String:
	return """
// GADS Detail Normal: Reoriented Normal Mapping of packed samples.
vec3 gads_vs_detail_normal(vec3 base_rgb, vec3 detail_rgb, float strength) {
	vec3 b = base_rgb * 2.0 - 1.0;
	b.z = sqrt(max(0.0, 1.0 - dot(b.xy, b.xy)));
	vec2 dxy = (detail_rgb.xy * 2.0 - 1.0) * strength;
	vec3 d = normalize(vec3(dxy, sqrt(max(0.0, 1.0 - min(dot(dxy, dxy), 0.9999)))));
	vec3 t = vec3(b.xy, b.z + 1.0);
	vec3 u = vec3(-d.xy, d.z);
	return normalize(t * dot(t, u) / t.z - u) * 0.5 + 0.5;
}
"""


func _get_code(input_vars: Array[String], output_vars: Array[String], _mode: Shader.Mode, _type: VisualShader.Type) -> String:
	return "%s = gads_vs_detail_normal(%s, %s, %s);" % [output_vars[0], _arg(input_vars, 0, "vec3(0.5, 0.5, 1.0)"),
		_arg(input_vars, 1, "vec3(0.5, 0.5, 1.0)"), _arg(input_vars, 2, "1.0")]


## input_vars[i], or [param fallback] (GLSL) when the port is not connected and has no value.
static func _arg(input_vars: Array[String], i: int, fallback: String) -> String:
	return input_vars[i] if i < input_vars.size() and not input_vars[i].is_empty() else fallback
