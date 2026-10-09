@tool
class_name GADSGlobals
extends RefCounted
## The global shader uniforms that every GADS shader reads. The editor plugin
## registers them in Project Settings > Shader Globals (so they are saved in project.godot and
## exported with the game); [method ensure_registered] also adds them to a running
## RenderingServer, so shaders compile without an editor restart.
##
## [code]gads_pom_steps[/code]  x: minimum linear steps (straight-on view), y: maximum linear steps
##     (grazing view), z: bisection steps after the linear search, w: 1 = omni and spot lights
##     self-shadow the relief too (0 = only directional lights do).
## [code]gads_pom_range[/code]  x: distance where the relief starts fading (m), y: distance where it
##     is gone (m), z: LOD bias of the march's height samples, w: the height-map mip level at and
##     beyond which the march is skipped (the relief is below a pixel there).
## [code]gads_pom_fade_px[/code]  x: relief size on screen (px) below which the relief starts fading,
##     y: size at which it is gone (0, 0: off, the distance fade alone), z, w: unused.
## [code]gads_shadow[/code]  x: self-shadow steps, y: maximum distance (m), z: softness (0 = hard,
##     k > 0 = contact-hardening), w: strength (0 = off).
## [code]gads_debug[/code]  x: debug view (0 = off), y: scale in metres (hit offset, world height),
##     z: reference height in metres of the field's world-height view (tests), w: unused.
## [code]gads_dfg[/code]  the multiple-scattering term of Godot's BRDF (tools/make_dfg_lut.py).
## [code]gads_deform[/code]  runtime deformation (GADSDeformationField): r = depth pressed down (m,
##     negative = raised) when stamped, g = the time of the stamp (s).
## [code]gads_deform_params[/code]  x, z: the deformation window's origin (m), y: its side (m), w: the
##     deepest deformation (m; 0 = no deformation).
## [code]gads_deform_time[/code]  x: now (s, the field's clock), y: recovery (m per second), z, w: unused.
## [code]gads_weather[/code]  surface effects on every GADS material (GADSManager's weather): x: rain
##     wetness, y: snow cover, z: puddle level (all 0..1), w: unused.

const POM_STEPS := &"gads_pom_steps"
const POM_RANGE := &"gads_pom_range"
const POM_FADE_PX := &"gads_pom_fade_px"
const SHADOW := &"gads_shadow"
const DEBUG := &"gads_debug"
const DFG := &"gads_dfg"
const DFG_PATH := "res://addons/gads/render/textures/gads_dfg_lut.exr"
const DEFORM := &"gads_deform"
const DEFORM_PARAMS := &"gads_deform_params"
const DEFORM_TIME := &"gads_deform_time"
const WEATHER := &"gads_weather"


## name -> [RenderingServer type, Project Settings type name, default value]. The defaults are the
## Medium preset, so materials look right before any GADSManager node runs.
static func definitions() -> Dictionary:
	return {
		POM_STEPS: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(8, 20, 3, 0)],
		POM_RANGE: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(18, 30, 0, 6)],
		POM_FADE_PX: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(0, 0, 0, 0)],
		SHADOW: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(6, 15, 0, 1)],
		DEBUG: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(0, 0.1, 0, 0)],
		DFG: [RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "sampler2D", DFG_PATH],
		DEFORM: [RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "sampler2D", ""],
		DEFORM_PARAMS: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(0, 0, 1, 0)],
		DEFORM_TIME: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(0, 0, 0, 0)],
		WEATHER: [RenderingServer.GLOBAL_VAR_TYPE_VEC4, "vec4", Vector4(0, 0, 0, 0)],
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
		var on_server := server_list.has(String(name)) if editor else (in_settings or _added.has(name))
		if not on_server:
			_added[name] = true
			var value: Variant = def[2]
			if def[0] == RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D:
				value = load(def[2]) if not String(def[2]).is_empty() else null
			RenderingServer.global_shader_parameter_add(name, def[0], value)
	if editor and to_project_settings and not missing.is_empty():
		ProjectSettings.save()
	return missing


## Values last written through [method set_value]. The RenderingServer can only be read back in
## the editor, so this keeps them for [method get_value].
static var _values := {}
## Globals added to the running RenderingServer by [method ensure_registered] (outside the editor
## it cannot be asked which exist).
static var _added := {}


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
