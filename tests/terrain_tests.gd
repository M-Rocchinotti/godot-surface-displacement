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
	await _test("holes", test_holes)
	await _test("rebuilds_once_per_change", test_rebuild)
	await _test("streams_chunks_around_the_camera", test_streaming)
	await _test("paints_layers_at_runtime", test_painting)
	await _test("navigation_mesh_follows_the_terrain", test_navigation)
	await _test("occluders_stay_below_the_surface", test_occluders)
	await _test("sculpts_and_paints", test_editing)
	await _test("erodes_and_generates", test_erosion)
	await _test("roads_along_paths", test_roads)
	await _test("impacts_dent_the_ground", test_impact)
	await _test("relief_collider_follows_the_feet", test_relief_collider)
	await _test("native_chunks", test_native_chunks)
	await _test("native_grid", test_native_grid)
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

## GADSReliefCollider3D: a height-field patch around a target on the relief the terrain's detail
## field draws (rays hit get_surface_height() within millimetres, above the terrain's own
## collision on the stones); it follows the target sampling only the new strip, and a teleport
## samples all of it.
func test_relief_collider() -> void:
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var t := make_terrain({"layers": [grass] as Array[ShaderMaterial], "detail_field": true, "height_scale": 6.0})
	root.add_child(t)
	var marker := Node3D.new()
	marker.position = Vector3(0, 0, 0)
	root.add_child(marker)
	var feet := GADSReliefCollider3D.new()
	feet.target = marker.get_path()
	feet.source = t.get_path()
	feet.spacing = 0.05
	feet.resolution = 33
	feet.collision_layer = 1 << 10
	root.add_child(feet)
	for i in 3:
		await physics_frame
	var first := feet.last_sampled
	var space := marker.get_world_3d().direct_space_state
	var measure := func(centre: Vector3) -> Array:
		var worst := 0.0
		var above := 0
		var hits := 0
		var rng := RandomNumberGenerator.new()
		rng.seed = 5
		for i in 40:
			var p := centre + Vector3(rng.randf_range(-0.7, 0.7), 0, rng.randf_range(-0.7, 0.7))
			var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 20, 0), p - Vector3(0, 20, 0), 1 << 10)
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			hits += 1
			worst = maxf(worst, absf(hit["position"].y - t.get_surface_height(p)))
			if hit["position"].y > t.get_height(p) + 0.01:
				above += 1
		return [hits, worst, above]
	var at := measure.call(marker.position) as Array
	print("  %d of 40 rays hit, largest difference to get_surface_height() %.2f mm, %d above the terrain's triangles; %d samples" % [at[0], at[1] * 1000.0, at[2], first])
	check(at[0] == 40 and at[1] < 0.004 and at[2] > 5 and first == 33 * 33, "rays land on the relief (within 4 mm), above the smooth ground on the stones")
	# A character's foot (a 5 cm sphere) falling onto it comes to rest on the relief.
	var body := CharacterBody3D.new()
	var foot := CollisionShape3D.new()
	var ball := SphereShape3D.new()
	ball.radius = 0.05
	foot.shape = ball
	body.add_child(foot)
	body.collision_mask = 1 | (1 << 10)
	root.add_child(body)
	body.global_position = Vector3(0.2, t.get_height(Vector3(0.2, 0, 0.1)) + 0.5, 0.1)
	for i in 90:
		body.velocity.y -= 9.8 / 60.0
		body.velocity.x = 0.0
		body.velocity.z = 0.0
		body.move_and_slide()
		await physics_frame
	var rest := body.global_position
	var bottom := rest.y - ball.radius
	var relief_here := t.get_surface_height(rest) - t.get_height(rest)
	print("  a foot rests %.1f mm above the smooth ground (the relief there: %.1f mm)" % [(bottom - t.get_height(rest)) * 1000.0, relief_here * 1000.0])
	check(body.is_on_floor() and bottom > t.get_height(rest) + 0.5 * relief_here - 0.002 and bottom < t.get_surface_height(rest) + 0.02,
		"a character's foot stands on the relief, not on the smooth ground")
	body.queue_free()
	marker.position += Vector3(0.6, 0, 0.3)
	for i in 2:
		await physics_frame
	var moved := feet.last_sampled
	var after := measure.call(marker.position) as Array
	check(after[0] == 40 and after[1] < 0.004 and moved > 0 and moved < 33 * 33 / 2, "it follows the target, sampling only the new strip (%d samples)" % moved)
	marker.position = Vector3(-10, 0, -12)
	for i in 2:
		await physics_frame
	var far := measure.call(marker.position) as Array
	check(far[0] == 40 and far[1] < 0.004 and feet.last_sampled == 33 * 33, "a teleport samples the whole patch again")
	feet.queue_free()
	marker.queue_free()
	t.queue_free()
	await process_frame


