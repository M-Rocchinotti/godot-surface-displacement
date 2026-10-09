extends RefCounted
## Builds the demo scenes in code (so they need no editor setup and tests build exactly what the
## demo shows): a gravel path, a cobblestone street, rocky ground, a brick wall with props, a
## GADSTerrain3D with a rover leaving tracks and a cliff tessellated for the camera at runtime.
## Every scene is a Node3D with a WorldEnvironment, a sun, a Camera3D named "Camera", a
## GADSManager node, and "views" metadata: view name -> [camera position, look target].

const TEX := "res://demo/textures/"
const SCENE_NAMES: Array[String] = ["Gravel path", "Cobblestone street", "Rocky ground", "Brick wall and props", "Hills and tracks", "Cliff", "Material lab"]
const Rover := preload("res://demo/scenes/demo_rover.gd")
const VIEW_NAMES: Array[String] = ["Eye level", "Grazing", "Overview"]


static func build(index: int) -> Node3D:
	match index:
		0:
			return build_gravel_path()
		1:
			return build_cobblestone_street()
		2:
			return build_rocky_ground()
		3:
			return build_brick_wall()
		4:
			return build_hills()
		5:
			return build_cliff()
		_:
			return build_material_lab()


# --- Shared pieces ---------------------------------------------------------------------------

static func make_root(scene_name: String, sun_elevation: float, sun_azimuth: float) -> Node3D:
	var root := Node3D.new()
	root.name = scene_name.replace(" ", "")
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.32, 0.46, 0.68)
	sky_material.sky_horizon_color = Color(0.72, 0.76, 0.8)
	sky_material.ground_horizon_color = Color(0.6, 0.6, 0.6)
	sky_material.ground_bottom_color = Color(0.25, 0.23, 0.2)
	env.sky = Sky.new()
	env.sky.sky_material = sky_material
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	# The Mobile renderer has no SSAO (and warns when asked for it).
	env.ssao_enabled = RenderingServer.get_current_rendering_method() != "mobile"
	env.ssao_radius = 0.6
	env.ssao_intensity = 1.5
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.7, 0.75, 0.8)
	env.fog_depth_begin = 40.0
	env.fog_depth_end = 160.0
	env.fog_density = 0.35
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-sun_elevation, sun_azimuth, 0)
	sun.light_energy = 1.7
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.fov = 70.0
	cam.near = 0.03
	cam.far = 400.0
	root.add_child(cam)
	var gads := GADSManager.new()
	gads.name = "GADSManager"
	root.add_child(gads)
	return root


static func ground_material(set_id: String, extra := {}) -> ShaderMaterial:
	var params := {"height_center": 0.0}
	params.merge(extra, true)
	var m := GADSMaterials.from_texture_set(TEX + set_id, GADSMaterials.Mapping.WORLD, params)
	m.resource_name = set_id
	return m


## A regular heightfield mesh of [param size] metres with [param step] spacing, centred on the
## origin, heights from [param height] (Callable(x, z) -> y), with UVs in metres and tangents.
static func heightfield(size: Vector2, step: float, height: Callable) -> ArrayMesh:
	var nx := int(size.x / step)
	var nz := int(size.y / step)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in nz + 1:
		for i in nx + 1:
			var x := -size.x * 0.5 + i * step
			var z := -size.y * 0.5 + j * step
			st.set_uv(Vector2(x, z))
			st.add_vertex(Vector3(x, height.call(x, z), z))
	for j in nz:
		for i in nx:
			var a := j * (nx + 1) + i
			var b := a + 1
			var c := a + nx + 2
			var d := a + nx + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(a)
			st.add_index(c)
			st.add_index(d)
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


static func _mesh_node(parent: Node3D, node_name: String, mesh: Mesh, material: Material, pos := Vector3.ZERO, group := &"") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	if group != &"":
		mi.add_to_group(group, true)
	parent.add_child(mi)
	return mi


static func _field(root: Node3D, layers: Array[ShaderMaterial], scatter: bool) -> GADSDisplacementField3D:
	var field := GADSDisplacementField3D.new()
	field.name = "GADSDisplacementField3D"
	field.layers = layers
	root.add_child(field)
	if scatter:
		var pebbles := GADSPebbleScatter3D.new()
		pebbles.name = "GADSPebbleScatter3D"
		field.add_child(pebbles)
	return field


## A hero prop baked with tools/bake_displaced_mesh.py (real geometry; its UV0 holds the texture
## coordinates the relief was baked with), shaded with a plain ORM material of the same set.
static func hero_prop(path: String, set_id: String, pos: Vector3, rot_y := 0.0) -> Node3D:
	var scene := (load(path) as PackedScene).instantiate() as Node3D
	scene.position = pos
	scene.rotation.y = rot_y
	var mat := ORMMaterial3D.new()
	var base := TEX + set_id + "/" + set_id
	mat.albedo_texture = load(base + "_albedo.jpg")
	mat.normal_enabled = true
	mat.normal_texture = load(base + "_normal.jpg")
	mat.orm_texture = load(base + "_arm.jpg")
	for mi: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		mi.material_override = mat
	return scene


