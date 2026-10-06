@tool
class_name GADSVisualShaderNodeTriplanarWeights
extends VisualShaderNodeCustom
## GADS Triplanar Weights: blend weights of the X, Y and Z projections for a world normal:
## |n|^sharpness, planes under 5 % dropped and the rest renormalised, as the GADS triplanar
## materials weigh them (so a floor samples one plane, a 45-degree roof two).


func _get_name() -> String:
	return "GADSTriplanarWeights"


func _get_category() -> String:
	return "GADS"


func _get_description() -> String:
	return "Triplanar projection weights with negligible planes dropped."


func _get_return_icon_type() -> PortType:
	return PORT_TYPE_VECTOR_3D


func _get_input_port_count() -> int:
	return 2


func _get_input_port_name(port: int) -> String:
	return ["normal_world", "sharpness"][port]


func _get_input_port_type(port: int) -> PortType:
	return [PORT_TYPE_VECTOR_3D, PORT_TYPE_SCALAR][port]


func _get_input_port_default_value(port: int) -> Variant:
	return [Vector3.UP, 4.0][port]


func _get_output_port_count() -> int:
	return 1


func _get_output_port_name(_port: int) -> String:
	return "weights"


func _get_output_port_type(_port: int) -> PortType:
	return PORT_TYPE_VECTOR_3D


func _get_global_code(_mode: Shader.Mode) -> String:
	return """
// GADS Triplanar Weights: |n|^sharpness, planes below 0.05 dropped, renormalised.
vec3 gads_vs_triplanar_weights(vec3 n, float sharpness) {
	vec3 w = pow(abs(n), vec3(sharpness));
	w /= max(w.x + w.y + w.z, 1e-6);
	w = mix(w, vec3(0.0), lessThan(w, vec3(0.05)));
	return w / max(w.x + w.y + w.z, 1e-6);
}
"""


func _get_code(input_vars: Array[String], output_vars: Array[String], _mode: Shader.Mode, _type: VisualShader.Type) -> String:
	return "%s = gads_vs_triplanar_weights(%s, %s);" % [output_vars[0], _arg(input_vars, 0, "vec3(0.0, 1.0, 0.0)"), _arg(input_vars, 1, "4.0")]


## input_vars[i], or [param fallback] (GLSL) when the port is not connected and has no value.
static func _arg(input_vars: Array[String], i: int, fallback: String) -> String:
	return input_vars[i] if i < input_vars.size() and not input_vars[i].is_empty() else fallback