## GADSImpact on a terrain: a permanent dent lowers the heights by its depth at the hit; where a
## deformation field covers the hit, a dent is a deformation mark instead and the heights stay.
func test_impact() -> void:
	var t := make_terrain({"height_scale": 10.0})
	root.add_child(t)
	var spot := Vector3(2.0, 0.0, 2.0)
	var before := t.get_height(spot)
	var hit := GADSImpact.dent_node(t, spot + Vector3(0, 30, 0), Vector3.DOWN, 3.0, 0.5, true)
	var drop := before - t.get_height(spot)
	print("  permanent dent: %s at %s, the ground %.3f m lower" % [hit["kind"], hit["position"], drop])
	check(hit["kind"] == "terrain" and absf(drop - 0.5) < 0.01 and absf(t.get_height(spot + Vector3(4, 0, 0)) - t.get_height(spot + Vector3(4, 0, 0))) == 0.0,
		"a permanent dent lowers the terrain by its depth at the hit")
	var deform := GADSDeformationField.new()
	deform.size_m = 16.0
	deform.resolution = 256
	root.add_child(deform)
	await process_frame
	var other := Vector3(-3.0, 0.0, 1.0)
	var h0 := t.get_height(other)
	hit = GADSImpact.dent_node(t, other + Vector3(0, 30, 0), Vector3.DOWN, 1.0, 0.2)
	var mark := deform.get_depth(Vector3(other.x, h0, other.z))
	print("  covered by a deformation field: %s, mark %.3f m deep, ground moved %.4f m" % [hit["kind"], mark, h0 - t.get_height(other)])
	check(hit["kind"] == "deformation" and absf(mark - 0.2) < 0.02 and t.get_height(other) == h0,
		"under a deformation field a dent is a mark that recovers, the heights stay")
	check(GADSImpact.dent_node(t, Vector3(500, 30, 0), Vector3.DOWN, 1.0, 0.2)["kind"] == "", "a ray that misses dents nothing")
	deform.queue_free()
	t.queue_free()
	await process_frame

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
	check(mat.get_shader_parameter("layer_albedo") is Texture2DArray and mat.get_shader_parameter("layer_height") is Texture2DArray,
		"the layers are packed into one texture array per channel")
	# The source height textures are kept as metadata for the CPU bake (the array resizes them).
	var heights: Array = mat.get_meta(&"gads_layer_heights", [])
	check(heights.size() >= 2 and heights[0] == rock.get_shader_parameter("height_texture")
		and heights[1] == snow.get_shader_parameter("height_texture"), "each layer keeps its source height texture")
	check(is_equal_approx(GADSMaterials.get_layer_param(mat, "scale", 0), 0.5) and is_equal_approx(GADSMaterials.get_layer_param(mat, "scale", 1), 2.0),
		"each layer keeps its texture size (scale relative to the first)")
	check(GADSMaterials.get_layer_param(mat, "mask_channel", 0) == GADSMaterials.LayerMask.VERTEX_R
		and GADSMaterials.get_layer_param(mat, "mask_channel", 1) == GADSMaterials.LayerMask.VERTEX_G
		and is_equal_approx(GADSMaterials.get_layer_param(mat, "amount", 0), 1.0), "layers 2 and 3 lie where vertex colour R and G say")
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