## A boulder: a noise-displaced sphere with triplanar parallax.
static func boulder(material: Material, pos: Vector3, radius: float, seed_value: int) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 1.4
	sphere.radial_segments = 48
	sphere.rings = 24
	var st := SurfaceTool.new()
	st.create_from(sphere, 0)
	var arrays := st.commit_to_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.9 / radius
	for i in verts.size():
		verts[i] *= 1.0 + 0.18 * noise.get_noise_3dv(verts[i])
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	st = SurfaceTool.new()
	st.create_from(mesh, 0)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = material
	mi.position = pos
	return mi


## [param mi] as a GADSMeshInstance3D that bakes its relief in the background once it is in the
## tree (a bake made while the game runs stays in memory). Without the native library it keeps
## drawing the parallax version.
static func baked(mi: MeshInstance3D, node_name: String) -> GADSMeshInstance3D:
	var node := GADSMeshInstance3D.new()
	node.name = node_name
	node.source_mesh = mi.mesh
	node.material_override = mi.material_override
	node.transform = mi.transform
	node.quality = GADSMeshInstance3D.Quality.LOW
	mi.free()
	if GADSMeshBaker.is_available():
		node.ready.connect(node.bake_async.bind(false), CONNECT_ONE_SHOT)
	return node


## A quad wall facing +Z (before [param basis]) with UVs in texture repeats of [param tile_m].
static func wall_quad(size: Vector2, tile_m: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := size.x * 0.5
	var pts := [Vector3(-w, 0, 0), Vector3(w, 0, 0), Vector3(w, size.y, 0), Vector3(-w, size.y, 0)]
	var uvs := [Vector2(0, size.y), Vector2(size.x, size.y), Vector2(size.x, 0), Vector2(0, 0)]
	for i in [0, 2, 1, 0, 3, 2]:
		st.set_normal(Vector3.BACK)
		st.set_uv(uvs[i] / tile_m)
		st.add_vertex(pts[i])
	st.generate_tangents()
	return st.commit()


static func _views(root: Node3D, views: Dictionary) -> void:
	root.set_meta(&"views", views)
	var first: Array = views[views.keys()[0]]
	var cam := root.get_node("Camera") as Camera3D
	cam.transform = view_transform(first)


## Camera transform of a view [position, look target].
static func view_transform(view: Array) -> Transform3D:
	var from: Vector3 = view[0]
	var to: Vector3 = view[1]
	return Transform3D(Basis.looking_at(to - from, Vector3.UP), from)


# --- 1. Gravel path --------------------------------------------------------------------------

static func path_x(z: float) -> float:
	return 2.2 * sin(z / 9.0)


static func terrain_height(x: float, z: float) -> float:
	return 0.25 * sin(x / 9.0) * cos(z / 11.0) + 0.12 * sin((x + z) / 5.3)


static func build_gravel_path() -> Node3D:
	var root := make_root("Gravel path", 26.0, 200.0)
	var pebbles := ground_material("clean_pebbles")
	var dirt := ground_material("forest_ground_04")
	var terrain := heightfield(Vector2(90, 90), 0.5, func(x: float, z: float) -> float: return terrain_height(x, z))
	_mesh_node(root, "Terrain", terrain, dirt, Vector3.ZERO, &"gads_ground")
	# The path: a ribbon that follows the terrain 5 mm above it, 2.4 m wide.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := 1.2
	var across := 12
	var rows := 0
	var z := -44.0
	while z <= 44.0:
		var dx := 2.2 / 9.0 * cos(z / 9.0)
		var side := Vector2(1.0, -dx).normalized()
		for k in across + 1:
			var s := -half + 2.0 * half * k / across
			var x := path_x(z) + side.x * s
			var zz := z + side.y * s
			st.set_uv(Vector2(x, zz))
			st.add_vertex(Vector3(x, terrain_height(x, zz) + 0.005, zz))
		rows += 1
		z += 0.25
	for r in rows - 1:
		for k in across:
			var a := r * (across + 1) + k
			var b := a + 1
			var c := a + across + 2
			var d := a + across + 1
			# Clockwise seen from above: Godot's front faces.
			for i in [a, b, c, a, c, d]:
				st.add_index(i)
	st.generate_normals()
	st.generate_tangents()
	_mesh_node(root, "GravelPath", st.commit(), pebbles, Vector3.ZERO, &"gads_ground")
	_field(root, [pebbles], true)
	var rock := GADSMaterials.from_texture_set(TEX + "rocks_ground_05", GADSMaterials.Mapping.TRIPLANAR, {"height_m": 0.06, "height_center": 1.0, "texture_size_m": Vector2(1.5, 1.5)})
	root.add_child(boulder(rock, Vector3(3.2, terrain_height(3.2, -3.0) + 0.15, -3.0), 0.55, 3))
	root.add_child(boulder(rock, Vector3(-2.6, terrain_height(-2.6, -9.0) + 0.1, -9.0), 0.4, 5))
	root.add_child(hero_prop("res://demo/models/hero_rubble_pile.glb", "rubble", Vector3(-3.0, terrain_height(-3.0, 1.5), 1.5), 0.6))
	var z0 := 5.0
	_views(root, {
		"Eye level": [Vector3(path_x(z0), terrain_height(path_x(z0), z0) + 1.7, z0), Vector3(path_x(z0 - 6.0), terrain_height(path_x(z0 - 6.0), z0 - 6.0), z0 - 6.0)],
		"Grazing": [Vector3(path_x(z0) + 0.2, terrain_height(path_x(z0), z0) + 0.35, z0), Vector3(path_x(z0 - 3.0), terrain_height(path_x(z0 - 3.0), z0 - 3.0) + 0.02, z0 - 3.0)],
		"Overview": [Vector3(6.0, 4.5, 9.0), Vector3(path_x(0.0), 0.0, 0.0)],
	})
	return root


# --- 2. Cobblestone street -------------------------------------------------------------------

static func build_cobblestone_street() -> Node3D:
	var root := make_root("Cobblestone street", 32.0, 235.0)
	var cobble := ground_material("cobblestone_floor_08")
	var pavers := ground_material("square_cobblestone", {"planar_rotation_deg": 0.0})
	var street := PlaneMesh.new()
	street.size = Vector2(8.0, 70.0)
	_mesh_node(root, "Street", street, cobble, Vector3.ZERO, &"gads_ground")
	var brick_walls := GADSMaterials.from_texture_set(TEX + "brick_wall_001", GADSMaterials.Mapping.TRIPLANAR, {"height_center": 1.0})
	var kerb_mat := GADSMaterials.from_texture_set(TEX + "square_cobblestone", GADSMaterials.Mapping.TRIPLANAR, {"height_m": 0.01, "height_center": 1.0})
	for sx in [-1.0, 1.0]:
		# Sidewalk: its top is pavers (a field layer, in the ground group); the 15 cm kerb below it
		# is a box with triplanar pavers (not ground: a vertical step is not a height field).
		var top := PlaneMesh.new()
		top.size = Vector2(2.6, 70.0)
		_mesh_node(root, "SidewalkTop", top, pavers, Vector3(sx * 5.3, 0.15, 0.0), &"gads_ground")
		var kerb := BoxMesh.new()
		kerb.size = Vector3(2.6, 0.146, 70.0)
		_mesh_node(root, "Kerb", kerb, kerb_mat, Vector3(sx * 5.3, 0.073, 0.0))
		# Facades.
		var facade := BoxMesh.new()
		facade.size = Vector3(0.6, 7.0, 70.0)
		_mesh_node(root, "Facade", facade, brick_walls, Vector3(sx * 6.9, 3.5, 0.0))
	_field(root, [cobble, pavers], false)
	# A UV-mapped wall section with the opt-in depth write, and a crate pushed into it.
	var wall_mat := GADSMaterials.from_texture_set(TEX + "brick_wall_001", GADSMaterials.Mapping.UV, {"height_center": 1.0}, GADSMaterials.Quality.POM_SELF_SHADOW, true)
	var wall := _mesh_node(root, "DepthWriteWall", wall_quad(Vector2(3.0, 2.2), 3.0), wall_mat, Vector3(-6.58, 0.15, -6.0))
	wall.rotation.y = PI * 0.5
	var crate := BoxMesh.new()
	crate.size = Vector3(0.6, 0.6, 0.6)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.45, 0.32, 0.2)
	wood.roughness = 0.8
	_mesh_node(root, "Crate", crate, wood, Vector3(-6.3, 0.45, -6.0))
	root.add_child(hero_prop("res://demo/models/hero_brick_wall.glb", "brick_wall_001", Vector3(4.4, 0.13, -9.0), PI * 0.5))
	_views(root, {
		"Eye level": [Vector3(0.8, 1.7, 6.0), Vector3(-0.5, 0.0, -2.0)],
		"Grazing": [Vector3(0.5, 0.3, 4.0), Vector3(0.0, 0.05, 1.0)],
		"Overview": [Vector3(3.5, 5.0, 8.0), Vector3(-2.0, 0.0, -4.0)],
	})
	return root


