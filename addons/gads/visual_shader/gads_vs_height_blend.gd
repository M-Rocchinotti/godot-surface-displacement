@tool
class_name GADSVisualShaderNodeHeightBlend
extends VisualShaderNodeCustom
## GADS Height Blend: the weight of a layer of height [code]above[/code] over a layer of height
## [code]below[/code] for a mask [code]mask[/code] (0..1): 0 at mask 0, 1 at mask 1, in between
## the higher relief wins (stones show through sand before it covers them), with a transition
## [code]width[/code] high. The layered GADS materials blend this way.


func _get_name() -> String:
	return "GADSHeightBlend"


func _get_category() -> String:
	return "GADS"


func _get_description() -> String:
	return "Height-aware blend weight of a layer over the one below, for a mask."


func _get_return_icon_type() -> PortType:
	return PORT_TYPE_SCALAR


func _get_input_port_count() -> int:
	return 4


func _get_input_port_name(port: int) -> String:
	return ["below", "above", "mask", "width"][port]


func _get_input_port_type(_port: int) -> PortType:
	return PORT_TYPE_SCALAR


func _get_input_port_default_value(port: int) -> Variant:
	return [0.5, 0.5, 0.5, 0.1][port]


func _get_output_port_count() -> int:
	return 1


func _get_output_port_name(_port: int) -> String:
	return "weight"


func _get_output_port_type(_port: int) -> PortType:
	return PORT_TYPE_SCALAR


func _get_global_code(_mode: Shader.Mode) -> String:
	return """
// GADS Height Blend: weight of a layer of height `above` over `below` for mask m.
float gads_vs_height_blend(float below, float above, float m, float width) {
	if (m <= 0.0) {
		return 0.0;
	}
	if (m >= 1.0) {
		return 1.0;
	}
	return smoothstep(-width, width, above - below + (2.0 * m - 1.0) * (1.0 + width));
}
"""


func _get_code(input_vars: Array[String], output_vars: Array[String], _mode: Shader.Mode, _type: VisualShader.Type) -> String:
	return "%s = gads_vs_height_blend(%s, %s, %s, max(%s, 1e-4));" % [output_vars[0], _arg(input_vars, 0, "0.5"), _arg(input_vars, 1, "0.5"),
		_arg(input_vars, 2, "0.5"), _arg(input_vars, 3, "0.1")]


## input_vars[i], or [param fallback] (GLSL) when the port is not connected and has no value.
static func _arg(input_vars: Array[String], i: int, fallback: String) -> String:
	return input_vars[i] if i < input_vars.size() and not input_vars[i].is_empty() else fallback
