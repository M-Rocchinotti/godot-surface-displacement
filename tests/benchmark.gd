extends SceneTree
## GPU cost of every preset at 1920x1080 with V-Sync off (headed run; tools/run_benchmark.py waits
## for an idle GPU first):
##     python tools/godot.py --script tests/benchmark.gd
##
## Scene: open ground of the demo's gravel (Poly Haven clean_pebbles) under a shadowed sun with
## SSAO, AgX and a sky, seen from eye level (1.7 m) so the ground covers about 60 % of the frame,
## the camera panning slowly along a fixed path. Baseline: the same ground with an ORMMaterial3D
## using the same albedo, normal and ORM textures at the same texel density (plain normal
## mapping), measured before and after the rows (median of both). Every row is measured three
## times (150 warm-up + 300 sampled frames each) and the median is reported; "added" is the
## viewport GPU time minus the baseline's. The budget check uses the Low / Medium / High / Epic
## targets of SDSettings.get_budget_ms(). Exit code 1 if a preset is over budget.
## Results: stdout and build/benchmark_results.md.
##
##     python tools/godot.py --script tests/benchmark.gd -- --explore        (or --explore=pom)
## measures candidate near-camera geometry settings (or parallax mip limits, pom_max_lod)
## instead (build/benchmark_explore.md).

const Builder := preload("res://demo/scenes/demo_builder.gd")
const SIZE := Vector2i(1920, 1080)
const WARMUP := 150
const SAMPLES := 300
const REPEATS := 3

var viewport: SubViewport
var scene: Node3D
var _lines: PackedStringArray = []


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	root.size = Vector2i(640, 360)
	SDGlobals.ensure_registered()
	viewport = SubViewport.new()
	viewport.size = SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	_run()


func _log(line: String) -> void:
	print(line)
	_lines.append(line)


## [param mode]: "baseline" or an SDSettings.Preset (optionally with feature switches off).
func build(sd_mode: Variant, features := {}) -> void:
	if scene != null:
		scene.queue_free()
		await process_frame
	scene = Node3D.new()
	var env_root := Builder.make_root("Benchmark", 30.0, 200.0)
	scene.add_child(env_root)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var sd := env_root.get_node("SurfaceDisplacement") as SurfaceDisplacement
	var base := "res://demo/textures/clean_pebbles/clean_pebbles"
	if sd_mode is String:
		var orm := ORMMaterial3D.new()
		# The plane's UV spans it once; the SD material repeats every texture_size_m (2 m).
		orm.uv1_scale = Vector3(plane.size.x / 2.0, plane.size.y / 2.0, 1.0)
		orm.albedo_texture = load(base + "_albedo.jpg")
		orm.normal_enabled = true
		orm.normal_texture = load(base + "_normal.jpg")
		orm.orm_texture = load(base + "_arm.jpg")
		orm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		orm.metallic = 0.0
		ground.material_override = orm
		sd.preset = SDSettings.Preset.OFF
	else:
		var mat := Builder.ground_material("clean_pebbles")
		ground.material_override = mat
		var field := DisplacementField3D.new()
		field.layers = [mat]
		field.bake_on_ready = false
		env_root.add_child(field)
		field.add_child(PebbleScatter3D.new())
		sd.preset = sd_mode
		for key: String in features:
			if key == "settings":
				sd.custom_settings = features[key]
				sd.preset = SDSettings.Preset.CUSTOM
			elif key == "label":
				pass
			elif key == "depth_write":
				# The opt-in depth write on the ground material itself.
				SDMaterials.set_depth_write(mat, true)
			else:
				sd.set(key, features[key])
	env_root.add_child(ground)
	viewport.add_child(scene)
	(env_root.get_node("Camera") as Camera3D).current = true


func _camera_at(t: float) -> void:
	var cam := scene.get_child(0).get_node("Camera") as Camera3D
	var p := Vector3(0.6 * t, 1.7, -0.9 * t)
	cam.look_at_from_position(p, p + Vector3(0.15, -0.45, -1.0))


## Median GPU time and spread of [param runs] (ms).
static func summarize(runs: Array[float]) -> Dictionary:
	var sorted := runs.duplicate()
	sorted.sort()
	return {"gpu": sorted[sorted.size() / 2], "spread": sorted[-1] - sorted[0]}


func measure() -> Dictionary:
	var rid := viewport.get_viewport_rid()
	var runs: Array[float] = []
	var frame_runs: Array[float] = []
	for r in REPEATS:
		for i in WARMUP:
			_camera_at(float(i) / 60.0)
			await process_frame
		var gpu := 0.0
		var start := Time.get_ticks_usec()
		for i in SAMPLES:
			_camera_at(float(WARMUP + i) / 60.0)
			await process_frame
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		runs.append(gpu / SAMPLES)
		frame_runs.append(float(Time.get_ticks_usec() - start) / 1000.0 / SAMPLES)
	frame_runs.sort()
	var s := summarize(runs)
	return {"gpu": s["gpu"], "spread": s["spread"], "frame": frame_runs[REPEATS / 2], "runs": runs}