## Holes: cut_holes() leaves the triangles around the cut vertices out of every LOD, the collision
## and the ground data; intersect_ray() passes through (or, asked to, stops on the closed surface);
## is_hole() says where; filling them restores the surface; a hole map texture cuts the same way.
func test_holes() -> void:
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var t := make_terrain({"layers": [grass] as Array[ShaderMaterial], "detail_field": true, "height_scale": 4.0})
	root.add_child(t)
	var count_tris := func() -> int:
		var n := 0
		for key: Vector2i in t._chunk_data:
			n += (t._chunk_data[key]["arrays"][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		return n
	var before: int = count_tris.call()
	var at := Vector3(5.0, 0.0, -3.0)
	at.y = t.get_height(at)
	var far := Vector3(-10.0, 0.0, 8.0)
	far.y = t.get_height(far)
	var rect := t.cut_holes(at, 1.5)
	await process_frame
	check(rect.has_area() and t.is_hole(at) and not t.is_hole(far), "is_hole() is true at the cut, false elsewhere")
	# No triangle of any LOD (skirts included) with its centre within 1 m of the cut.
	var inside := 0
	for key: Vector2i in t._chunk_data:
		var data: Dictionary = t._chunk_data[key]
		var verts: PackedVector3Array = data["arrays"][Mesh.ARRAY_VERTEX]
		var sets: Array = [data["arrays"][Mesh.ARRAY_INDEX]]
		sets.append_array((data["lods"] as Dictionary).values())
		for idx: PackedInt32Array in sets:
			for i in range(0, idx.size(), 3):
				var c := (verts[idx[i]] + verts[idx[i + 1]] + verts[idx[i + 2]]) / 3.0
				if Vector2(c.x - at.x, c.z - at.z).length() < 1.0:
					inside += 1
	var removed: int = before - count_tris.call()
	print("  %d of %d finest triangles cut; %d triangles of any LOD left within 1 m" % [removed, before, inside])
	check(inside == 0 and removed > 50 and removed < 400, "the chunks leave the hole's triangles out at every LOD, and only those")
	check(not t.intersect_ray(at + Vector3(0, 10, 0), Vector3.DOWN).is_finite(), "a ray passes through the hole")
	var closed := t.intersect_ray(at + Vector3(0, 10, 0), Vector3.DOWN, 1e6, false)
	check(closed.is_finite() and absf(closed.y - at.y) < 0.01, "or stops on the closed surface when asked (the brushes)")
	await physics_frame
	await physics_frame
	var space := t.get_world_3d().direct_space_state
	var through := space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3(0, 10, 0), at - Vector3(0, 10, 0)))
	var beside := space.intersect_ray(PhysicsRayQueryParameters3D.create(far + Vector3(0, 10, 0), far - Vector3(0, 10, 0)))
	check(through.is_empty() and not beside.is_empty(), "the collision has the hole too")
	var bake := t.get_detail_field().ground_bake
	var w_hole: Color = bake.sample(Vector2(at.x, at.z))["weights"]
	var w_far: Color = bake.sample(Vector2(far.x, far.z))["weights"]
	check(w_hole.r + w_hole.g + w_hole.b + w_hole.a < 0.01 and w_far.r + w_far.g + w_far.b + w_far.a > 0.99,
		"the detail field has no ground there (it dives under, as at the end of the ground)")
	check(t.is_holes_editable() and t.get_hole_image().get_size() == t.get_grid_size(), "the hole map is an editable map of one texel per vertex")
	t.cut_holes(at, 2.0, true)
	await process_frame
	check(not t.is_hole(at) and count_tris.call() == before, "filling closes it again")
	t.queue_free()
	# A hole map: white where the terrain is open.
	var img := Image.create(64, 64, false, Image.FORMAT_L8)
	img.fill_rect(Rect2i(28, 28, 8, 8), Color.WHITE)
	var t2 := make_terrain({"holes": ImageTexture.create_from_image(img)})
	root.add_child(t2)
	check(t2.is_hole(Vector3(0, 0, 0)) and not t2.is_hole(Vector3(10, 0, 10)), "a hole map texture cuts where it is white")
	t2.queue_free()
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


