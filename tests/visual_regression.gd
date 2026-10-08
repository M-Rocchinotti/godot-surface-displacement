extends SceneTree
## Visual regression: renders fixed views of the demo scenes (and two debug views) and compares
## each with its reference image in tests/reference/. A shot fails when its mean colour difference,
## the worst 16 x 16 pixel block's mean difference (a local defect: a crack, a missing prop) or
## its share of clearly changed pixels exceeds the limits below; the shot and a difference image
## are then written to build/visual/. The same machine renders the shots bit for bit the same; the
## limits leave room for another driver but catch, for example, the normal maps of UV-mapped
## surfaces going missing.
##     python tools/godot.py --fixed-fps 30 --script tests/visual_regression.gd
##     python tools/godot.py --fixed-fps 30 --script tests/visual_regression.gd -- --update
##     ... -- --only=brick_wall,material_lab_tessellation
## --update writes the references from this run (look at them before committing). Animated
## materials are stopped and every bake is waited for, so a shot does not depend on timing.

const Builder := preload("res://demo/scenes/demo_builder.gd")
const REFERENCE_DIR := "res://tests/reference/"
const OUTPUT_DIR := "res://build/visual/"
const SIZE := Vector2i(480, 270)
## Largest mean difference (0..1, the RGB channels' average) a shot may have.
const MAX_MEAN := 0.003
## Largest mean difference of a 16 x 16 pixel block.
const MAX_BLOCK := 0.03
const BLOCK := 16
## Largest share of pixels whose largest channel differs by more than CHANGED_BY.
const MAX_CHANGED := 0.005
const CHANGED_BY := 0.1
## [name, scene index, debug view]
const SHOTS := [
	["gravel_path", 0, GADSManager.DebugView.OFF],
	["cobblestone_street", 1, GADSManager.DebugView.OFF],
	["rocky_ground", 2, GADSManager.DebugView.OFF],
	["brick_wall", 3, GADSManager.DebugView.OFF],
	["hills", 4, GADSManager.DebugView.OFF],
	["cliff", 5, GADSManager.DebugView.OFF],
	["material_lab", 6, GADSManager.DebugView.OFF],
	["material_lab_tessellation", 6, GADSManager.DebugView.TESSELLATION],
	["brick_wall_normals", 3, GADSManager.DebugView.NORMALS],
]

var _passed := 0
var _failed := 0
var _viewport: SubViewport


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	GADSGlobals.ensure_registered()
	var update := OS.get_cmdline_user_args().has("--update")
	var only := []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = Array(arg.trim_prefix("--only=").split(","))
	_viewport = SubViewport.new()
	_viewport.size = SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	for shot: Array in SHOTS:
		if not only.is_empty() and not only.has(shot[0]):
			continue
		print("== %s" % shot[0])
		var img := await _render(shot[1], shot[2])
		var ref_path: String = REFERENCE_DIR + shot[0] + ".webp"
		if update:
			img.save_webp(ProjectSettings.globalize_path(ref_path), false)
			print("  wrote %s" % ref_path)
			continue
		var ref: Image = Image.load_from_file(ProjectSettings.globalize_path(ref_path)) if FileAccess.file_exists(ref_path) else null
		if ref == null:
			check(false, "a reference image exists (%s; run with --update)" % ref_path)
			continue
		ref.convert(Image.FORMAT_RGBA8)
		var d := compare(img, ref)
		print("  mean difference %.4f (limit %.3f), worst block %.4f (limit %.2f), %.2f %% of pixels changed by more than %.2f (limit %.1f %%)" % [
			d["mean"], MAX_MEAN, d["block"], MAX_BLOCK, d["changed"] * 100.0, CHANGED_BY, MAX_CHANGED * 100.0])
		var ok: bool = d["mean"] <= MAX_MEAN and d["block"] <= MAX_BLOCK and d["changed"] <= MAX_CHANGED
		check(ok, "%s matches its reference" % shot[0])
		if not ok:
			img.save_png(ProjectSettings.globalize_path(OUTPUT_DIR + shot[0] + ".png"))
			(d["image"] as Image).save_png(ProjectSettings.globalize_path(OUTPUT_DIR + shot[0] + "_diff.png"))
			print("  wrote %s%s.png and _diff.png" % [OUTPUT_DIR, shot[0]])
	if not update:
		print("\nvisual regression: %d passed, %d failed" % [_passed, _failed])
	_viewport.queue_free()
	await process_frame
	await process_frame
	quit(1 if _failed > 0 else 0)


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)


