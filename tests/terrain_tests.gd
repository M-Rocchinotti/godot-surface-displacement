extends SceneTree
## Tests of GADSTerrain3D: heights, chunk LODs and their seams, layer rules, collision, the
## ground data of its detail field, rendering and LOD selection by the engine:
##     python tools/godot.py --script tests/terrain_tests.gd
## Exit code 0 = all passed. Run a subset with: -- --only=name,name

const Harness := preload("res://tests/lib/gads_harness.gd")
const SIZE := Vector2i(640, 360)
const MAP := 129

var h: Harness
var _passed := 0
var _failed := 0


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	GADSGlobals.ensure_registered()
	h = Harness.new(self)
	h.make_viewport(SIZE, true)
	_run()


func _run() -> void:
	await process_frame # _initialize runs before the root enters the tree.
	await _test("heights_follow_the_heightmap", test_heights)
	await _test("chunk_lods_and_skirts", test_lods)
	await _test("layers_by_rules_and_splat_map", test_layers)
	await _test("collision_matches_the_surface", test_collision)
	await _test("detail_field_ground_data", test_ground_data)
	await _test("rebuilds_once_per_change", test_rebuild)
	await _test("streams_chunks_around_the_camera", test_streaming)
	await _test("paints_layers_at_runtime", test_painting)
	await _test("navigation_mesh_follows_the_terrain", test_navigation)
	if DisplayServer.get_name() != "headless":
		await _test("renders_front_faces_and_coarser_far_away", test_render)
	print("\nterrain tests: %d passed, %d failed" % [_passed, _failed])
	h.clear_scene()
	h.viewport.queue_free()
	await h.frames(3)
	quit(1 if _failed > 0 else 0)


func _test(test_name: String, fn: Callable) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			var wanted := false
			for part in arg.trim_prefix("--only=").split(","):
				wanted = wanted or test_name.contains(part)
			if not wanted:
				return
	print("\n== %s" % test_name)
	GADSSettings.create_preset(GADSSettings.Preset.HIGH).apply_globals()
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))
	await fn.call()


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)


# --- Fixtures -----------------------------------------------------------------------------------

## Hills: smooth bumps plus a steep ridge, 0..1, at heightmap texel (x, y) of a MAP x MAP map.
static func hill(x: float, y: float) -> float:
	var u := x / (MAP - 1)
	var v := y / (MAP - 1)
	var bumps := 0.35 + 0.25 * sin(u * TAU * 2.0) * cos(v * TAU * 1.5)
	var ridge := 0.4 * smoothstep(0.55, 0.62, u) * (1.0 - smoothstep(0.62, 0.9, u))
	return clampf(bumps + ridge, 0.0, 1.0)


static func hill_texture() -> ImageTexture:
	var img := Image.create(MAP, MAP, false, Image.FORMAT_RF)
	for y in MAP:
		for x in MAP:
			img.set_pixel(x, y, Color(hill(x, y), 0, 0))
	return ImageTexture.create_from_image(img)


static func layer_material(tile: float, color: Color) -> ShaderMaterial:
	var img := Image.create(64, 64, false, Image.FORMAT_RF)
	for y in 64:
		for x in 64:
			img.set_pixel(x, y, Color(0.5 + 0.5 * sin(x * 0.4) * sin(y * 0.4), 0, 0))
	img.generate_mipmaps()
	var albedo := Image.create(4, 4, false, Image.FORMAT_RGB8)
	albedo.fill(color)
	return GADSMaterials.create(GADSMaterials.Mapping.WORLD,
		{"height": ImageTexture.create_from_image(img), "albedo": ImageTexture.create_from_image(albedo)},
		{"height_m": 0.04, "height_center": 0.0, "texture_size_m": Vector2(tile, tile)}, GADSMaterials.Quality.POM)


## A 64 m terrain over the hills (40 m high), 0.5 m spacing, 32-quad chunks.
func make_terrain(params := {}) -> GADSTerrain3D:
	var t := GADSTerrain3D.new()
	t.name = "Terrain"
	t.heightmap = hill_texture()
	t.size = Vector2(64, 64)
	t.height_scale = 40.0
	t.vertex_spacing = 0.5
	t.chunk_quads = 32
	t.lod_levels = 5
	t.detail_field = false
	for k: String in params:
		t.set(k, params[k])
	return t