# --- 3. Rocky ground -------------------------------------------------------------------------

static func rocky_height(x: float, z: float) -> float:
	return 0.9 * sin(x / 6.5) * cos(z / 7.5) + 0.35 * sin((x - 2.0 * z) / 3.1) + 0.15 * cos(x / 1.7)


static func build_rocky_ground() -> Node3D:
	var root := make_root("Rocky ground", 24.0, 150.0)
	var rocks := ground_material("rocks_ground_05")
	var terrain := heightfield(Vector2(70, 70), 0.25, func(x: float, z: float) -> float: return rocky_height(x, z))
	_mesh_node(root, "Terrain", terrain, rocks, Vector3.ZERO, &"gads_ground")
	_field(root, [rocks], false)
	var boulder_mat := GADSMaterials.from_texture_set(TEX + "rocks_ground_05", GADSMaterials.Mapping.TRIPLANAR, {"height_m": 0.08, "height_center": 1.0, "texture_size_m": Vector2(1.5, 1.5)})
	root.add_child(boulder(boulder_mat, Vector3(2.5, rocky_height(2.5, -4.0) + 0.2, -4.0), 0.8, 7))
	# The same boulder with its relief baked into real geometry: outline, shadows and contact.
	root.add_child(baked(boulder(boulder_mat, Vector3(4.6, rocky_height(4.6, -3.2) + 0.2, -3.2), 0.8, 7), "BakedBoulder"))
	root.add_child(hero_prop("res://demo/models/hero_rubble_pile.glb", "rubble", Vector3(-2.0, rocky_height(-2.0, -2.0), -2.0), 0.3))
	_views(root, {
		"Eye level": [Vector3(0.0, rocky_height(0.0, 4.0) + 1.7, 4.0), Vector3(0.0, rocky_height(0.0, -3.0), -3.0)],
		"Grazing": [Vector3(0.3, rocky_height(0.3, 3.0) + 0.4, 3.0), Vector3(0.0, rocky_height(0.0, 0.5), 0.5)],
		"Overview": [Vector3(7.0, 6.0, 9.0), Vector3(0.0, 0.0, -1.0)],
	})
	return root


