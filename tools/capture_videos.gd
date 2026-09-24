extends SceneTree
## Renders the showcase clips frame by frame into build/video_frames/<clip>/ (headed run;
## --headless draws nothing). tools/make_videos.py runs this and encodes the MP4s:
##
##     python tools/make_videos.py
##     python tools/godot.py --script tools/capture_videos.gd -- --only=gravel   # frames only
##
## Deterministic: the camera follows a fixed path in time t = frame / FPS (real-time speed, one
## rendered frame per video frame, whatever the machine's frame rate), after a warm-up at the
## first pose with the ground bakes finished. Modes: "full" = Epic (parallax, self-shadowing,
## near-camera geometry, pebbles), "flat" = preset Off (normal mapping only).

const Builder := preload("res://demo/scenes/demo_builder.gd")
const FPS := 30
const OUT := "res://build/video_frames/"

var viewport: SubViewport


## [name, scene index, mode, seconds, size, pose Callable(t) -> [eye, target]]
func clips() -> Array:
	var walk_speed := 1.2
	var gravel_walk := func(t: float) -> Array:
		var z := 8.5 - walk_speed * t
		var x := Builder.path_x(z)
		var ahead := z - 4.5
		return [Vector3(x, Builder.terrain_height(x, z) + 1.7, z),
				Vector3(Builder.path_x(ahead), Builder.terrain_height(Builder.path_x(ahead), ahead), ahead)]
	var gravel_grazing := func(t: float) -> Array:
		# A low sideways sweep across the path, looking along it.
		var z := 5.0 - 0.15 * t
		var centre := Builder.path_x(z)
		var x := centre - 1.0 + 2.0 * t / 7.0
		var look_z := z - 2.5
		var look_x := Builder.path_x(look_z) + (x - centre) * 0.4
		return [Vector3(x, Builder.terrain_height(x, z) + 0.32, z),
				Vector3(look_x, Builder.terrain_height(look_x, look_z) + 0.02, look_z)]
	var street_walk := func(t: float) -> Array:
		var z := 9.0 - walk_speed * t
		return [Vector3(0.8, 1.7, z), Vector3(0.3, 0.0, z - 8.0)]
	var street_grazing := func(t: float) -> Array:
		var x := -1.6 + 3.2 * t / 7.0
		return [Vector3(x, 0.28, 4.2 - 0.1 * t), Vector3(x * 0.6, 0.05, 1.2 - 0.1 * t)]
	var wall_walk := func(t: float) -> Array:
		# Along the brick wall, past the parallax box, the baked hero wall and the rubble.
		var x := -3.2 + 0.95 * t
		return [Vector3(x, 1.6, 1.4), Vector3(x + 1.8, 0.9, -3.0)]
	var wide := Vector2i(1280, 720)
	var half := Vector2i(960, 1080)
	return [
		["gravel_path_walk", 0, "full", 7.0, wide, gravel_walk],
		["gravel_path_grazing", 0, "full", 7.0, wide, gravel_grazing],
		["cobblestone_street_walk", 1, "full", 7.0, wide, street_walk],
		["cobblestone_street_grazing", 1, "full", 7.0, wide, street_grazing],
		["brick_wall_walk", 3, "full", 7.0, wide, wall_walk],
		["compare_gravel_path_grazing_flat", 0, "flat", 7.0, half, gravel_grazing],
		["compare_gravel_path_grazing_full", 0, "full", 7.0, half, gravel_grazing],
		["compare_cobblestone_street_grazing_flat", 1, "flat", 7.0, half, street_grazing],
		["compare_cobblestone_street_grazing_full", 1, "full", 7.0, half, street_grazing],
	]


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	root.size = Vector2i(640, 360)
	SDGlobals.ensure_registered()
	_run()


func _run() -> void:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	for clip: Array in clips():
		var clip_name: String = clip[0]
		if not only.is_empty() and not clip_name.contains(only):
			continue
		await _render(clip_name, clip[1], clip[2], clip[3], clip[4], clip[5])
	quit(0)


func _render(clip_name: String, scene_index: int, mode: String, seconds: float, size: Vector2i, pose: Callable) -> void:
	var dir := OUT + clip_name + "/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + f))
	viewport = SubViewport.new()
	viewport.size = size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene := Builder.build(scene_index)
	viewport.add_child(scene)
	var cam := scene.get_node("Camera") as Camera3D
	cam.current = true
	var sd := scene.get_node("SurfaceDisplacement") as SurfaceDisplacement
	sd.preset = SDSettings.Preset.EPIC if mode == "full" else SDSettings.Preset.OFF
	sd.near_field = mode == "full"
	sd.scatter = mode == "full"
	_place(cam, pose.call(0.0))
	await process_frame
	for field: DisplacementField3D in scene.find_children("*", "DisplacementField3D", true, false):
		if field.is_baking():
			await field.baked
	for i in 30:
		await process_frame
	var frames := int(round(seconds * FPS))
	for i in frames:
		_place(cam, pose.call(float(i) / FPS))
		await process_frame
		await RenderingServer.frame_post_draw
		var img := viewport.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		img.save_jpg(dir + "%05d.jpg" % i, 0.95)
	print("captured %s: %d frames of %s" % [clip_name, frames, size])
	viewport.queue_free()
	await process_frame
	await process_frame


static func _place(cam: Camera3D, eye_target: Array) -> void:
	cam.look_at_from_position(eye_target[0], eye_target[1])
