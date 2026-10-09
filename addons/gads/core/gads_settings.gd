@tool
class_name GADSSettings
extends Resource
## Quality settings of GADS: parallax occlusion mapping (POM), self-shadowing,
## near-camera geometry ([GADSDisplacementField3D]) and pebble scatter ([GADSPebbleScatter3D]).
## [method create_preset] gives the Low / Medium / High / Ultra presets; the budgets are the
## targets the benchmark (tests/benchmark.gd) checks them against.

enum Preset { OFF, LOW, MEDIUM, HIGH, ULTRA, CUSTOM }
enum SelfShadow { OFF, HARD, SOFT }

@export_group("Parallax occlusion mapping")
@export var pom_enabled := true:
	set(value):
		pom_enabled = value
		emit_changed()
## Linear steps when looking straight at a surface.
@export_range(1, 64) var pom_min_steps := 8:
	set(value):
		pom_min_steps = value
		emit_changed()
## Linear steps at grazing angles.
@export_range(1, 64) var pom_max_steps := 20:
	set(value):
		pom_max_steps = value
		emit_changed()
## Bisection steps after the linear search (a final secant step always follows).
@export_range(0, 8) var pom_refine_steps := 3:
	set(value):
		pom_refine_steps = value
		emit_changed()
## The relief starts fading into plain normal mapping here (m from the camera)...
@export_range(0.0, 500.0, 0.5, "suffix:m") var pom_fade_start := 18.0:
	set(value):
		pom_fade_start = value
		emit_changed()
## ...and is gone here.
@export_range(0.0, 500.0, 0.5, "suffix:m") var pom_fade_end := 30.0:
	set(value):
		pom_fade_end = value
		emit_changed()
## Added to the mip level the march samples (positive = blurrier, cheaper).
@export_range(-2.0, 4.0, 0.25) var pom_lod_bias := 0.0:
	set(value):
		pom_lod_bias = value
		emit_changed()
## Height-map mip level at and beyond which the march is skipped (the relief is below a pixel).
@export_range(0.0, 12.0, 0.5) var pom_max_lod := 6.0:
	set(value):
		pom_max_lod = value
		emit_changed()
## Fade the relief by its size on screen as well: it starts fading where a material's depth spans
## x pixels and is gone at y, so shallow relief fades nearer than deep relief (and stops costing
## its march) while deep relief keeps its shape out to the distance fade. (0, 0): off.
@export var pom_fade_pixels := Vector2(0, 0):
	set(value):
		pom_fade_pixels = value
		emit_changed()
@export_group("Self-shadowing")
## Height-field shadows from directional lights (and omni and spot lights with
## [member self_shadow_local_lights]), computed in a light() that reproduces Godot's own direct
## lighting. OFF uses Godot's built-in lighting.
@export var self_shadow := SelfShadow.HARD:
	set(value):
		self_shadow = value
		emit_changed()
@export_range(1, 32) var self_shadow_steps := 6:
	set(value):
		self_shadow_steps = value
		emit_changed()
@export_range(0.0, 200.0, 0.5, "suffix:m") var self_shadow_distance := 15.0:
	set(value):
		self_shadow_distance = value
		emit_changed()
## Contact-hardening strength for SOFT (larger = harder).
@export_range(1.0, 200.0, 1.0) var self_shadow_softness := 24.0:
	set(value):
		self_shadow_softness = value
		emit_changed()
## Omni and spot lights self-shadow the relief too, not only directional lights. Each one costs
## a self-shadow march on every pixel it lights.
@export var self_shadow_local_lights := false:
	set(value):
		self_shadow_local_lights = value
		emit_changed()
@export_group("Near-camera geometry")
@export var near_field_enabled := false:
	set(value):
		near_field_enabled = value
		emit_changed()
## Rings, quads per ring side and finest vertex spacing of [GADSDisplacementField3D]. The defaults
## (3 x 96 at 4 cm, reaching 7.7 m) are Ultra's: denser grids cost more than they show, because
## the field's fragments march the full relief anyway (tests/benchmark.gd --explore).
@export_range(2, 6) var near_field_levels := 3:
	set(value):
		near_field_levels = value
		emit_changed()
@export_range(16, 512, 4) var near_field_resolution := 96:
	set(value):
		near_field_resolution = value
		emit_changed()