# --- 4. Brick wall and props -----------------------------------------------------------------

static func build_brick_wall() -> Node3D:
	var root := make_root("Brick wall and props", 18.0, 290.0)
	var floor_mat := ground_material("gravel_stones")
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(30.0, 30.0)
	_mesh_node(root, "Floor", floor_mesh, floor_mat, Vector3.ZERO, &"gads_ground")
	_field(root, [floor_mat], true)
	var bricks := GADSMaterials.from_texture_set(TEX + "brick_wall_001", GADSMaterials.Mapping.UV, {"height_center": 1.0})
	var back := _mesh_node(root, "BrickWall", wall_quad(Vector2(9.0, 3.0), 3.0), bricks, Vector3(0.0, 0.0, -3.0))
	back.name = "BrickWall"
	var bricks_depth := GADSMaterials.from_texture_set(TEX + "brick_wall_001", GADSMaterials.Mapping.UV, {"height_center": 1.0}, GADSMaterials.Quality.POM_SELF_SHADOW, true)
	var side := _mesh_node(root, "DepthWriteWall", wall_quad(Vector2(4.0, 3.0), 3.0), bricks_depth, Vector3(-4.5, 0.0, -1.0))
	side.rotation.y = PI * 0.5
	var crate := BoxMesh.new()
	crate.size = Vector3(0.7, 0.7, 0.7)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.45, 0.32, 0.2)
	wood.roughness = 0.8
	_mesh_node(root, "Crate", crate, wood, Vector3(-4.2, 0.35, -0.2))
	# The same wall segment twice: parallax only (left) and baked real geometry (right).
	var box := BoxMesh.new()
	box.size = Vector3(2.0, 0.9, 0.3)
	var tri_bricks := GADSMaterials.from_texture_set(TEX + "brick_wall_001", GADSMaterials.Mapping.TRIPLANAR, {"height_center": 1.0})
	_mesh_node(root, "PomWallSegment", box, tri_bricks, Vector3(-1.3, 0.45, -0.5))
	root.add_child(hero_prop("res://demo/models/hero_brick_wall.glb", "brick_wall_001", Vector3(1.3, -0.02, -0.5)))
	root.add_child(hero_prop("res://demo/models/hero_rubble_pile.glb", "rubble", Vector3(3.2, 0.0, 0.8), 1.2))
	var rubble := GADSMaterials.from_texture_set(TEX + "rubble", GADSMaterials.Mapping.TRIPLANAR, {"height_m": 0.05, "height_center": 1.0})
	var block := BoxMesh.new()
	block.size = Vector3(0.8, 0.5, 0.6)
	_mesh_node(root, "RubbleBlock", block, rubble, Vector3(2.2, 0.25, -2.0))
	_views(root, {
		"Eye level": [Vector3(0.3, 1.7, 3.8), Vector3(-0.3, 0.8, -2.0)],
		"Grazing": [Vector3(-3.0, 1.2, -2.6), Vector3(4.0, 1.2, -2.95)],
		"Overview": [Vector3(4.0, 3.5, 5.0), Vector3(-0.5, 0.5, -1.5)],
	})
	return root


# --- 5. Hills and tracks (GADSTerrain3D, runtime deformation) --------------------------------

const HILLS_SIZE := 96.0
const HILLS_LOW := -3.0
const HILLS_HIGH := 9.0