## Editing: the ray query; sculpting changes the heights in the brush by its falloff and nowhere
## else, and the chunks, collision, rules and ground data follow; regions go back (undo); a
## rebuild keeps the edits; painting the splat map; a streamed terrain, also where no chunk is yet.
func test_editing() -> void:
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var rock := layer_material(4.0, Color(0.5, 0.5, 0.5))
	var t := make_terrain({"layers": [grass, rock] as Array[ShaderMaterial], "slope_range": Vector2(20, 30), "height_layer": 0,
		"detail_field": true, "height_scale": 10.0})
	root.add_child(t)
	# The ray query.
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst := 0.0
	var bad := 0
	for i in 60:
		var target := Vector3(rng.randf_range(-30, 30), 0, rng.randf_range(-30, 30))
		target.y = t.get_height(target)
		var from := target + Vector3(rng.randf_range(-20, 20), 30, rng.randf_range(-20, 20))
		var hit := t.intersect_ray(from, target - from)
		if not hit.is_finite() or from.distance_to(hit) > from.distance_to(target) + 0.01 \
				or (hit - from).normalized().dot((target - from).normalized()) < 0.9999:
			bad += 1
			continue
		worst = maxf(worst, absf(hit.y - t.get_height(hit)))
	print("  60 rays: %d wrong, largest height error %.3f mm" % [bad, worst * 1000.0])
	check(bad == 0 and worst < 0.002, "intersect_ray() lands on the surface, on the ray, no farther than the point aimed at")
	check(not t.intersect_ray(Vector3(0, 50, 0), Vector3.UP).is_finite() and not t.intersect_ray(Vector3(100, 50, 0), Vector3.DOWN).is_finite(),
		"and misses rays that do not meet it")
	# Making the heightmap editable keeps every height.
	var original := t.heightmap
	var c := Vector3(-8.0, 0, 4.0) # a vertex
	var probes := [Vector3.ZERO, Vector3(1.5, 0, 0), Vector3(0, 0, 2.9), Vector3(3.5, 0, 0), Vector3(-6, 0, 3), Vector3(1.7, 0, 0)]
	var before := []
	for o: Vector3 in probes:
		before.append(t.get_height(c + o))
	var snapshot := t.get_height_image()
	var same := true
	for i in probes.size():
		same = same and absf(t.get_height(c + probes[i]) - before[i]) < 1e-5
	check(t.is_height_editable() and t.heightmap == original and snapshot.get_size() == t.get_grid_size() and same,
		"a float heightmap of one texel per vertex is edited as it is")
	# Another map is replaced by one with the same heights.
	var coarse := make_terrain({"vertex_spacing": 1.0})
	root.add_child(coarse)
	var q := Vector3(3.0, 0, -5.0)
	var hq := coarse.get_height(q)
	coarse.make_heights_editable()
	check(coarse.is_height_editable() and coarse.heightmap != original and coarse.heightmap.get_size() == Vector2(65, 65) and absf(coarse.get_height(q) - hq) < 1e-5,
		"another heightmap becomes an editable map of one texel per vertex with the same heights")
	coarse.queue_free()
	var slope_before := t.get_layer_weights(c + probes[5]).x
	var rect := t.sculpt(c, 3.0, GADSSculpt.Mode.RAISE, 2.0)
	var rise: float = t.get_height(c) - before[0]
	var half: float = t.get_height(c + probes[1]) - before[1]
	var outside: float = absf(t.get_height(c + probes[3]) - before[3]) + absf(t.get_height(c + probes[4]) - before[4])
	print("  raise 2 m: %.4f m in the middle, %.4f m at half the radius, %.6f m beyond" % [rise, half, outside])
	check(rect.has_area() and absf(rise - 2.0) < 1e-4 and absf(half - 2.0 * 0.5625) < 1e-3 and outside == 0.0,
		"raise: the strength in the middle, the falloff between, nothing beyond the radius")
	var mesh_y := NAN
	for chunk in t.get_chunks():
		var v: PackedVector3Array = chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for p in v:
			if Vector2(p.x, p.z).is_equal_approx(Vector2(c.x, c.z)):
				mesh_y = p.y
	check(absf(mesh_y - t.get_height(c)) < 1e-4, "the chunk's vertices follow")
	check(t.get_layer_weights(c + probes[5]).x > 0.8, "the slope rule puts rock on the new flank (%.2f, was %.2f)" % [t.get_layer_weights(c + probes[5]).x, slope_before])
	await physics_frame
	await physics_frame
	var ray := t.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(c + Vector3(0.2, 60, 0.1), c + Vector3(0.2, -60, 0.1)))
	check(not ray.is_empty() and absf((ray["position"] as Vector3).y - t.get_height(c + Vector3(0.2, 0, 0.1))) < 0.005, "the collision follows")
	await process_frame
	var field := t.get_detail_field()
	var s: Dictionary = field.ground_bake.sample(Vector2(c.x, c.z))
	check(absf(float(s["height"]) - t.get_height(c)) < 1e-3, "the detail field's ground data follows (%.4f vs %.4f)" % [float(s["height"]), t.get_height(c)])
	# A region goes back (the tool's undo); a rebuild keeps edits.
	t.set_height_region(rect.position, snapshot.get_region(rect))
	same = true
	for i in probes.size():
		same = same and absf(t.get_height(c + probes[i]) - before[i]) < 1e-5
	check(same, "set_height_region() puts the heights back")
	t.sculpt(c, 3.0, GADSSculpt.Mode.FLATTEN, 1.0, 5.0)
	check(absf(t.get_height(c) - 5.0) < 1e-4, "flatten levels to a height (%.4f)" % t.get_height(c))
	t.sculpt(c, 0.6, GADSSculpt.Mode.RAISE, 3.0)
	var spike := t.get_height(c) - 5.0
	t.sculpt(c, 2.0, GADSSculpt.Mode.SMOOTH, 1.0)
	check(t.get_height(c) - 5.0 < spike * 0.5, "smooth takes a spike down (%.2f m to %.2f m)" % [spike, t.get_height(c) - 5.0])
	var kept := t.get_height(c)
	t.flush_edits()
	t.rebuild()
	check(t.is_height_editable() and absf(t.get_height(c) - kept) < 1e-5, "a rebuild keeps the edits")
	# Painting the splat map.
	var p := Vector3(10.0, 0, -10.0)
	var far_point := Vector3(-20.0, 0, -20.0)
	var far_before := t.get_layer_weights(far_point)
	t.paint_splatmap(p, 2.0, 1, 1.0)
	check(t.is_splat_editable() and t.get_layer_weights(p).x > 0.99, "paint_splatmap() paints the layer (%.2f)" % t.get_layer_weights(p).x)
	check(t.get_layer_weights(far_point).distance_to(far_before) <= 1.0 / 255.0 + 1e-6, "the rules' weights are kept in the splat map elsewhere")
	var colour := Color()
	for chunk in t.get_chunks():
		var arrays := chunk.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in v.size():
			if Vector2(v[i].x, v[i].z).is_equal_approx(Vector2(p.x, p.z)):
				colour = (arrays[Mesh.ARRAY_COLOR] as PackedColorArray)[i]
	check(colour.r > 0.99, "the chunks' vertex colours follow")
	await process_frame
	s = field.ground_bake.sample(Vector2(p.x, p.z))
	check((s["weights"] as Color).g > 0.99, "the detail field shows the painted layer")
	var painted := t.get_splat_image()
	t.paint_splatmap(p, 2.0, 0, 1.0)
	check(t.get_layer_weights(p).x < 0.01, "layer 0 paints the first layer back")
	t.set_splat_region(Vector2i.ZERO, painted)
	check(t.get_layer_weights(p).x > 0.99, "set_splat_region() puts the weights back")
	t.queue_free()
	await process_frame
	# Streaming: a built chunk and one built after the edit.
	var holder := Node3D.new()
	root.add_child(holder)
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.position = Vector3(-24, 30, -24)
	var st := make_terrain({"stream_radius": 12.0, "height_scale": 10.0})
	holder.add_child(st)
	st.stream_camera = st.get_path_to(cam)
	await _settle(st)
	var near := Vector3(-24.0, 0, -24.0)
	var far := Vector3(22.0, 0, 22.0)
	var h_near := st.get_height(near)
	var h_far := st.get_height(far)
	st.sculpt(near, 2.0, GADSSculpt.Mode.RAISE, 1.5)
	st.sculpt(far, 2.0, GADSSculpt.Mode.LOWER, 1.5)
	check(absf(st.get_height(near) - h_near - 1.5) < 1e-4 and absf(h_far - st.get_height(far) - 1.5) < 1e-4, "a streamed terrain sculpts too")
	var found_near := NAN
	for chunk in st.get_chunks():
		for v: Vector3 in chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			if Vector2(v.x, v.z).is_equal_approx(Vector2(near.x, near.z)):
				found_near = v.y
	await physics_frame
	await physics_frame
	var hit := st.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(near + Vector3(0, 60, 0), near - Vector3(0, 60, 0)))
	check(absf(found_near - st.get_height(near)) < 1e-4 and not hit.is_empty() and absf((hit["position"] as Vector3).y - st.get_height(near)) < 0.005,
		"its built chunk and the chunk's collision follow")
	cam.position = Vector3(22, 30, 22)
	await _settle(st)
	var found_far := NAN
	for chunk in st.get_chunks():
		for v: Vector3 in chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			if Vector2(v.x, v.z).is_equal_approx(Vector2(far.x, far.z)):
				found_far = v.y
	check(absf(found_far - st.get_height(far)) < 1e-4, "a chunk built after the edit has it")
	holder.queue_free()
	await process_frame