## Mean difference, worst block mean, share of changed pixels and a difference image (changes x 4)
## of two images of the same size.
static func compare(a: Image, b: Image) -> Dictionary:
	if a.get_size() != b.get_size():
		return {"mean": 1.0, "block": 1.0, "changed": 1.0, "image": a}
	var diff := Image.create_empty(a.get_width(), a.get_height(), false, Image.FORMAT_RGB8)
	var blocks := Vector2i(ceili(a.get_width() / float(BLOCK)), ceili(a.get_height() / float(BLOCK)))
	var block_sums := PackedFloat64Array()
	block_sums.resize(blocks.x * blocks.y)
	var sum := 0.0
	var changed := 0
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var dr := absf(ca.r - cb.r)
			var dg := absf(ca.g - cb.g)
			var db := absf(ca.b - cb.b)
			var d := (dr + dg + db) / 3.0
			sum += d
			block_sums[(y / BLOCK) * blocks.x + x / BLOCK] += d
			if maxf(dr, maxf(dg, db)) > CHANGED_BY:
				changed += 1
			diff.set_pixel(x, y, Color(minf(dr * 4.0, 1.0), minf(dg * 4.0, 1.0), minf(db * 4.0, 1.0)))
	var worst := 0.0
	for i in block_sums.size():
		var bx := i % blocks.x
		var by := i / blocks.x
		var pixels := (mini((bx + 1) * BLOCK, a.get_width()) - bx * BLOCK) * (mini((by + 1) * BLOCK, a.get_height()) - by * BLOCK)
		worst = maxf(worst, block_sums[i] / pixels)
	var n := float(a.get_width() * a.get_height())
	return {"mean": sum / n, "block": worst, "changed": changed / n, "image": diff}


## Builds demo scene [param index] at the High preset, waits for its bakes and tessellations,
## and captures its first view with [param debug_view].
func _render(index: int, debug_view: GADSManager.DebugView) -> Image:
	var scene := Builder.build(index)
	_viewport.add_child(scene)
	(scene.get_node("Camera") as Camera3D).current = true
	var gads := scene.get_node("GADSManager") as GADSManager
	gads.adaptive_quality = false
	gads.preset = GADSSettings.Preset.HIGH
	gads.debug_view = debug_view
	_stop_animation(scene)
	for i in 1200:
		await process_frame
		if i > 10 and not _busy(scene):
			break
	for i in 10:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _viewport.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	scene.queue_free()
	await process_frame
	await process_frame
	return img


## Whether anything in [param scene] still bakes, tessellates or streams.
static func _busy(scene: Node) -> bool:
	for node: GADSMeshInstance3D in scene.find_children("*", "GADSMeshInstance3D", true, false):
		if node.is_baking() or node.is_view_tessellating():
			return true
	for field: GADSDisplacementField3D in scene.find_children("*", "GADSDisplacementField3D", true, false):
		if field.is_baking():
			return true
	for terrain: GADSTerrain3D in scene.find_children("*", "GADSTerrain3D", true, false):
		if terrain.is_streaming_busy():
			return true
	return false


## Stops flowing and breathing relief: a shot must not depend on the renderer's clock.
static func _stop_animation(scene: Node) -> void:
	for node in scene.find_children("*", "GeometryInstance3D", true, false):
		for m in GADSMaterials.materials_of(node):
			if GADSMaterials.is_gads_material(m):
				(m as ShaderMaterial).set_shader_parameter("flow_speed", Vector2.ZERO)
				(m as ShaderMaterial).set_shader_parameter("pulse_amount", 0.0)