# --- Tests --------------------------------------------------------------------------------------

func test_heights() -> void:
	var t := make_terrain()
	root.add_child(t)
	check(t.get_extent() == Vector2(64, 64) and t.get_grid_size() == Vector2i(129, 129) and t.get_chunks().size() == 16,
		"64 m at 0.5 m: 129 x 129 vertices in 4 x 4 chunks (%s, %s, %d)" % [t.get_extent(), t.get_grid_size(), t.get_chunks().size()])
	var worst := 0.0
	for z in range(0, 129, 7):
		for x in range(0, 129, 5):
			var p := Vector3(-32.0 + x * 0.5, 0.0, -32.0 + z * 0.5)
			worst = maxf(worst, absf(t.get_height(p) - 40.0 * hill(x, z)))
	print("  largest difference at the vertices %.4f mm" % (worst * 1000.0))
	check(worst < 1e-4, "vertex heights are the heightmap's")
	check(is_nan(t.get_height(Vector3(40, 0, 0))), "no height outside the terrain")
	# Between vertices: the triangles' plane (the diagonal from (1, 0) to (0, 1) of each quad).
	var a := t.get_height(Vector3(-32.0, 0, -32.0))
	var b := t.get_height(Vector3(-31.5, 0, -32.0))
	var c := t.get_height(Vector3(-32.0, 0, -31.5))
	check(absf(t.get_height(Vector3(-31.8, 0, -31.9)) - (a + 0.4 * (b - a) + 0.2 * (c - a))) < 1e-4, "between vertices: the triangle's plane")
	t.position = Vector3(10, 5, -3)
	check(absf(t.get_height(Vector3(10, 0, -3)) - (5.0 + 40.0 * hill(64, 64))) < 1e-4, "heights follow the node's position")
	var n := t.get_normal(Vector3(10 + 0.4 * 32, 0, -3))
	check(n.is_normalized() and n.y > 0.0, "a normal points up out of the ground")
	t.queue_free()
	await process_frame


