extends SceneTree
## Where the parallax relief fades out at eye level, per preset and texel size (headed run;
## --headless draws nothing):
##
##     python tools/godot.py --script tools/relief_range.gd
##
## The relief ends at the nearer of two limits: the distance fade (pom_fade_start to
## pom_fade_end) and the mip fade (the march's mip level from pom_max_lod - 1 to pom_max_lod).
## The mip level grows with the texels a pixel covers, so the mip fade depends on the texel size,
## the resolution and the viewing angle, not on the distance alone. This renders the cost debug
## view (its blue channel is the march's mip level / 8) of flat ground with the demo's materials
## from the demo's eye-level camera (1.7 m up, 70 degrees vertical field of view, looking at the
## ground 6 m ahead) at 1920 x 1080, reads the mip level and the distance of every row of the
## centre column, and writes build/relief_range.md.

const SIZE := Vector2i(1920, 1080)
## Demo texture sets of three texel sizes (tile size / resolution).
const SETS := [["clean_pebbles", "1 mm"], ["gravel_stones", "2 mm"], ["rocks_ground_05", "3 mm"]]

var viewport: SubViewport
var _lines: PackedStringArray = []


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	SDGlobals.ensure_registered()
	viewport = SubViewport.new()
	viewport.size = SIZE
	viewport.use_hdr_2d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	_run.call_deferred()


func _log(line: String) -> void:
	print(line)
	_lines.append(line)


## Mip level and distance (m) of every ground row of the centre column: [[lod, distance], ...]
## from the bottom of the screen up.
func _rows(set_id: String) -> Array:
	var scene := Node3D.new()
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	we.environment = env
	scene.add_child(we)
	var mat := SDMaterials.from_texture_set("res://demo/textures/" + set_id, SDMaterials.Mapping.WORLD, {"height_center": 0.0})
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	ground.material_override = mat
	scene.add_child(ground)
	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.far = 400.0
	scene.add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 1.7, 0.0), Vector3(0.0, 0.0, -6.0))
	cam.current = true
	viewport.add_child(scene)
	SDGlobals.set_value(SDGlobals.POM_RANGE, Vector4(1000, 2000, 0, 99))
	SDGlobals.set_value(SDGlobals.DEBUG, Vector4(2, 0.1, 0, 0))
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	var rows := []
	for py in range(SIZE.y - 1, -1, -1):
		var o := cam.project_ray_origin(Vector2(SIZE.x * 0.5, py + 0.5))
		var d := cam.project_ray_normal(Vector2(SIZE.x * 0.5, py + 0.5))
		if d.y >= -1e-4:
			break
		var lod := img.get_pixel(SIZE.x / 2, py).b * 8.0
		rows.append([lod, o.distance_to(o + d * (-o.y / d.y))])
	SDGlobals.set_value(SDGlobals.DEBUG, Vector4(0, 0.1, 0, 0))
	scene.queue_free()
	await process_frame
	return rows


## Distance (m) of the first row whose mip level reaches [param lod], or INF.
static func distance_at(rows: Array, lod: float) -> float:
	for r: Array in rows:
		if r[0] >= lod:
			return r[1]
	return INF


static func span(a: float, b: float) -> String:
	return "%s-%s m" % ["%.1f" % a if a < INF else "-", "%.1f" % b if b < INF else "-"]


func _run() -> void:
	var rows := {}
	for s: Array in SETS:
		rows[s[0]] = await _rows(s[0])
	_log("# Where the relief fades out at eye level")
	_log("")
	_log("tools/relief_range.gd: flat ground, camera 1.7 m up looking at the ground 6 m ahead, 70 degrees, %d x %d. Each cell: where the relief starts to fade and where it is gone (the nearer of the distance fade and the mip fade)." % [SIZE.x, SIZE.y])
	_log("")
	var header := "| Preset | distance fade | pom_max_lod |"
	var rule := "|---|---|---|"
	for s: Array in SETS:
		header += " %s texels (%s) |" % [s[1], s[0]]
		rule += "---|"
	_log(header)
	_log(rule)
	for preset: SDSettings.Preset in [SDSettings.Preset.LOW, SDSettings.Preset.MEDIUM, SDSettings.Preset.HIGH, SDSettings.Preset.EPIC]:
		var st := SDSettings.create_preset(preset)
		var line := "| %s | %s | %.1f |" % [SDSettings.preset_name(preset), span(st.pom_fade_start, st.pom_fade_end), st.pom_max_lod]
		for s: Array in SETS:
			var r: Array = rows[s[0]]
			var start := minf(st.pom_fade_start, distance_at(r, st.pom_max_lod - 1.0))
			var end := minf(st.pom_fade_end, distance_at(r, st.pom_max_lod))
			line += " %s |" % span(start, end)
		_log(line)
	_log("")
	var lods := "Mip level by distance:"
	for s: Array in SETS:
		var r: Array = rows[s[0]]
		lods += " %s:" % s[1]
		for dist: float in [4.0, 6.0, 8.0, 12.0, 18.0, 25.0, 35.0]:
			for row: Array in r:
				if row[1] >= dist:
					lods += " %.0f m %.1f," % [dist, row[0]]
					break
	_log(lods.trim_suffix(","))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))
	var f := FileAccess.open("res://build/relief_range.md", FileAccess.WRITE)
	f.store_string("\n".join(_lines) + "\n")
	f.close()
	viewport.queue_free()
	await process_frame
	quit()
