@tool
class_name SDSettings
extends Resource
## Quality settings of Surface Displacement: parallax occlusion mapping (POM), self-shadowing,
## near-camera geometry ([DisplacementField3D]) and pebble scatter ([PebbleScatter3D]).
## [method create_preset] gives the Low / Medium / High / Epic presets; the budgets are the
## targets the benchmark (tests/benchmark.gd) checks them against.

enum Preset { OFF, LOW, MEDIUM, HIGH, EPIC, CUSTOM }
enum SelfShadow { OFF, HARD, SOFT }

@export_group("Parallax occlusion mapping")
@export var pom_enabled := true
## Linear steps when looking straight at a surface.
@export_range(1, 64) var pom_min_steps := 8
## Linear steps at grazing angles.
@export_range(1, 64) var pom_max_steps := 20
## Bisection steps after the linear search (a final secant step always follows).
@export_range(0, 8) var pom_refine_steps := 3
## The relief starts fading into plain normal mapping here (m from the camera)...
@export_range(0.0, 500.0, 0.5, "suffix:m") var pom_fade_start := 18.0
## ...and is gone here.
@export_range(0.0, 500.0, 0.5, "suffix:m") var pom_fade_end := 30.0
## Added to the mip level the march samples (positive = blurrier, cheaper).
@export_range(-2.0, 4.0, 0.25) var pom_lod_bias := 0.0
## Height-map mip level at and beyond which the march is skipped (the relief is below a pixel).
@export_range(0.0, 12.0, 0.5) var pom_max_lod := 6.0
## Materials that opted into the depth write ([method SDMaterials.set_depth_write]) write it;
## off, they draw without it (their opt-in is kept for when it is on again).
@export var depth_write_enabled := true
@export_group("Self-shadowing")
## Height-field shadows from directional lights, computed in a light() that reproduces Godot's
## own direct lighting. OFF uses Godot's built-in lighting.
@export var self_shadow := SelfShadow.HARD
@export_range(1, 32) var self_shadow_steps := 6
## Self-shadowing fades out towards this distance from the camera (0 = no self-shadowing).
@export_range(0.0, 200.0, 0.5, "suffix:m") var self_shadow_distance := 15.0
## Contact-hardening strength for SOFT (larger = harder).
@export_range(1.0, 200.0, 1.0) var self_shadow_softness := 24.0
@export_group("Near-camera geometry")
@export var near_field_enabled := false
## Rings, quads per ring side and finest vertex spacing of [DisplacementField3D]. The defaults
## (3 x 96 at 4 cm, reaching 7.7 m) are Epic's: denser grids cost more than they show, because
## the field's fragments march the full relief anyway (tests/benchmark.gd --explore).
@export_range(2, 6) var near_field_levels := 3
@export_range(16, 512, 4) var near_field_resolution := 96
@export_range(0.005, 0.1, 0.0005, "suffix:m") var near_field_spacing := 0.04
@export_group("Pebble scatter")
@export var scatter_enabled := false
## Fraction of the scatter's pebbles that are drawn (0-1).
@export_range(0.0, 1.0, 0.05) var scatter_density := 1.0
@export_range(2.0, 30.0, 0.5, "suffix:m") var scatter_radius := 8.0


static func create_preset(preset: Preset) -> SDSettings:
	var s := SDSettings.new()
	match preset:
		Preset.OFF:
			s.pom_enabled = false
			s.self_shadow = SelfShadow.OFF
			s.depth_write_enabled = false
		Preset.LOW:
			s.pom_min_steps = 4
			s.pom_max_steps = 10
			s.pom_refine_steps = 0
			s.pom_fade_start = 8.0
			s.pom_fade_end = 14.0
			s.pom_max_lod = 5.0
			s.self_shadow = SelfShadow.OFF
			# The depth write costs early-Z and a second march (README): not in the cheapest preset.
			s.depth_write_enabled = false
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
		Preset.EPIC:
			# Real geometry near the camera: the field (3 rings of 96 x 96 quads at 4 cm, reaching
			# 7.7 m) and the pebbles. The field's fragments march the relief too, so Epic pays for
			# it with slightly fewer parallax steps and a shorter fade than High (tests/benchmark.gd).
			s.pom_min_steps = 8
			s.pom_max_steps = 20
			s.pom_refine_steps = 3
			s.pom_fade_start = 20.0
			s.pom_fade_end = 35.0
			s.self_shadow = SelfShadow.SOFT
			s.self_shadow_steps = 8
			s.self_shadow_distance = 20.0
			s.near_field_enabled = true
			s.scatter_enabled = true
	return s


static func preset_name(preset: Preset) -> String:
	return ["Off", "Low", "Medium", "High", "Epic", "Custom"][preset]


## Target added GPU time (ms) at 1080p on a GTX 1080 with the ground covering about 60 % of
## the screen, the convention of tests/benchmark.gd.
static func get_budget_ms(preset: Preset) -> float:
	return [0.0, 0.5, 1.2, 2.0, 3.0, INF][preset]


## The shader variant quality these settings need.
func get_quality() -> SDMaterials.Quality:
	if not pom_enabled:
		return SDMaterials.Quality.FLAT
	if self_shadow == SelfShadow.OFF:
		return SDMaterials.Quality.POM
	return SDMaterials.Quality.POM_SELF_SHADOW


## Writes the shader globals every Surface Displacement shader reads.
func apply_globals() -> void:
	SDGlobals.set_value(SDGlobals.POM_STEPS, Vector4(pom_min_steps, maxi(pom_max_steps, pom_min_steps), pom_refine_steps, 0))
	SDGlobals.set_value(SDGlobals.POM_RANGE, Vector4(pom_fade_start, maxf(pom_fade_end, pom_fade_start + 0.01), pom_lod_bias, pom_max_lod))
	var softness := self_shadow_softness if self_shadow == SelfShadow.SOFT else 0.0
	var strength := 0.0 if self_shadow == SelfShadow.OFF else 1.0
	SDGlobals.set_value(SDGlobals.SHADOW, Vector4(self_shadow_steps, self_shadow_distance, softness, strength))
