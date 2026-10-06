@tool
class_name GADSVisualShaderNodeCavity
extends VisualShaderNodeCustom
## GADS Cavity: where a height map's relief lies below its surroundings (cavity: cracks,
## hollows; dirt, moss, wetness) or above them (edge: crests; wear, dust-free edges), from the
## height at the pixel against the height averaged over 2^radius texels around (a coarser mip).
## Both 0..1.


func _get_name() -> String:
	return "GADSCavity"


func _get_category() -> String:
	return "GADS"


func _get_description() -> String:
	return "Cavity and edge masks of a height map (height against its surroundings)."


func _get_return_icon_type() -> PortType:
	return PORT_TYPE_SCALAR


func _get_input_port_count() -> int:
	return 4


func _get_input_port_name(port: int) -> String:
	return ["height_map", "uv", "radius", "contrast"][port]


func _get_input_port_type(port: int) -> PortType:
	return [PORT_TYPE_SAMPLER, PORT_TYPE_VECTOR_2D, PORT_TYPE_SCALAR, PORT_TYPE_SCALAR][port]


func _get_input_port_default_value(port: int) -> Variant:
	return [null, Vector2.ZERO, 3.0, 5.0][port]


func _is_input_port_default(port: int, _mode: Shader.Mode) -> bool:
	return port == 1


func _get_output_port_count() -> int:
	return 2


func _get_output_port_name(port: int) -> String:
	return ["cavity", "edge"][port]


func _get_output_port_type(_port: int) -> PortType:
	return PORT_TYPE_SCALAR


func _is_available(_mode: Shader.Mode, type: VisualShader.Type) -> bool:
	return type == VisualShader.TYPE_FRAGMENT


func _get_global_code(_mode: Shader.Mode) -> String:
	return """
// GADS Cavity: height against its surroundings (a mip `radius` levels coarser).
void gads_vs_cavity(sampler2D tex, vec2 uv, float radius, float contrast, out float cavity, out float edge) {
	vec2 ddx = dFdx(uv);
	vec2 ddy = dFdy(uv);
	float s = exp2(max(radius, 0.0));
	float d = textureGrad(tex, uv, ddx, ddy).r - textureGrad(tex, uv, ddx * s, ddy * s).r;
	cavity = clamp(-d * contrast, 0.0, 1.0);
	edge = clamp(d * contrast, 0.0, 1.0);
}
"""


func _get_code(input_vars: Array[String], output_vars: Array[String], _mode: Shader.Mode, _type: VisualShader.Type) -> String:
	if input_vars[0].is_empty():
		return "%s = 0.0;\n%s = 0.0;" % [output_vars[0], output_vars[1]]
	return "gads_vs_cavity(%s, %s, %s, %s, %s, %s);" % [input_vars[0], _arg(input_vars, 1, "UV"), _arg(input_vars, 2, "3.0"), _arg(input_vars, 3, "5.0"),
		output_vars[0], output_vars[1]]


## input_vars[i], or [param fallback] (GLSL) when the port is not connected and has no value.
static func _arg(input_vars: Array[String], i: int, fallback: String) -> String:
	return input_vars[i] if i < input_vars.size() and not input_vars[i].is_empty() else fallback