## Candidate parallax mip limits (pom_max_lod) per preset for --explore=pom: where the relief fades
## out on fine textures at grazing views (tools/relief_range.gd) against what it costs.
static func explore_pom_rows() -> Array:
	var rows := []
	var candidates := {SDSettings.Preset.LOW: [5.0, 5.5, 6.0, 6.5], SDSettings.Preset.MEDIUM: [6.0, 6.5, 7.0, 7.5],
			SDSettings.Preset.HIGH: [6.5, 7.0, 7.5, 8.0], SDSettings.Preset.EPIC: [6.0, 6.5, 7.0, 7.5]}
	for base: SDSettings.Preset in candidates:
		for max_lod: float in candidates[base]:
			var s := SDSettings.create_preset(base)
			s.pom_max_lod = max_lod
			rows.append([base, {"settings": s, "label": "pom_max_lod %.1f" % max_lod}])
	return rows


## Candidate settings for the explore mode: a base preset with near-camera geometry changes.
static func explore_rows() -> Array:
	var rows := []
	for base: SDSettings.Preset in [SDSettings.Preset.HIGH, SDSettings.Preset.EPIC]:
		for cfg: Array in [[4, 256, 0.015], [4, 160, 0.02], [4, 128, 0.03], [4, 96, 0.04], [3, 128, 0.03], [3, 96, 0.04], [4, 80, 0.05]]:
			var s := SDSettings.create_preset(base)
			s.near_field_levels = cfg[0]
			s.near_field_resolution = cfg[1]
			s.near_field_spacing = cfg[2]
			var reach: float = cfg[1] / 2.0 * pow(2.0, cfg[0] - 1) * cfg[2]
			rows.append([base, {"settings": s, "label": "field %d x %d at %.1f cm (reach %.1f m)" % [cfg[0], cfg[1], cfg[2] * 100.0, reach]}])
		var no_field := SDSettings.create_preset(base)
		no_field.near_field_enabled = false
		rows.append([base, {"settings": no_field, "label": "no field"}])
	return rows


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var explore := args.has("--explore") or args.has("--explore=pom")
	await process_frame
	_log("# Surface Displacement benchmark" + (" (explore)" if explore else ""))
	_log("")
	_log("GPU: %s | %s | %dx%d, V-Sync off, %d x (%d warm-up + %d sampled frames), median" % [
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(), SIZE.x, SIZE.y,
		REPEATS, WARMUP, SAMPLES])
	await build("baseline")
	var base_first := await measure()
	var rows := (explore_pom_rows() if args.has("--explore=pom") else explore_rows()) if explore else [
		[SDSettings.Preset.OFF, {}], [SDSettings.Preset.LOW, {}], [SDSettings.Preset.MEDIUM, {}],
		[SDSettings.Preset.HIGH, {}], [SDSettings.Preset.EPIC, {}],
		[SDSettings.Preset.EPIC, {"scatter": false}], [SDSettings.Preset.EPIC, {"near_field": false}],
		[SDSettings.Preset.EPIC, {"near_field": false, "self_shadow": false}],
		[SDSettings.Preset.MEDIUM, {"depth_write": true}],
	]
	var results := []
	for row: Array in rows:
		await build(row[0], row[1])
		results.append(await measure())
	await build("baseline")
	var base_last := await measure()
	var base_runs: Array[float] = []
	base_runs.append_array(base_first["runs"])
	base_runs.append_array(base_last["runs"])
	var base := summarize(base_runs)
	_log("")
	_log("Baseline (ORMMaterial3D, same textures and texel density, normal mapping only): viewport GPU %.3f ms (6 runs before and after the rows, spread %.3f)" % [base["gpu"], base["spread"]])
	_log("")
	_log("| Preset | features | viewport GPU ms | added ms | target ms | spread | result |")
	_log("|---|---|---|---|---|---|---|")
	var failures := 0
	for i in rows.size():
		var row: Array = rows[i]
		var r: Dictionary = results[i]
		var feature_map: Dictionary = row[1]
		var added: float = r["gpu"] - base["gpu"]
		var budget := SDSettings.get_budget_ms(row[0])
		var budget_row: bool = feature_map.is_empty() and row[0] != SDSettings.Preset.OFF
		var ok := added <= budget
		if budget_row and not ok:
			failures += 1
		var feats := "all of the preset"
		if feature_map.has("label"):
			feats = feature_map["label"]
		elif not feature_map.is_empty():
			feats = ", ".join(feature_map.keys().map(func(k: String) -> String: return ("+ " if feature_map[k] else "no ") + k.replace("_", " ")))
		_log("| %s | %s | %.3f | %.3f | %s | %.3f | %s |" % [SDSettings.preset_name(row[0]), feats, r["gpu"], added,
				"%.1f" % budget if budget_row else "-", r["spread"], ("PASS" if ok else "OVER") if budget_row else "-"])
	_log("")
	if not explore:
		_log("Budget check: %s" % ("all presets within budget" if failures == 0 else "%d preset(s) over budget" % failures))
	var f := FileAccess.open("res://build/benchmark_explore.md" if explore else "res://build/benchmark_results.md", FileAccess.WRITE)
	if f != null:
		f.store_string("
".join(_lines) + "
")
	scene.queue_free()
	await process_frame
	await process_frame
	quit(1 if failures > 0 and not explore else 0)
