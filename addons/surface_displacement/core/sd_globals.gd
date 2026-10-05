@tool
class_name SDGlobals
extends RefCounted
## The global shader uniforms that every Surface Displacement shader reads. The editor plugin
## registers them in Project Settings > Shader Globals (so they are saved in project.godot and
## exported with the game); [method ensure_registered] also adds them to a running
## RenderingServer, so shaders compile without an editor restart.
##
## [code]sd_pom_steps[/code]  x: minimum linear steps (straight-on view), y: maximum linear steps
##     (grazing view), z: bisection steps after the linear search, w: 1 = omni and spot lights
##     self-shadow the relief too (0 = only directional lights do).
## [code]sd_pom_range[/code]  x: distance where the relief starts fading (m), y: distance where it
##     is gone (m), z: LOD bias of the march's height samples, w: the height-map mip level at and
##     beyond which the march is skipped (the relief is below a pixel there).
## [code]sd_shadow[/code]  x: self-shadow steps, y: maximum distance (m), z: softness (0 = hard,
##     k > 0 = contact-hardening), w: strength (0 = off).
## [code]sd_debug[/code]  x: debug view (0 = off), y: scale in metres (hit offset, world height),
##     z: reference height in metres of the field's world-height view (tests), w: unused.
## [code]sd_dfg[/code]  the multiple-scattering term of Godot's BRDF (tools/make_dfg_lut.py).

const POM_STEPS := &"sd_pom_steps"
const POM_RANGE := &"sd_pom_range"
const SHADOW := &"sd_shadow"
const DEBUG := &"sd_debug"
const DFG := &"sd_dfg"
const DFG_PATH := "res://addons/surface_displacement/textures/sd_dfg_lut.exr"


## name -> [RenderingServer type, Project Settings type name, default value]. The defaults are the
## Medium preset, so materials look right before any SurfaceDisplacement node runs.
static func definitions() -> Dictionary:
	return {
		POM_STEPS: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(8, 20, 3, 0)],
		POM_RANGE: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(18, 30, 0, 6)],
		SHADOW: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(6, 15, 0, 1)],
		DEBUG: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(0, 0.1, 0, 0)],
		DFG: [RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "sampler2D", DFG_PATH],
	}


## Makes sure every global exists. In the editor with [param to_project_settings], missing ones
## are added to Project Settings (saved) as well. Returns the names that were missing.
##
## Outside the editor the RenderingServer cannot be asked for its list (Godot reports that as an
## error), but at startup it registers exactly the globals in Project Settings, so those are the
## ones that exist; the others are added here.
static func ensure_registered(to_project_settings := false) -> PackedStringArray:
	var missing := PackedStringArray()
	var defs := definitions()
	var editor := Engine.is_editor_hint()
	var server_list: PackedStringArray = []
	if editor:
		for name in RenderingServer.global_shader_parameter_get_list():
			server_list.append(String(name))
	for name: StringName in defs:
		var def: Array = defs[name]
		var key := "shader_globals/" + String(name)
		var in_settings := ProjectSettings.has_setting(key)
		if not in_settings:
			missing.append(String(name))
			if editor and to_project_settings:
				ProjectSettings.set_setting(key, {"type": def[1], "value": def[2]})
		var on_server := server_list.has(String(name)) if editor else in_settings
		if not on_server:
			var value: Variant = def[2]
			if def[0] == RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D:
				value = load(def[2])
			RenderingServer.global_shader_parameter_add(name, def[0], value)
	if editor and to_project_settings and not missing.is_empty():
		ProjectSettings.save()
	return missing


## Values last written through [method set_value] (plain vectors, no objects). The RenderingServer
## can only be read back in the editor, so this keeps them for [method get_value].
static var _values := {}


static func set_value(name: StringName, value: Variant) -> void:
	_values[name] = value
	RenderingServer.global_shader_parameter_set(name, value)


## The value last set through [method set_value], else the Project Settings value, else the
## default of [method definitions].
static func get_value(name: StringName) -> Variant:
	if _values.has(name):
		return _values[name]
	var key := "shader_globals/" + String(name)
	if ProjectSettings.has_setting(key):
		return (ProjectSettings.get_setting(key) as Dictionary).get("value")
	return definitions()[name][2]