## Erosion and generated heights on a terrain: the heights change and everything follows; a
## generated landscape spans 0..height_scale.
func test_erosion() -> void:
	if not GADSProcedural.is_available():
		check(false, "the native library is loaded")
		return
	var t := make_terrain({"height_scale": 20.0})
	root.add_child(t)
	var p := Vector3(5.3, 0, -7.1)
	var before := t.get_height(p)
	var rect := t.generate_heights("ridged", {"seed": 2, "scale": 3.0})
	var lo := INF
	var hi := -INF
	for z in range(0, 129, 4):
		for x in range(0, 129, 4):
			var h := t.get_height(Vector3(-32.0 + x * 0.5, 0, -32.0 + z * 0.5))
			lo = minf(lo, h)
			hi = maxf(hi, h)
	print("  generated: %.2f to %.2f m" % [lo, hi])
	check(rect == Rect2i(Vector2i.ZERO, t.get_grid_size()) and t.get_height(p) != before and lo >= -1e-4 and hi <= 20.0001 and hi - lo > 8.0,
		"generate_heights() makes a landscape within 0..height_scale")
	var generated := t.get_height(p)
	t.erode({"seed": 5})
	var mesh_ok := true
	for chunk in t.get_chunks():
		var v: PackedVector3Array = chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for i in range(0, 33 * 33, 37):
			mesh_ok = mesh_ok and absf(v[i].y - t.get_height(v[i])) < 1e-4
	check(t.get_height(p) != generated and mesh_ok, "erode() changes the heights, the chunks follow")
	var exr := "user://gads_terrain_export.exr"
	var err := t.export_heightmap(exr)
	var back := Image.load_from_file(ProjectSettings.globalize_path(exr)) if err == OK else null
	var g := t.get_grid_size()
	check(back != null and back.get_size() == g and absf(back.get_pixel(64, 30).r * 20.0 - t.get_height(Vector3(-32.0 + 64 * 0.5, 0, -32.0 + 30 * 0.5))) < 0.02,
		"export_heightmap() writes the heights as an EXR of one texel per vertex")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(exr))
	t.queue_free()
	await process_frame