static func hills_height(x: float, z: float) -> float:
	var ridge := 6.5 * smoothstep(14.0, 30.0, -z) * (0.6 + 0.4 * sin(x / 7.0))
	return 1.6 * sin(x / 11.0) * cos(z / 13.0) + 0.6 * sin((x + 2.0 * z) / 6.3) + ridge


## The terrain's hole map: white within [param radius] metres of [param at] (XZ), one texel per
## terrain vertex (0.5 m).
static func hills_hole_map(at: Vector2, radius: float) -> ImageTexture:
	var n := int(HILLS_SIZE / 0.5) + 1
	var img := Image.create(n, n, false, Image.FORMAT_L8)
	for z in n:
		for x in n:
			var p := Vector2(x, z) * 0.5 - Vector2(HILLS_SIZE, HILLS_SIZE) * 0.5
			if p.distance_to(at) <= radius:
				img.set_pixel(x, z, Color.WHITE)
	return ImageTexture.create_from_image(img)


## The terrain's heightmap: hills_height() over HILLS_SIZE, 0..1 between HILLS_LOW and HILLS_HIGH.
static func hills_heightmap(size := 257) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RF)
	for j in size:
		for i in size:
			var x := -HILLS_SIZE * 0.5 + HILLS_SIZE * i / (size - 1)
			var z := -HILLS_SIZE * 0.5 + HILLS_SIZE * j / (size - 1)
			img.set_pixel(i, j, Color((hills_height(x, z) - HILLS_LOW) / (HILLS_HIGH - HILLS_LOW), 0, 0))
	return ImageTexture.create_from_image(img)


static func build_hills() -> Node3D:
	var root := make_root("Hills and tracks", 30.0, 160.0)
	var ground := ground_material("forest_ground_04")
	var rock := ground_material("rocks_ground_05")
	var gravel := ground_material("gravel_stones")
	var terrain := GADSTerrain3D.new()
	terrain.name = "Terrain"
	terrain.heightmap = hills_heightmap()
	terrain.size = Vector2(HILLS_SIZE, HILLS_SIZE)
	terrain.height_offset = HILLS_LOW
	terrain.height_scale = HILLS_HIGH - HILLS_LOW
	terrain.vertex_spacing = 0.5
	terrain.chunk_quads = 64
	terrain.layers = [ground, rock, gravel] as Array[ShaderMaterial]
	terrain.slope_range = Vector2(22.0, 32.0)
	terrain.height_band = Vector2(5.0, 6.5)
	# A shaft into the hillside: a hole in the terrain (its hole map) over a rock-lined pit.
	var shaft := Vector2(14.0, -6.0)
	terrain.holes = hills_hole_map(shaft, 2.4)
	root.add_child(terrain)
	var pit_mat := rock.duplicate() as ShaderMaterial
	pit_mat.shader = GADSMaterials.get_shader(GADSMaterials.Mapping.TRIPLANAR, GADSMaterials.Quality.POM_SELF_SHADOW)
	pit_mat.set_shader_parameter("albedo_tint", Color(0.6, 0.55, 0.5))
	var pit_mesh := CylinderMesh.new()
	pit_mesh.top_radius = 3.0
	pit_mesh.bottom_radius = 2.6
	pit_mesh.height = 9.0
	pit_mesh.radial_segments = 32
	pit_mesh.cap_top = false
	pit_mesh.flip_faces = true
	var lowest := INF
	for k in 16:
		var a := TAU * k / 16.0
		lowest = minf(lowest, hills_height(shaft.x + 3.0 * cos(a), shaft.y + 3.0 * sin(a)))
	_mesh_node(root, "Shaft", pit_mesh, pit_mat, Vector3(shaft.x, lowest - 0.05 - pit_mesh.height * 0.5, shaft.y))
	# A gravel road winding from the viewpoint up towards the ridge (flattened when the scene starts).
	var road := GADSTerrainPath3D.new()
	road.name = "Road"
	road.curve = Curve3D.new()
	for p: Vector3 in [Vector3(-14, 0, 30), Vector3(-6, 0, 18), Vector3(-12, 0, 4), Vector3(-6, 0, -12), Vector3(4, 0, -24), Vector3(2, 0, -40)]:
		road.curve.add_point(p, Vector3.ZERO, Vector3.ZERO)
	for i in road.curve.point_count:
		# Smooth handles along the line through the neighbours.
		var prev := road.curve.get_point_position(maxi(i - 1, 0))
		var next := road.curve.get_point_position(mini(i + 1, road.curve.point_count - 1))
		road.curve.set_point_in(i, (prev - next) * 0.2)
		road.curve.set_point_out(i, (next - prev) * 0.2)
	road.width = 2.6
	road.falloff = 2.5
	road.layer = 2
	road.smoothing = 14.0
	road.apply_on_ready = true
	terrain.add_child(road)
	var tracks := GADSDeformationField.new()
	tracks.name = "Tracks"
	# A fixed window over the rover's whole loop (no follow): 32 m at 6 cm texels.
	tracks.position = Vector3(0.0, 0.0, -2.0)
	tracks.size_m = 32.0
	tracks.resolution = 512
	tracks.max_depth = 0.12
	tracks.recovery_rate = 0.0005
	root.add_child(tracks)
	var rover := Node3D.new()
	rover.name = "Rover"
	rover.set_script(Rover)
	rover.set("terrain", terrain)
	rover.set("center", Vector2(0.0, -2.0))
	var body := MeshInstance3D.new()
	body.name = "Body"
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 0.45, 2.0)
	body.mesh = box
	body.position = Vector3(0, 0.62, 0)
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.75, 0.35, 0.12)
	paint.roughness = 0.6
	body.material_override = paint
	rover.add_child(body)
	var tyre := StandardMaterial3D.new()
	tyre.albedo_color = Color(0.08, 0.08, 0.08)
	tyre.roughness = 0.9
	for side in [-0.75, 0.75]:
		for axle in [-0.7, 0.7]:
			var wheel_mesh := MeshInstance3D.new()
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = 0.32
			cylinder.bottom_radius = 0.32
			cylinder.height = 0.3
			wheel_mesh.mesh = cylinder
			wheel_mesh.material_override = tyre
			wheel_mesh.position = Vector3(side, 0.29, axle)
			wheel_mesh.rotation_degrees = Vector3(0, 0, 90)
			rover.add_child(wheel_mesh)
		var track := GADSDeformer3D.new()
		track.name = "Track" + ("L" if side < 0 else "R")
		track.position = Vector3(side, 0.0, 0.0)
		track.continuous = true
		track.radius = 0.16
		track.depth = 0.07
		track.spacing = 0.05
		track.contact_height = 0.3
		rover.add_child(track)
	root.add_child(rover)
	_views(root, {
		"Eye level": [Vector3(0.0, hills_height(0.0, 10.0) + 1.7, 10.0), Vector3(0.0, hills_height(0.0, 2.0), 2.0)],
		"Grazing": [Vector3(6.2, hills_height(6.2, -3.5) + 0.5, -3.5), Vector3(9.0, hills_height(9.0, -0.5), -0.5)],
		"Overview": [Vector3(18.0, 16.0, 22.0), Vector3(0.0, 0.0, -6.0)],
	})
	return root