func test_lods() -> void:
	var t := make_terrain()
	root.add_child(t)
	var chunk := t.get_chunks()[5]
	var surface := RenderingServer.mesh_get_surface(chunk.mesh.get_rid(), 0)
	var lods: Array = surface.get("lods", [])
	var base := (chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	var vertex_count := (chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var index_bytes := 2 if vertex_count <= 65535 else 4
	var counts: Array[int] = []
	var keys: Array[float] = []
	for lod: Dictionary in lods:
		keys.append(lod["edge_length"])
		counts.append((lod["index_data"] as PackedByteArray).size() / (3 * index_bytes))
	print("  %d triangles, LODs %s, keys %s m" % [base, counts, keys])
	check(lods.size() == 4, "a 32-quad chunk with 5 levels has 4 LODs")
	var halving := true
	var increasing := true
	for k in counts.size():
		var grid := 2 * (32 >> (k + 1)) * (32 >> (k + 1))
		var skirts := 2 * 4 * (32 >> (k + 1))
		halving = halving and counts[k] == grid + skirts
		increasing = increasing and (k == 0 or keys[k] > keys[k - 1])
	check(base == 2 * 32 * 32 + 2 * 4 * 32 and halving, "each LOD halves the quads per side (skirts included)")
	check(increasing, "LOD keys increase")
	# A key is the LOD's height error (m): check it against the heights.
	var arrays := chunk.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var key_ok := true
	for k in lods.size():
		var s := 2 << k
		var worst := 0.0
		for z in 33:
			for x in 33:
				var x0 := mini((x / s) * s, 32 - s)
				var z0 := mini((z / s) * s, 32 - s)
				var fx := float(x - x0) / s
				var fz := float(z - z0) / s
				var h00 := v[z0 * 33 + x0].y
				var h10 := v[z0 * 33 + x0 + s].y
				var h01 := v[(z0 + s) * 33 + x0].y
				var h11 := v[(z0 + s) * 33 + x0 + s].y
				var hc := h00 + fx * (h10 - h00) + fz * (h01 - h00) if fx + fz <= 1.0 else h11 + (1.0 - fx) * (h01 - h11) + (1.0 - fz) * (h10 - h11)
				worst = maxf(worst, absf(v[z * 33 + x].y - hc))
		key_ok = key_ok and absf(worst - keys[k]) < 1e-4 + 1e-5 * k
	check(key_ok, "each key is its LOD's largest height error")
	# Skirts: each chunk's hang deeper than the widest gap two LODs can leave on its -Z border (the
	# neighbour there interpolates the same border heights at its own LOD).
	var covered := true
	var tightest := INF
	for c: MeshInstance3D in t.get_chunks():
		var cv: PackedVector3Array = c.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var skirt_depth := INF
		for r in 32: # the first ring side is the -Z border, x = 0..31
			skirt_depth = minf(skirt_depth, cv[r].y - cv[33 * 33 + r].y)
		var widest_gap := 0.0
		for sa in [1, 2, 4, 8, 16]:
			for sb in [1, 2, 4, 8, 16]:
				for x in 33:
					widest_gap = maxf(widest_gap, absf(_edge_interp(cv, x, sa) - _edge_interp(cv, x, sb)))
		covered = covered and skirt_depth >= widest_gap
		tightest = minf(tightest, skirt_depth - widest_gap)
	print("  smallest margin of a skirt over the widest gap on its border %.3f m" % tightest)
	check(covered, "skirts are deeper than any gap between LODs")
	t.queue_free()
	await process_frame


## Height along a chunk's -Z border at x, interpolated at stride s.
static func _edge_interp(v: PackedVector3Array, x: int, s: int) -> float:
	var x0 := mini((x / s) * s, 32 - s)
	return lerpf(v[x0].y, v[x0 + s].y, float(x - x0) / s)


func test_layers() -> void:
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var rock := layer_material(4.0, Color(0.5, 0.5, 0.5))
	var snow := layer_material(1.0, Color(1, 1, 1))
	var t := make_terrain({"layers": [grass, rock, snow] as Array[ShaderMaterial], "slope_range": Vector2(30, 40), "height_band": Vector2(25, 27)})
	root.add_child(t)
	# The ridge's flank (u 0.55..0.62 rises 0.4 * 40 m over 4.5 m) is steep; low ground is flat-ish.
	var steep := Vector3(-32.0 + 0.585 * 64.0, 0, 0)
	var steep_n := t.get_normal(steep)
	var w_steep := t.get_layer_weights(steep)
	print("  ridge flank %.0f deg: weights %s" % [rad_to_deg(acos(steep_n.y)), w_steep])
	check(w_steep.x > 0.9, "rock (layer 2) covers the steep flank")
	var low := Vector3.ZERO
	var best := INF
	for z in range(0, 129, 4):
		for x in range(0, 60, 4):
			var p := Vector3(-32.0 + x * 0.5, 0, -32.0 + z * 0.5)
			var y := t.get_height(p)
			if y < best and t.get_normal(p).y > 0.97:
				best = y
				low = p
	check(t.get_layer_weights(low) == Vector2.ZERO, "a low, gentle spot is the first layer only (%.1f m)" % best)
	var high := Vector3.ZERO
	best = -INF
	for z in range(0, 129, 4):
		for x in range(0, 129, 4):
			var p := Vector3(-32.0 + x * 0.5, 0, -32.0 + z * 0.5)
			if t.get_height(p) > best:
				best = t.get_height(p)
				high = p
	check(t.get_layer_weights(high).y > 0.99, "snow (layer 3) covers the peak (%.1f m)" % best)
	var mat := t.get_material() as ShaderMaterial
	var info := GADSMaterials.parse(mat.shader)
	check(info.get("layered", false) and info["mapping"] == GADSMaterials.Mapping.WORLD, "the layers combine into a layered world material")
	check(mat.get_shader_parameter("layer1_height_texture") == rock.get_shader_parameter("height_texture")
		and mat.get_shader_parameter("layer2_albedo_texture") == snow.get_shader_parameter("albedo_texture"), "each layer keeps its textures")
	check(is_equal_approx(mat.get_shader_parameter("layer1_scale"), 0.5) and is_equal_approx(mat.get_shader_parameter("layer2_scale"), 2.0),
		"each layer keeps its texture size (scale relative to the first)")
	check(mat.get_shader_parameter("layer1_mask_channel") == GADSMaterials.LayerMask.VERTEX_R
		and mat.get_shader_parameter("layer2_mask_channel") == GADSMaterials.LayerMask.VERTEX_G
		and is_equal_approx(mat.get_shader_parameter("layer1_amount"), 1.0), "layers 2 and 3 lie where vertex colour R and G say")
	var colors: PackedColorArray = t.get_chunks()[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	check(colors.size() > 0, "the chunks carry the weights as vertex colours")
	# A splat map replaces the rules.
	var splat := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	splat.fill(Color(0, 0, 0, 1))
	splat.fill_rect(Rect2i(0, 0, 4, 8), Color(1, 0, 0, 1))
	t.splatmap = ImageTexture.create_from_image(splat)
	t.rebuild()
	check(t.get_layer_weights(Vector3(-20, 0, 0)) == Vector2(1, 0) and t.get_layer_weights(Vector3(20, 0, 0)) == Vector2.ZERO,
		"a splat map puts the layers where it says")
	t.queue_free()
	await process_frame


func test_collision() -> void:
	var t := make_terrain()
	t.position = Vector3(3, -2, 1)
	root.add_child(t)
	await physics_frame
	await physics_frame
	var space := t.get_world_3d().direct_space_state
	var worst := 0.0
	var hits := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 200:
		var p := Vector3(3.0 + rng.randf_range(-31.5, 31.5), 0.0, 1.0 + rng.randf_range(-31.5, 31.5))
		var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 100, 0), p - Vector3(0, 100, 0))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		hits += 1
		worst = maxf(worst, absf((hit["position"] as Vector3).y - t.get_height(p)))
	print("  %d of 200 rays hit; largest difference %.2f mm" % [hits, worst * 1000.0])
	check(hits == 200 and worst < 0.005, "the collision shape is the drawn surface")
	t.collision = false
	await process_frame
	check(t.get_collision_body() == null, "collision can be turned off")
	t.queue_free()
	await process_frame


func test_ground_data() -> void:
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var rock := layer_material(4.0, Color(0.5, 0.5, 0.5))
	# 10 m high: most of it gentle enough for the field (steeper than 39 degrees is a step to it).
	var t := make_terrain({"layers": [grass, rock] as Array[ShaderMaterial], "slope_range": Vector2(20, 30), "height_layer": 0,
		"detail_field": true, "height_scale": 10.0})
	t.position = Vector3(0, 1, 0)
	root.add_child(t)
	var field := t.get_detail_field()
	check(field != null and field.layers.size() == 2 and field.ground_bake != null, "the detail field takes the terrain's layers and ground data")
	var bake := field.ground_bake
	check(is_equal_approx(bake.texel_size, 0.25) and bake.get_size() == Vector2i(257, 257), "the ground data has half the vertex spacing (%s at %.2f m)" % [bake.get_size(), bake.texel_size])
	check(absf(bake.sample(Vector2(-32.0 + 0.5 * 7, -32.0 + 0.5 * 9))["height"] - t.get_height(Vector3(-32.0 + 0.5 * 7, 0, -32.0 + 0.5 * 9))) < 1e-3,
		"its texel centres are on the vertices")
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var layer_ok := 0
	var n := 0
	for i in 400:
		var p := Vector3(rng.randf_range(-31, 31), 0, rng.randf_range(-31, 31))
		var s := bake.sample(Vector2(p.x, p.z))
		var weights: Color = s["weights"]
		if weights.r + weights.g + weights.b + weights.a < 0.999:
			continue # Not all displaced by the field there (steps: steep ground).
		n += 1
		worst = maxf(worst, absf(float(s["height"]) - t.get_height(p)))
		var w := t.get_layer_weights(p)
		var dominant := 1 if w.x >= 0.5 else 0
		if (weights.g > weights.r) == (dominant == 1) or absf(w.x - 0.5) < 0.2:
			layer_ok += 1
	print("  %d points: largest height difference %.1f mm; dominant layer right at %d" % [n, worst * 1000.0, layer_ok])
	check(n > 100 and worst < field.lift, "the field's ground is the drawn surface within its lift (%.1f mm)" % (field.lift * 1000.0))
	check(layer_ok == n, "the field shows the dominant layer")
	# The surface with its relief: the field's, above the triangles by at most a layer's depth.
	var lo := INF
	var hi := -INF
	var same := true
	for i in 200:
		var p := Vector3(rng.randf_range(-31, 31), 0, rng.randf_range(-31, 31))
		var surface := t.get_surface_height(p)
		var from_field := field.get_surface_height(p)
		same = same and (is_nan(from_field) or is_equal_approx(surface, from_field))
		var above := surface - t.get_height(p)
		lo = minf(lo, above)
		hi = maxf(hi, above)
	print("  surface with relief: %.1f to %.1f mm above the triangles" % [lo * 1000.0, hi * 1000.0])
	check(same and lo > -field.lift and hi > 0.005 and hi <= 0.06, "get_surface_height() is the detail field's relief on the terrain, the ground where it does not displace")
	t.queue_free()
	await process_frame


func test_rebuild() -> void:
	var t := make_terrain()
	root.add_child(t)
	var count := [0]
	t.rebuilt.connect(func() -> void: count[0] += 1)
	var before := t.get_height(Vector3(5, 0, 5))
	t.height_scale = 20.0
	t.height_offset = 3.0
	t.vertex_spacing = 1.0
	await process_frame
	await process_frame
	check(count[0] == 1, "three changes in a frame rebuild once (%d)" % count[0])
	check(absf(t.get_height(Vector3(5, 0, 5)) - (3.0 + (before) * 0.5)) < 0.5 and t.get_grid_size() == Vector2i(65, 65),
		"the new heights and spacing apply")
	print("  rebuilt 64 m at 1 m in %.0f ms" % (t.get_build_seconds() * 1000.0))
	t.queue_free()
	await process_frame


func test_render() -> void:
	var s := h.new_lit_scene(Color(1, 1, 1))
	var t := make_terrain({"layers": [layer_material(2.0, Color(0.2, 0.6, 0.2))] as Array[ShaderMaterial]})
	s.add_child(t)
	var cam := h.add_camera(Vector3(0, 80, 0.01), Vector3.ZERO, 60.0)
	await h.frames(3)
	var img := await h.capture()
	var c := img.get_pixel(SIZE.x / 2, SIZE.y / 2)
	print("  from above: %s" % c)
	check(c.g > 0.3 and c.g > c.r, "seen from above the terrain draws (front faces wind the right way)")
	cam.look_at_from_position(Vector3(0, -30, 0.01), Vector3.ZERO)
	await h.frames(2)
	img = await h.capture()
	c = img.get_pixel(SIZE.x / 2, SIZE.y / 2)
	check(c.r < 0.01 and c.g < 0.01, "seen from below it is culled")
	# The engine picks coarser LODs far away.
	var vp := h.viewport.get_viewport_rid()
	cam.look_at_from_position(Vector3(0, 45, 20), Vector3(0, 10, 0))
	await h.frames(3)
	var near := RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	cam.look_at_from_position(Vector3(0, 400, 600), Vector3(0, 10, 0))
	cam.far = 2000.0
	await h.frames(3)
	var far := RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	print("  primitives near %d, far %d" % [near, far])
	check(far * 4 < near, "far away the engine draws coarser LODs")
	h.clear_scene()
	await process_frame


## A streamed terrain builds the chunks near the camera on worker threads, the same as the whole
## terrain's, frees those left far behind, gives each a collision shape and the detail field a
## ground window around the camera.
func test_streaming() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.position = Vector3(-24, 30, -24)
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var t := make_terrain({"stream_radius": 20.0, "layers": [grass] as Array[ShaderMaterial], "detail_field": true, "height_scale": 10.0})
	holder.add_child(t)
	t.stream_camera = t.get_path_to(cam)
	await _settle(t)
	var expected := _chunks_within(t, Vector2(-24, -24), 20.0)
	var built := _chunk_keys(t)
	print("  %d of %d chunks built near (-24, -24): %s" % [built.size(), t.get_chunk_grid().x * t.get_chunk_grid().y, built])
	check(built == expected and built.size() < 16, "exactly the chunks within the radius are built")
	check(t.get_collision_body() != null and t.get_collision_body().get_child_count() == built.size(), "each with its own collision shape")
	# The same chunk as the whole terrain builds.
	var whole := make_terrain({"height_scale": 10.0})
	root.add_child(whole)
	var a: PackedVector3Array = t.get_chunks()[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var key := Vector2i(int(String(t.get_chunks()[0].name).get_slice("_", 1)), int(String(t.get_chunks()[0].name).get_slice("_", 2)))
	var same: MeshInstance3D = null
	for c in whole.get_chunks():
		if c.name == t.get_chunks()[0].name:
			same = c
	var b: PackedVector3Array = same.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] if same != null else PackedVector3Array()
	var worst := 0.0
	for i in mini(a.size(), b.size()):
		worst = maxf(worst, a[i].distance_to(b[i]))
	check(a.size() == b.size() and worst < 1e-5, "a streamed chunk is the whole terrain's chunk %s (largest difference %.6f m)" % [key, worst])
	var p := Vector3(-22.3, 0, -25.1)
	check(absf(t.get_height(p) - whole.get_height(p)) < 1e-5, "heights are the same streamed or not")
	whole.queue_free()
	await physics_frame
	await physics_frame
	var hit := t.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 50, 0), p - Vector3(0, 50, 0)))
	check(not hit.is_empty() and absf((hit["position"] as Vector3).y - t.get_height(p)) < 0.005, "the streamed collision is the surface")
	var field := t.get_detail_field()
	var bake := field.ground_bake if field != null else null
	check(bake != null and field.visible and bake.get_rect().has_point(Vector2(-24, -24)) and bake.get_rect().size.x < 64.0,
		"the detail field's ground data is a window around the camera (%s)" % (bake.get_rect() if bake != null else "none"))
	# Fly to the opposite corner: the old chunks go, new ones come, the window follows.
	var before := built
	cam.position = Vector3(24, 30, 24)
	await _settle(t)
	built = _chunk_keys(t)
	expected = _chunks_within(t, Vector2(24, 24), 20.0)
	# Old chunks stay until well beyond the radius (1.25 x radius + a chunk: no rebuilding back and
	# forth at the edge).
	var kept := _chunks_within(t, Vector2(24, 24), 20.0 * 1.25 + t.chunk_quads * t.get_vertex_spacing()).filter(func(k: Vector2i) -> bool: return before.has(k))
	for k in kept:
		if not expected.has(k):
			expected.append(k)
	expected.sort()
	check(built == expected and not built.has(Vector2i(0, 0)), "after flying across: the chunks there, the far old ones gone (%s)" % [built])
	bake = field.ground_bake
	check(bake != null and bake.get_rect().has_point(Vector2(24, 24)), "and the ground window followed")
	holder.queue_free()
	await process_frame