## Roads: flatten_path() puts the line's height on the band, fades back over the falloff and
## leaves the rest; it paints the layer under it; GADSTerrainPath3D conforms to the ground smoothly.
func test_roads() -> void:
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var gravel := layer_material(1.0, Color(0.5, 0.45, 0.4))
	var t := make_terrain({"layers": [grass, gravel] as Array[ShaderMaterial], "slope_layer": 0, "height_layer": 0, "height_scale": 10.0})
	root.add_child(t)
	var far := Vector3(0.0, 0, 6.0) # 6 m from the line: beyond width / 2 + falloff
	var fading := Vector3(4.0, 0, -6.5) # 3.5 m from the line: in the falloff
	var h_far := t.get_height(far)
	var h_fading := t.get_height(fading)
	var line := PackedVector3Array([Vector3(-20, 3, -10), Vector3(20, 5, -10)])
	var rect := t.flatten_path(line, 4.0, 3.0, 1)
	var on := [Vector3(0, 0, -10), Vector3(-10, 0, -10), Vector3(5, 0, -11.5), Vector3(-15, 0, -8.5)]
	var worst := 0.0
	for p: Vector3 in on:
		worst = maxf(worst, absf(t.get_height(p) - (4.0 + p.x / 20.0)))
	print("  on the band: largest difference from the line's height %.4f mm" % (worst * 1000.0))
	check(rect.has_area() and worst < 1e-4, "on the band the ground takes the line's height, interpolated along it")
	var line_h := 4.0 + fading.x / 20.0
	var f := t.get_height(fading)
	check(t.get_height(far) == h_far and ((f > minf(h_fading, line_h) and f < maxf(h_fading, line_h)) or absf(h_fading - line_h) < 1e-3),
		"in the falloff between the ground and the line (%.2f between %.2f and %.2f), beyond it untouched" % [f, h_fading, line_h])
	check(t.get_layer_weights(Vector3(0, 0, -10)).x > 0.99 and t.get_layer_weights(far).x < 0.01, "the layer is painted under the road, not beyond")
	t.queue_free()
	await process_frame
	# A path node that follows the hills.
	var hills := make_terrain({"height_scale": 10.0})
	root.add_child(hills)
	var path := GADSTerrainPath3D.new()
	path.curve = Curve3D.new()
	for p in [Vector3(-25, 0, -20), Vector3(0, 0, 0), Vector3(20, 0, 22)]:
		path.curve.add_point(p)
	path.width = 3.0
	path.falloff = 2.0
	path.smoothing = 10.0
	var lone := GADSTerrainPath3D.new()
	check(lone._get_configuration_warnings().size() == 2, "a path with no terrain and no curve warns about both")
	lone.free()
	hills.add_child(path)
	check(path._get_configuration_warnings().is_empty(), "a path on a terrain with a curve does not warn")
	var points := path.road_points()
	var ground_bump := 0.0
	var road_bump := 0.0
	for i in range(1, points.size() - 1):
		road_bump = maxf(road_bump, absf(points[i - 1].y - 2.0 * points[i].y + points[i + 1].y))
		ground_bump = maxf(ground_bump, absf(hills.get_height(points[i - 1]) - 2.0 * hills.get_height(points[i]) + hills.get_height(points[i + 1])))
	path.apply()
	var off := 0.0
	for i in range(0, points.size(), 7):
		off = maxf(off, absf(hills.get_height(points[i]) - points[i].y))
	print("  %d road points; bumpiness %.4f m (ground %.4f m); terrain within %.4f mm of the road" % [points.size(), road_bump, ground_bump, off * 1000.0])
	check(points.size() > 50 and road_bump < ground_bump * 0.5 and off < 0.005, "a conforming path smooths the ground's heights and the terrain takes them (between vertices within the grid's interpolation)")
	hills.queue_free()
	await process_frame