@export_range(0.005, 0.1, 0.0005, "suffix:m") var near_field_spacing := 0.04:
	set(value):
		near_field_spacing = value
		emit_changed()
@export_group("Pebble scatter")
@export var scatter_enabled := false:
	set(value):
		scatter_enabled = value
		emit_changed()
## Fraction of the scatter's pebbles that are drawn (0-1).
@export_range(0.0, 1.0, 0.05) var scatter_density := 1.0:
	set(value):
		scatter_density = value
		emit_changed()
@export_range(2.0, 30.0, 0.5, "suffix:m") var scatter_radius := 8.0:
	set(value):
		scatter_radius = value
		emit_changed()


static func create_preset(preset: Preset) -> GADSSettings:
	var s := GADSSettings.new()
	match preset:
		Preset.OFF:
			s.pom_enabled = false
			s.self_shadow = SelfShadow.OFF
		Preset.LOW:
			s.pom_min_steps = 4
			s.pom_max_steps = 10
			s.pom_refine_steps = 0
			s.pom_fade_start = 8.0
			s.pom_fade_end = 14.0
			s.pom_max_lod = 5.0
			s.self_shadow = SelfShadow.OFF
		Preset.MEDIUM:
			pass # the defaults
		Preset.HIGH:
			s.pom_min_steps = 10
			s.pom_max_steps = 28
			s.pom_refine_steps = 4
			s.pom_fade_start = 25.0
			s.pom_fade_end = 40.0
			s.pom_max_lod = 6.5
			s.self_shadow = SelfShadow.SOFT
			s.self_shadow_steps = 12
			s.self_shadow_distance = 25.0
			s.self_shadow_local_lights = true
		Preset.ULTRA:
			# Real geometry near the camera: the field (3 rings of 96 x 96 quads at 4 cm, reaching
			# 7.7 m) and the pebbles. The field's fragments march the relief too, so Ultra pays for
			# it with slightly fewer parallax steps and a shorter fade than High (tests/benchmark.gd).
			s.pom_min_steps = 8
			s.pom_max_steps = 20
			s.pom_refine_steps = 3
			s.pom_fade_start = 20.0
			s.pom_fade_end = 35.0
			s.self_shadow = SelfShadow.SOFT
			s.self_shadow_steps = 8
			s.self_shadow_distance = 20.0
			s.self_shadow_local_lights = true
			s.near_field_enabled = true
			s.scatter_enabled = true
	return s


static func preset_name(preset: Preset) -> String:
	return ["Off", "Low", "Medium", "High", "Ultra", "Custom"][preset]


## Target added GPU time (ms) at 1080p on a GTX 1080 with the ground covering about 60 % of
## the screen, the convention of tests/benchmark.gd.
static func get_budget_ms(preset: Preset) -> float:
	return [0.0, 0.5, 1.2, 2.0, 3.0, INF][preset]


## The shader variant quality these settings need.
func get_quality() -> GADSMaterials.Quality:
	if not pom_enabled:
		return GADSMaterials.Quality.FLAT
	if self_shadow == SelfShadow.OFF:
		return GADSMaterials.Quality.POM
	return GADSMaterials.Quality.POM_SELF_SHADOW


## Writes the shader globals every GADS shader reads.
func apply_globals() -> void:
	var local_lights := 1.0 if self_shadow_local_lights and self_shadow != SelfShadow.OFF else 0.0
	GADSGlobals.set_value(GADSGlobals.POM_STEPS, Vector4(pom_min_steps, maxi(pom_max_steps, pom_min_steps), pom_refine_steps, local_lights))
	GADSGlobals.set_value(GADSGlobals.POM_RANGE, Vector4(pom_fade_start, maxf(pom_fade_end, pom_fade_start + 0.01), pom_lod_bias, pom_max_lod))
	GADSGlobals.set_value(GADSGlobals.POM_FADE_PX, Vector4(maxf(pom_fade_pixels.x, 0.0), clampf(pom_fade_pixels.y, 0.0, maxf(pom_fade_pixels.x, 0.0)), 0, 0))
	var softness := self_shadow_softness if self_shadow == SelfShadow.SOFT else 0.0
	var strength := 0.0 if self_shadow == SelfShadow.OFF else 1.0
	GADSGlobals.set_value(GADSGlobals.SHADOW, Vector4(self_shadow_steps, self_shadow_distance, softness, strength))