func _settle(t: GADSTerrain3D) -> void:
	var stable := 0
	var last := -1
	for i in 600:
		await process_frame
		var n := t.get_chunks().size()
		stable = stable + 1 if n == last and not t.is_streaming_busy() else 0
		last = n
		if stable >= 5:
			return


static func _chunk_keys(t: GADSTerrain3D) -> Array:
	var out := []
	for c in t.get_chunks():
		var parts := String(c.name).split("_")
		out.append(Vector2i(int(parts[1]), int(parts[2])))
	out.sort()
	return out


static func _chunks_within(t: GADSTerrain3D, xz: Vector2, radius: float) -> Array:
	var out := []
	var grid := t.get_chunk_grid()
	var side := t.chunk_quads * t.get_vertex_spacing()
	var origin := -t.get_extent() * 0.5
	for cz in grid.y:
		for cx in grid.x:
			var r := Rect2(origin + Vector2(cx, cz) * side, Vector2(side, side))
			if xz.distance_to(xz.clamp(r.position, r.end)) <= radius:
				out.append(Vector2i(cx, cz))
	out.sort()
	return out


## Painting a layer at runtime: the weights, the chunks' vertex colours and the detail field's
## ground data follow; erasing and saving the painted weights work; a streamed terrain builds
## chunks with what was painted before they existed.
func test_painting() -> void:
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var mud := layer_material(1.0, Color(0.4, 0.3, 0.2))
	var t := make_terrain({"layers": [grass, mud] as Array[ShaderMaterial], "slope_layer": 0, "height_layer": 0, "detail_field": true, "height_scale": 5.0})
	root.add_child(t)
	var p := Vector3(-10.0, 0, 6.0)
	check(t.get_layer_weights(p) == Vector2.ZERO, "before: the first layer only")
	t.paint_layer(p, 3.0, 1, 1.0, 0.5)
	var w := t.get_layer_weights(p)
	var edge := t.get_layer_weights(p + Vector3(2.6, 0, 0))
	var outside := t.get_layer_weights(p + Vector3(3.5, 0, 0))
	print("  weights: centre %s, near the edge %s, outside %s" % [w, edge, outside])
	check(w.is_equal_approx(Vector2(1, 0)) and edge.x > 0.0 and edge.x < 1.0 and outside == Vector2.ZERO, "the painted layer takes over in the middle and fades out at the edge")
	# The vertex colour of the chunk under p.
	var colour := Color()
	for c in t.get_chunks():
		var arrays := c.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in v.size():
			if Vector2(v[i].x, v[i].z).is_equal_approx(Vector2(p.x, p.z)):
				colour = (arrays[Mesh.ARRAY_COLOR] as PackedColorArray)[i]
	check(colour.r > 0.99, "the chunk's vertex colours follow (R %.2f)" % colour.r)
	var s: Dictionary = t.get_detail_field().ground_bake.sample(Vector2(p.x, p.z))
	check((s["weights"] as Color).g > 0.99, "the detail field shows the painted layer there")
	var saved := t.get_painted_weights()
	t.paint_layer(p, 5.0, 0, 1.0, 0.0)
	check(t.get_layer_weights(p) == Vector2.ZERO, "painting layer 0 erases")
	t.set_painted_weights(saved)
	check(t.get_layer_weights(p).is_equal_approx(Vector2(1, 0)), "painted weights can be saved and given back")
	t.clear_paint()
	check(t.get_layer_weights(p) == Vector2.ZERO, "clear_paint() goes back to the rules")
	t.queue_free()
	# Streaming: paint where no chunk is yet, then fly there.
	var holder := Node3D.new()
	root.add_child(holder)
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.position = Vector3(-24, 30, -24)
	var st := make_terrain({"stream_radius": 12.0, "layers": [grass, mud] as Array[ShaderMaterial], "slope_layer": 0, "height_layer": 0, "detail_field": false})
	holder.add_child(st)
	st.stream_camera = st.get_path_to(cam)
	await _settle(st)
	var far := Vector3(20.0, 0, 20.0)
	st.paint_layer(far, 2.0, 1)
	cam.position = Vector3(20, 30, 20)
	await _settle(st)
	var found := Color()
	for c in st.get_chunks():
		var arrays := c.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in v.size():
			if Vector2(v[i].x, v[i].z).is_equal_approx(Vector2(far.x, far.z)):
				found = (arrays[Mesh.ARRAY_COLOR] as PackedColorArray)[i]
	check(found.r > 0.99, "a streamed chunk built later carries what was painted there")
	holder.queue_free()
	await process_frame