## The native chunk builder makes the same chunks as the GDScript one: a whole terrain (weights
## per vertex), a streamed one (heights sampled from the heightmap, the rules), a splat map, the
## painted weights and occluders.
func test_native_chunks() -> void:
	if not ClassDB.class_exists(GADSTerrain3D.MESHER):
		check(false, "the native library is loaded")
		return
	var splat := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	for y in 40:
		for x in 40:
			splat.set_pixel(x, y, Color(float(x) / 39.0, float(y) / 39.0, 0, 1))
	var cases := [
		["whole terrain", {}],
		["streamed (sampled heights, rules)", {"stream_radius": 1.0}],
		["splat map, occluders", {"splatmap": ImageTexture.create_from_image(splat), "occluders": true}],
	]
	for c: Array in cases:
		var t := make_terrain(c[1])
		t.stream_camera = NodePath("..") # nothing streams in during the comparison
		root.add_child(t)
		if c[0] == "whole terrain":
			t.paint_layer(Vector3(-20, 0, -20), 3.0, 1)
		var worst := 0.0
		var same_indices := true
		var native_ms := 0.0
		var script_ms := 0.0
		for key in [Vector2i(0, 0), Vector2i(1, 2), Vector2i(3, 3)]:
			var t0 := Time.get_ticks_usec()
			var a: Dictionary = t.call("_chunk_arrays", key.x, key.y, 5)
			native_ms += (Time.get_ticks_usec() - t0) / 1000.0
			t0 = Time.get_ticks_usec()
			var b: Dictionary = t.call("_chunk_arrays_gd", key.x, key.y, 5)
			script_ms += (Time.get_ticks_usec() - t0) / 1000.0
			for ch in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL]:
				var va: PackedVector3Array = a["arrays"][ch]
				var vb: PackedVector3Array = b["arrays"][ch]
				same_indices = same_indices and va.size() == vb.size()
				for i in mini(va.size(), vb.size()):
					worst = maxf(worst, va[i].distance_to(vb[i]))
			var ca: PackedColorArray = a["arrays"][Mesh.ARRAY_COLOR]
			var cb: PackedColorArray = b["arrays"][Mesh.ARRAY_COLOR]
			for i in mini(ca.size(), cb.size()):
				worst = maxf(worst, maxf(absf(ca[i].r - cb[i].r), absf(ca[i].g - cb[i].g)))
			var ua: PackedVector2Array = a["arrays"][Mesh.ARRAY_TEX_UV]
			var ub: PackedVector2Array = b["arrays"][Mesh.ARRAY_TEX_UV]
			for i in mini(ua.size(), ub.size()):
				worst = maxf(worst, ua[i].distance_to(ub[i]))
			same_indices = same_indices and a["arrays"][Mesh.ARRAY_INDEX] == b["arrays"][Mesh.ARRAY_INDEX]
			var la: Dictionary = a["lods"]
			var lb: Dictionary = b["lods"]
			same_indices = same_indices and la.size() == lb.size()
			for k in mini(la.size(), lb.size()):
				worst = maxf(worst, absf(float(la.keys()[k]) - float(lb.keys()[k])))
				same_indices = same_indices and la.values()[k] == lb.values()[k]
			same_indices = same_indices and a.has("occluder") == b.has("occluder")
			if a.has("occluder") and b.has("occluder"):
				var oa: PackedVector3Array = a["occluder"]["vertices"]
				var ob: PackedVector3Array = b["occluder"]["vertices"]
				for i in mini(oa.size(), ob.size()):
					worst = maxf(worst, oa[i].distance_to(ob[i]))
				same_indices = same_indices and oa.size() == ob.size() and a["occluder"]["indices"] == b["occluder"]["indices"]
		print("  %s: largest difference %.7f; native %.1f ms, GDScript %.1f ms for 3 chunks" % [c[0], worst, native_ms, script_ms])
		check(worst < 1e-5 and same_indices, "%s: the native chunks are the GDScript ones" % c[0])
		t.queue_free()
		await process_frame


