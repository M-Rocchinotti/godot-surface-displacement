@tool
class_name GADSVisualShaderNodeSlopeMask
extends VisualShaderNodeCustom
## GADS Slope Mask: how much the surface faces up, as a smooth band: 0 where the world normal's
## y is below [code]from[/code], 1 above [code]to[/code] (0.6 .. 0.85: tops of stones and level
## ground; snow, moss, dust). From the shaded normal (normal maps included when NORMAL is set
## before), fragment only.


func _get_name() -> String:
	return "GADSSlopeMask"


func _get_category() -> String:
	return "GADS"


func _get_description() -> String:
	return "Smooth band of how much the surface faces up (world normal y)."


func _get_return_icon_type() -> PortType:
	return PORT_TYPE_SCALAR


func _get_input_port_count() -> int:
	return 2


func _get_input_port_name(port: int) -> String:
	return ["from", "to"][port]


func _get_input_port_type(_port: int) -> PortType:
	return PORT_TYPE_SCALAR


func _get_input_port_default_value(port: int) -> Variant:
	return [0.6, 0.85][port]


func _get_output_port_count() -> int:
	return 1


func _get_output_port_name(_port: int) -> String:
	return "mask"


func _get_output_port_type(_port: int) -> PortType:
	return PORT_TYPE_SCALAR


func _is_available(mode: Shader.Mode, type: VisualShader.Type) -> bool:
	return mode == Shader.MODE_SPATIAL and type == VisualShader.TYPE_FRAGMENT


func _get_code(input_vars: Array[String], output_vars: Array[String], _mode: Shader.Mode, _type: VisualShader.Type) -> String:
	var from := _arg(input_vars, 0, "0.6")
	return "%s = smoothstep(%s, max(%s, %s + 1e-4), normalize(mat3(INV_VIEW_MATRIX) * NORMAL).y);" % [
		output_vars[0], from, _arg(input_vars, 1, "0.85"), from]


## input_vars[i], or [param fallback] (GLSL) when the port is not connected and has no value.
static func _arg(input_vars: Array[String], i: int, fallback: String) -> String:
	return input_vars[i] if i < input_vars.size() and not input_vars[i].is_empty() else fallback