## A navigation mesh baked from a scene with a terrain (and its detail field) follows the
## terrain, from its chunk meshes or its collision shapes; the field's lattice mesh (placed by its
## shader) adds nothing.
func test_navigation() -> void:
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var holder := Node3D.new()
	root.add_child(holder)
	var t := make_terrain({"layers": [grass] as Array[ShaderMaterial], "detail_field": true, "height_scale": 6.0})
	holder.add_child(t)
	await process_frame
	for geometry in [NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES, NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS]:
		var nav := NavigationMesh.new()
		nav.geometry_parsed_geometry_type = geometry
		nav.cell_size = 0.25
		nav.cell_height = 0.05
		nav.agent_max_slope = 50.0
		nav.agent_max_climb = 0.5
		nav.detail_sample_distance = 1.0
		nav.detail_sample_max_error = 0.05
		var source := NavigationMeshSourceGeometryData3D.new()
		NavigationServer3D.parse_source_geometry_data(nav, source, holder)
		NavigationServer3D.bake_from_source_geometry_data(nav, source)
		var vertices := nav.get_vertices()
		var worst := 0.0
		for v in vertices:
			worst = maxf(worst, absf(v.y - t.get_height(v)))
		var label := "meshes" if geometry == NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES else "collision"
		print("  from %s: %d vertices, %d polygons, largest height difference %.2f m" % [label, vertices.size(), nav.get_polygon_count(), worst])
		check(nav.get_polygon_count() > 50 and worst < 0.4, "a navigation mesh baked from the terrain's %s follows it" % label)
	holder.queue_free()
	await process_frame