## The native grid passes give what the GDScript would: heights at every vertex, the rules' and
## the splat map's weights, the ground data's texels (heights and dominant layer) and its error.
func test_native_grid() -> void:
	if not ClassDB.class_exists(GADSTerrain3D.MESHER):
		check(false, "the native library is loaded")
		return
	var grass := layer_material(2.0, Color(0.2, 0.6, 0.2))
	var rock := layer_material(4.0, Color(0.5, 0.5, 0.5))
	var t := make_terrain({"layers": [grass, rock] as Array[ShaderMaterial], "slope_range": Vector2(20, 30), "height_scale": 10.0})
	var t0 := Time.get_ticks_usec()
	root.add_child(t)
	print("  64 m terrain built in %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var heights: PackedFloat32Array = t.get("_heights")
	var w1: PackedFloat32Array = t.get("_w1")
	var w2: PackedFloat32Array = t.get("_w2")
	var g := t.get_grid_size()
	var worst_h := 0.0
	var worst_w := 0.0
	for z in range(0, g.y, 3):
		for x in range(0, g.x, 3):
			worst_h = maxf(worst_h, absf(heights[z * g.x + x] - float(t.call("_sample_source", x, z))))
			var w: Vector2 = t.call("_compute_weights", x, z)
			worst_w = maxf(worst_w, maxf(absf(w1[z * g.x + x] - w.x), absf(w2[z * g.x + x] - w.y)))
	check(worst_h < 1e-5 and worst_w < 1e-5, "heights and weights at the vertices are the GDScript ones (%.7f m, %.7f)" % [worst_h, worst_w])
	var texel := t.get_ground_texel()
	var part: Dictionary = ClassDB.class_call_static(GADSTerrain3D.MESHER, &"ground_arrays", t.call("_grid_state", 1), Vector2i(10, 20), Vector2i(60, 40), texel, 0.0, 2)
	var ph: PackedFloat32Array = part["heights"]
	var pc: PackedInt32Array = part["codes"]
	var origin := -t.get_extent() * 0.5
	var worst_g := 0.0
	var codes_ok := true
	for z in 40:
		for x in 60:
			var p := origin + Vector2(10 + x, 20 + z) * texel
			worst_g = maxf(worst_g, absf(ph[z * 60 + x] - float(t.call("_height_local", p))))
			var wts: Vector2 = t.call("_weights_at", ((p - origin) / t.get_vertex_spacing()).clamp(Vector2.ZERO, Vector2(g - Vector2i.ONE)))
			codes_ok = codes_ok and pc[z * 60 + x] == (2 if wts.y >= 0.5 else (1 if wts.x >= 0.5 else 0))
	check(worst_g < 1e-5 and codes_ok, "the ground data's texels are the GDScript ones (%.7f m)" % worst_g)
	var crease := 0.0
	var steep := GADSGroundBake.STEP_SLOPE * t.get_vertex_spacing()
	for z in g.y - 1:
		for x in g.x - 1:
			var h00 := heights[z * g.x + x]
			var h10 := heights[z * g.x + x + 1]
			var h01 := heights[(z + 1) * g.x + x]
			var h11 := heights[(z + 1) * g.x + x + 1]
			if maxf(maxf(absf(h10 - h00), absf(h01 - h00)), maxf(absf(h11 - h10), absf(h11 - h01))) <= steep:
				crease = maxf(crease, absf(h00 + h11 - h10 - h01))
	var native_crease: float = ClassDB.class_call_static(GADSTerrain3D.MESHER, &"ground_error", t.call("_grid_state", 1), Rect2i(Vector2i.ZERO, g - Vector2i.ONE), steep)
	check(absf(native_crease - crease) < 1e-5, "the ground data's error is the GDScript one (%.5f m)" % native_crease)
	t.queue_free()
	await process_frame


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



## Occluders: one per chunk, a coarse grid that lies below the drawn surface everywhere (it never
## hides what is visible) but within a few of its errors of it (it still hides what is behind).
func test_occluders() -> void:
	var t := make_terrain({"height_scale": 10.0})
	t.occluders = true
	t.occluder_quads = 4
	root.add_child(t)
	await process_frame
	var count := 0
	var above := 0
	var worst_gap := 0.0
	var triangles := 0
	for chunk in t.get_chunks():
		var nodes := chunk.get_children(true).filter(func(n: Node) -> bool: return n is OccluderInstance3D)
		if nodes.size() != 1:
			continue
		count += 1
		var occ := (nodes[0] as OccluderInstance3D).occluder as ArrayOccluder3D
		var v := occ.vertices
		var idx := occ.indices
		triangles += idx.size() / 3
		# Points across each occluder triangle against the terrain's surface there.
		for i in range(0, idx.size(), 3):
			for k in 6:
				var a := (k % 3 + 1) / 4.0
				var b := (1.0 - a) * (0.25 + 0.5 * float(k / 3))
				var p: Vector3 = v[idx[i]] * a + v[idx[i + 1]] * b + v[idx[i + 2]] * (1.0 - a - b)
				var surface := t.get_height(t.to_global(p))
				if p.y > surface + 1e-4:
					above += 1
				worst_gap = maxf(worst_gap, surface - p.y)
	print("  %d chunks, %d occluder triangles; occluder points above the surface: %d; largest gap below it %.2f m" % [count, triangles, above, worst_gap])
	check(count == t.get_chunks().size() and triangles == count * 2 * 4 * 4, "every chunk has a 4 x 4 quad occluder")
	check(above == 0 and worst_gap < 1.5, "it lies below the drawn surface everywhere, and close to it")
	t.occluders = false
	await process_frame
	await process_frame
	var left := 0
	for chunk in t.get_chunks():
		left += chunk.get_children(true).filter(func(n: Node) -> bool: return n is OccluderInstance3D).size()
	check(left == 0, "switching them off removes them")
	t.queue_free()
	await process_frame
