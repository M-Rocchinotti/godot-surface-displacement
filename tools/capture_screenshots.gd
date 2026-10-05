extends SceneTree
## Captures the README images into docs/images/ (headed run; --headless draws nothing):
##
##     python tools/godot.py --script tools/capture_screenshots.gd
##
## For every demo scene and camera view (eye level, grazing) it renders the three comparison
## modes of the demo - flat (preset Off: normal mapping only), POM (Ultra parallax and
## self-shadowing, no geometry) and POM + geometry (Ultra: near-camera geometry and pebbles too)
## - and writes each image plus a side-by-side strip. Also a field-rings debug view and the demo
## with its UI.

const Builder := preload("res://demo/scenes/demo_builder.gd")
const OUT := "res://docs/images/"
const SIZE := Vector2i(1280, 720)
const MODES := ["flat", "pom", "pom_geometry"]
# JPEG: 35 lossless 720p captures would add 36 MB to the repository.
const QUALITY := 0.9

var viewport: SubViewport


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	GADSGlobals.ensure_registered()
	viewport = SubViewport.new()
	viewport.size = SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	_run()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func capture() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func set_mode(sd: GADSManager, mode: int) -> void:
	sd.preset = GADSSettings.Preset.OFF if mode == 0 else GADSSettings.Preset.ULTRA
	sd.near_field = mode == 2
	sd.scatter = mode == 2
	sd.apply()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var slugs := ["gravel_path", "cobblestone_street", "rocky_ground", "brick_wall"]
	for index in Builder.SCENE_NAMES.size():
		var scene := Builder.build(index)
		viewport.add_child(scene)
		var cam := scene.get_node("Camera") as Camera3D
		cam.current = true
		var sd := scene.get_node("GADSManager") as GADSManager
		var fields := scene.find_children("*", "GADSDisplacementField3D", true, false)
		await frames(10)
		for f: GADSDisplacementField3D in fields:
			if f.is_baking():
				await f.baked
		var views: Dictionary = scene.get_meta(&"views")
		for view_name: String in ["Eye level", "Grazing"]:
			cam.transform = Builder.view_transform(views[view_name])
			var shots: Array[Image] = []
			for mode in MODES.size():
				set_mode(sd, mode)
				await frames(40)
				var img := await capture()
				img.save_jpg(OUT + "%s_%s_%s.jpg" % [slugs[index], view_name.to_snake_case(), MODES[mode]], QUALITY)
				shots.append(img)
			strip(shots).save_jpg(OUT + "%s_%s_compare.jpg" % [slugs[index], view_name.to_snake_case()], QUALITY)
			print("captured %s, %s" % [Builder.SCENE_NAMES[index], view_name])
		if index == 0:
			cam.transform = Builder.view_transform(views["Overview"])
			set_mode(sd, 2)
			sd.debug_view = GADSManager.DebugView.FIELD_LEVELS
			await frames(30)
			(await capture()).save_jpg(OUT + "gravel_path_field_levels.jpg", QUALITY)
			sd.debug_view = GADSManager.DebugView.COST
			cam.transform = Builder.view_transform(views["Eye level"])
			await frames(20)
			(await capture()).save_jpg(OUT + "gravel_path_cost.jpg", QUALITY)
			sd.debug_view = GADSManager.DebugView.OFF
		scene.queue_free()
		await frames(5)
	# The demo with its UI, in its own SubViewport so the capture ignores the desktop size.
	viewport.queue_free()
	await frames(3)
	var ui_viewport := SubViewport.new()
	ui_viewport.size = SIZE
	ui_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(ui_viewport)
	var demo := (load("res://demo/demo_main.tscn") as PackedScene).instantiate()
	ui_viewport.add_child(demo)
	await frames(120)
	await RenderingServer.frame_post_draw
	var ui := ui_viewport.get_texture().get_image()
	ui.convert(Image.FORMAT_RGB8)
	ui.save_jpg(OUT + "demo_ui.jpg", QUALITY)
	print("captured demo_ui")
	ui_viewport.queue_free()
	await frames(5)
	quit(0)


## Three images side by side (each scaled to a third of the width), with a thin divider.
static func strip(images: Array[Image]) -> Image:
	var w := SIZE.x / 3
	var h := SIZE.y / 3 * 2
	var out := Image.create(w * images.size() + 4 * (images.size() - 1), h, false, Image.FORMAT_RGB8)
	out.fill(Color(1, 1, 1))
	for i in images.size():
		var src := images[i].duplicate() as Image
		# Centre crop to the strip cell's aspect, then scale.
		var crop_w := int(SIZE.y * float(w) / h)
		src = src.get_region(Rect2i((SIZE.x - crop_w) / 2, 0, crop_w, SIZE.y))
		src.resize(w, h, Image.INTERPOLATE_LANCZOS)
		out.blit_rect(src, Rect2i(0, 0, w, h), Vector2i(i * (w + 4), 0))
	return out