# --- 6. Cliff (runtime view-dependent tessellation, clusters) --------------------------------

## A curved rock face (an arc of a cylinder, concave towards the viewer), [param rows] x
## [param cols] quads, UVs in texture repeats of [param tile_m].
static func cliff_mesh(radius: float, arc_deg: float, height: float, cols: int, rows: int, tile_m: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var arc := deg_to_rad(arc_deg)
	for j in rows + 1:
		for i in cols + 1:
			var a := -arc * 0.5 + arc * i / cols
			var y := height * j / rows
			# Facing the centre (+Z side of the arc looks towards -Z): normal points inwards.
			var p := Vector3(sin(a) * radius, y, -cos(a) * radius)
			st.set_normal(Vector3(-sin(a), 0.0, cos(a)))
			st.set_uv(Vector2(radius * (a + arc * 0.5) / tile_m, (height - y) / tile_m))
			st.add_vertex(p)
	for j in rows:
		for i in cols:
			var a := j * (cols + 1) + i
			var b := a + 1
			var c := a + cols + 1
			var d := c + 1
			# Clockwise seen from the inside (Godot's front faces).
			for k in [a, c, b, b, c, d]:
				st.add_index(k)
	st.generate_tangents()
	return st.commit()


static func build_cliff() -> Node3D:
	# A low sun from the side rakes across the face and shows its relief.
	var root := make_root("Cliff", 28.0, 40.0)
	var gravel := ground_material("rocky_gravel")
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(40.0, 40.0)
	_mesh_node(root, "Floor", floor_mesh, gravel, Vector3.ZERO, &"gads_ground")
	_field(root, [gravel], true)
	var rock := GADSMaterials.from_texture_set(TEX + "rocks_ground_05", GADSMaterials.Mapping.UV,
		{"height_m": 0.45, "height_center": 1.0}, GADSMaterials.Quality.POM_SELF_SHADOW)
	var cliff := GADSMeshInstance3D.new()
	cliff.name = "Cliff"
	cliff.source_mesh = cliff_mesh(14.0, 100.0, 12.0, 40, 16, 5.0)
	cliff.material_override = rock
	# Tessellated for the camera while the game runs: dense where it looks closely, coarse further
	# away and above; split into clusters so the engine culls and picks LODs per part.
	cliff.quality = GADSMeshInstance3D.Quality.MEDIUM
	cliff.view_dependent = true
	cliff.pixel_error = 1.5
	cliff.view_max_triangles = 400000
	cliff.cluster_triangles = 30000
	cliff.generate_lods = true
	root.add_child(cliff)
	var boulder_mat := GADSMaterials.from_texture_set(TEX + "rocks_ground_05", GADSMaterials.Mapping.TRIPLANAR,
		{"height_m": 0.08, "height_center": 1.0, "texture_size_m": Vector2(1.5, 1.5)})
	for b in [[Vector3(-3.0, 0.3, -11.8), 1.1, 3], [Vector3(2.4, 0.2, -12.4), 0.8, 5], [Vector3(5.5, 0.35, -10.9), 1.3, 9]]:
		root.add_child(boulder(boulder_mat, b[0], b[1], b[2]))
	_views(root, {
		"Eye level": [Vector3(1.0, 1.7, -6.0), Vector3(-1.5, 2.0, -13.5)],
		"Grazing": [Vector3(-8.5, 1.4, -9.0), Vector3(4.0, 3.0, -13.6)],
		"Overview": [Vector3(0.0, 8.0, 6.0), Vector3(0.0, 4.0, -12.0)],
	})
	return root


# --- 7. Material lab (procedural materials, surface effects, vector displacement) ---------------

## A procedural material of [param kind], or [param fallback] where the native library is missing.
static func _procedural(kind: String, options: Dictionary, fallback: ShaderMaterial) -> ShaderMaterial:
	if not GADSProcedural.is_available():
		return fallback # The GDScript generator would take seconds a material at startup.
	var m := GADSProcedural.create_material(kind, options)
	return m if m != null else fallback


## A vector displacement map of curling ridges: three per repeat across u, each a bump that leans
## forward along +u as it rises, so its crest overhangs (a height map cannot do that). Signed
## RGBF, tangent space.
static func curl_vector_map(size := 128) -> ImageTexture:
	var rgb := PackedFloat32Array()
	rgb.resize(size * size * 3)
	for y in size:
		for x in size:
			var t := fposmod((x + 0.5) / size * 3.0, 1.0)
			var v := (y + 0.5) / size
			# Bell across the ridge, varying slowly along it.
			var z := exp(-pow((t - 0.45) / 0.16, 2.0)) * (0.75 + 0.25 * sin(TAU * v * 2.0))
			var i := (y * size + x) * 3
			rgb[i] = 1.1 * z * z
			rgb[i + 1] = 0.0
			rgb[i + 2] = z
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGBF, rgb.to_byte_array())
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func build_material_lab() -> Node3D:
	var root := make_root("Material lab", 40.0, 35.0)
	var fallback_ground := ground_material("rocky_gravel")
	# Floor: procedural tiles, dirt in the joints, worn edges.
	var floor_mat := _procedural("tiles", {"size": 512, "mapping": GADSMaterials.Mapping.WORLD, "tile_m": Vector2(2, 2),
		"params": {"scale": 4, "seed": 2}}, fallback_ground)
	floor_mat.set_shader_parameter("cavity_amount", 0.55)
	floor_mat.set_shader_parameter("cavity_color", Color(0.22, 0.2, 0.16))
	floor_mat.set_shader_parameter("edge_amount", 0.35)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(24, 24)
	_mesh_node(root, "Floor", floor_mesh, floor_mat)
	# A brick wall with moss in the joints (parallax, UV mapping).
	var wall_mat := _procedural("bricks", {"size": 512, "tile_m": Vector2(2, 2), "params": {"seed": 5}},
		GADSMaterials.from_texture_set(TEX + "brick_wall_001", GADSMaterials.Mapping.UV, {}, GADSMaterials.Quality.POM_SELF_SHADOW))
	wall_mat.set_shader_parameter("cavity_amount", 0.7)
	wall_mat.set_shader_parameter("cavity_color", Color(0.16, 0.26, 0.1))
	var wall := _mesh_node(root, "Wall", wall_quad(Vector2(8, 3), 2.0), wall_mat, Vector3(0, 0, -6))
	wall.rotation_degrees = Vector3.ZERO
	# Baked spheres, one per procedural kind.
	var kinds := ["rock", "stones", "craters", "cracks", "ridged", "scales"]
	for i in kinds.size():
		var kind: String = kinds[i]
		# Around a sphere u runs twice as far as v: two repeats around keep the texels square.
		var mat := _procedural(kind, {"size": 512, "tile_m": Vector2(1.7, 1.7), "params": {"seed": 11 + i}}, fallback_ground)
		mat.set_shader_parameter("uv_scale", Vector2(2.0, 1.0))
		var sphere := SphereMesh.new()
		sphere.radius = 0.55
		sphere.height = 1.1
		sphere.radial_segments = 32
		sphere.rings = 16
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.material_override = mat
		mi.position = Vector3(-5.0 + 2.0 * i, 0.6, -2.5)
		var node := baked(mi, "Sphere_%s" % kind)
		node.quality = GADSMeshInstance3D.Quality.MEDIUM
		root.add_child(node)
	# The stones sphere again, not baked: silhouette parallax draws its relief, outline included.
	var sil_mat := _procedural("stones", {"size": 512, "tile_m": Vector2(1.7, 1.7), "params": {"seed": 12}}, fallback_ground)
	sil_mat.set_shader_parameter("uv_scale", Vector2(2.0, 1.0))
	GADSMaterials.set_silhouette(sil_mat, true)
	var sil_sphere := SphereMesh.new()
	sil_sphere.radius = 0.55
	sil_sphere.height = 1.1
	var sil_mi := MeshInstance3D.new()
	sil_mi.name = "Sphere_stones_parallax"
	sil_mi.mesh = sil_sphere
	sil_mi.material_override = sil_mat
	sil_mi.position = Vector3(-2.0, 0.6, 0.3)
	root.add_child(sil_mi)
	# One material, three boulders: each varies its relief depth and tint per node (they batch).
	var boulder_mat := _procedural("rock", {"size": 512, "tile_m": Vector2(1.7, 1.7), "params": {"seed": 21}}, fallback_ground)
	boulder_mat.set_shader_parameter("uv_scale", Vector2(2.0, 1.0))
	var variations := [[0.4, Color(1.0, 0.92, 0.8), "Shallow"], [1.0, Color.WHITE, "Default"], [1.8, Color(0.75, 0.8, 0.9), "Deep"]]
	for i in variations.size():
		var boulder := SphereMesh.new()
		boulder.radius = 0.4
		boulder.height = 0.8
		var b := _mesh_node(root, "Boulder_%s" % variations[i][2], boulder, boulder_mat, Vector3(0.2 + 1.1 * i, 0.4, 0.6))
		GADSMaterials.set_variation(b, variations[i][0], variations[i][1])
	# Animated relief: a slowly flowing, breathing pool (parallax; nothing to bake).
	var pool_mat := _procedural("billow", {"size": 512, "mapping": GADSMaterials.Mapping.WORLD, "tile_m": Vector2(2, 2),
		"params": {"seed": 9}}, fallback_ground)
	pool_mat.set_shader_parameter("albedo_tint", Color(1.0, 0.5, 0.25))
	pool_mat.set_shader_parameter("flow_speed", Vector2(0.06, 0.03))
	pool_mat.set_shader_parameter("pulse_amount", 0.35)
	pool_mat.set_shader_parameter("pulse_rate", 0.3)
	var pool := PlaneMesh.new()
	pool.size = Vector2(2.5, 2.5)
	_mesh_node(root, "FlowingPool", pool, pool_mat, Vector3(-4.5, 0.03, 1.5))
	# Vector displacement: curling ridges that overhang, baked from a flat panel.
	var curl := GADSMaterials.create(GADSMaterials.Mapping.UV, {"albedo": (floor_mat.get_shader_parameter("albedo_texture") as Texture2D)},
		{"vector_displacement_texture": curl_vector_map(), "vector_displacement_m": 0.35, "vector_displacement_signed": true,
		"height_m": 0.0, "albedo_tint": Color(0.75, 0.82, 0.9)}, GADSMaterials.Quality.POM)
	var panel := PlaneMesh.new()
	panel.size = Vector2(3, 3)
	var panel_mi := MeshInstance3D.new()
	panel_mi.mesh = panel
	panel_mi.material_override = curl
	panel_mi.position = Vector3(4.5, 0.02, 1.5)
	var curl_node := baked(panel_mi, "VectorDisplaced")
	curl_node.quality = GADSMeshInstance3D.Quality.MEDIUM
	root.add_child(curl_node)
	# Surface presets (GADSSurfacePresets), behind the wall: one of each kind of surface, from its
	# procedural pattern; ground presets on low slabs (their world-planar maps face up).
	var ids := GADSSurfacePresets.ids()
	for i in ids.size():
		var id: String = ids[i]
		var pm: ShaderMaterial = fallback_ground
		if GADSProcedural.is_available():
			pm = GADSSurfacePresets.create(id, {}, {"size": 256, "tile_m": 1.0, "seed": 3 + i})
		var ground: bool = GADSMaterials.parse(pm.shader).get("mapping", 0) == GADSMaterials.Mapping.WORLD
		var block := BoxMesh.new()
		block.size = Vector3(1.2, 0.25 if ground else 1.2, 1.2)
		var at := Vector3(-3.75 + 1.5 * (i % 6), block.size.y * 0.5, -8.0 - 2.2 * (i / 6))
		_mesh_node(root, "Preset_%s" % id, block, pm, at)
		var label := Label3D.new()
		label.text = GADSSurfacePresets.label(id)
		label.font_size = 28
		label.pixel_size = 0.004
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position = at + Vector3(0, block.size.y * 0.5 + 0.25, 0)
		root.add_child(label)
	_views(root, {
		"Eye level": [Vector3(0.5, 1.6, 3.5), Vector3(0.0, 0.8, -3.0)],
		"Grazing": [Vector3(4.1, 0.5, 4.7), Vector3(4.6, 0.12, 1.5)],
		"Overview": [Vector3(0.0, 6.0, 7.0), Vector3(0.0, 0.0, -2.0)],
		"Surface presets": [Vector3(0.0, 3.2, -15.5), Vector3(0.0, 0.3, -8.8)],
	})
	return root
