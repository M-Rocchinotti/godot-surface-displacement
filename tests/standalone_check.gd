extends SceneTree
## Runs inside a FRESH project that contains nothing but addons/gads (see
## tests/run_standalone_check.py): builds a ground with a generated height map, a
## GADSManager node at Ultra, a GADSDisplacementField3D and a GADSPebbleScatter3D, and checks
## that the parallax relief and the field's geometry render.
var vp: SubViewport
var cam: Camera3D


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.use_hdr_2d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var scene := Node3D.new()
	vp.add_child(scene)
	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	we.environment.background_mode = Environment.BG_COLOR
	we.environment.background_color = Color.BLACK
	we.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	we.environment.ambient_light_color = Color.BLACK
	we.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	scene.add_child(we)
	var img := Image.create(128, 128, false, Image.FORMAT_RF)
	for y in 128:
		for x in 128:
			img.set_pixel(x, y, Color(0.5 + 0.5 * sin(x * TAU / 32.0) * cos(y * TAU / 32.0), 0, 0))
	img.generate_mipmaps()
	var mat := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {"height": ImageTexture.create_from_image(img)},
			{"height_m": 0.05, "height_center": 0.0, "texture_size_m": Vector2(1, 1)})
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	ground.material_override = mat
	scene.add_child(ground)
	var field := GADSDisplacementField3D.new()
	field.layers = [mat]
	scene.add_child(field)
	field.add_child(GADSPebbleScatter3D.new())
	var gads := GADSManager.new()
	gads.preset = GADSSettings.Preset.ULTRA
	scene.add_child(gads)
	cam = Camera3D.new()
	scene.add_child(cam)
	cam.look_at_from_position(Vector3(0.2, 1.7, 3.0), Vector3(0, 0, 0))
	cam.current = true
	_run(gads)


func _run(gads: GADSManager) -> void:
	for i in 60:
		await process_frame
	gads.debug_view = GADSManager.DebugView.HIT_OFFSET
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	var hit := vp.get_texture().get_image()
	var moved := 0
	for y in range(180, 360, 4):
		for x in range(0, 640, 4):
			var c := hit.get_pixel(x, y)
			if absf(c.r - 0.5) + absf(c.g - 0.5) + absf(c.b - 0.5) > 0.01:
				moved += 1
	var fields := get_nodes_in_group(&"gads_field")
	var ok := moved > 500 and fields.size() == 1 and (fields[0] as GADSDisplacementField3D).get_mesh_instance().mesh != null
	print("  pixels with a parallax offset: %d, fields: %d" % [moved, fields.size()])
	print("STANDALONE OK" if ok else "STANDALONE FAIL")
	vp.queue_free()
	for i in 3:
		await process_frame
	quit(0 if ok else 1)
