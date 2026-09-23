extends RefCounted
## Builds the demo scenes in code (so they need no editor setup and tests build exactly what the
## demo shows): a gravel path, a cobblestone street, rocky ground and a brick wall with props.
## Every scene is a Node3D with a WorldEnvironment, a sun, a Camera3D named "Camera", a
## SurfaceDisplacement node, and "views" metadata: view name -> [camera position, look target].

const TEX := "res://demo/textures/"
const SCENE_NAMES: Array[String] = ["Gravel path", "Cobblestone street", "Rocky ground", "Brick wall and props"]
const VIEW_NAMES: Array[String] = ["Eye level", "Grazing", "Overview"]


static func build(index: int) -> Node3D:
	match index:
		0:
			return build_gravel_path()
		1:
			return build_cobblestone_street()
		2:
			return build_rocky_ground()
		_:
			return build_brick_wall()


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
	env.ssao_enabled = true
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
	var sd := SurfaceDisplacement.new()
	sd.name = "SurfaceDisplacement"
	root.add_child(sd)
	return root


static func ground_material(set_id: String, extra := {}) -> ShaderMaterial:
	var params := {"height_center": 0.0}
	params.merge(extra, true)
	var m := SDMaterials.from_texture_set(TEX + set_id, SDMaterials.Mapping.WORLD, params)
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


static func _field(root: Node3D, layers: Array[ShaderMaterial], scatter: bool) -> DisplacementField3D:
	var field := DisplacementField3D.new()
	field.name = "DisplacementField3D"
	field.layers = layers
	root.add_child(field)
	if scatter:
		var pebbles := PebbleScatter3D.new()
		pebbles.name = "PebbleScatter3D"
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
	_mesh_node(root, "Terrain", terrain, dirt, Vector3.ZERO, &"sd_ground")
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
			for i in [a, c, b, a, d, c]:
				st.add_index(i)
	st.generate_normals()
	st.generate_tangents()
	_mesh_node(root, "GravelPath", st.commit(), pebbles, Vector3.ZERO, &"sd_ground")
	_field(root, [pebbles], true)
	var rock := SDMaterials.from_texture_set(TEX + "rocks_ground_05", SDMaterials.Mapping.TRIPLANAR, {"height_m": 0.06, "height_center": 1.0, "texture_size_m": Vector2(1.5, 1.5)})
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
	_mesh_node(root, "Street", street, cobble, Vector3.ZERO, &"sd_ground")
	var brick_walls := SDMaterials.from_texture_set(TEX + "brick_wall_001", SDMaterials.Mapping.TRIPLANAR, {"height_center": 1.0})
	var kerb_mat := SDMaterials.from_texture_set(TEX + "square_cobblestone", SDMaterials.Mapping.TRIPLANAR, {"height_m": 0.01, "height_center": 1.0})
	for sx in [-1.0, 1.0]:
		# Sidewalk: its top is pavers (a field layer, in the ground group); the 15 cm kerb below it
		# is a box with triplanar pavers (not ground: a vertical step is not a height field).
		var top := PlaneMesh.new()
		top.size = Vector2(2.6, 70.0)
		_mesh_node(root, "SidewalkTop", top, pavers, Vector3(sx * 5.3, 0.15, 0.0), &"sd_ground")
		var kerb := BoxMesh.new()
		kerb.size = Vector3(2.6, 0.146, 70.0)
		_mesh_node(root, "Kerb", kerb, kerb_mat, Vector3(sx * 5.3, 0.073, 0.0))
		# Facades.
		var facade := BoxMesh.new()
		facade.size = Vector3(0.6, 7.0, 70.0)
		_mesh_node(root, "Facade", facade, brick_walls, Vector3(sx * 6.9, 3.5, 0.0))
	_field(root, [cobble, pavers], false)
	# A UV-mapped wall section with the opt-in depth write, and a crate pushed into it.
	var wall_mat := SDMaterials.from_texture_set(TEX + "brick_wall_001", SDMaterials.Mapping.UV, {"height_center": 1.0}, SDMaterials.Quality.POM_SELF_SHADOW, true)
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
	_mesh_node(root, "Terrain", terrain, rocks, Vector3.ZERO, &"sd_ground")
	_field(root, [rocks], false)
	var boulder_mat := SDMaterials.from_texture_set(TEX + "rocks_ground_05", SDMaterials.Mapping.TRIPLANAR, {"height_m": 0.08, "height_center": 1.0, "texture_size_m": Vector2(1.5, 1.5)})
	root.add_child(boulder(boulder_mat, Vector3(2.5, rocky_height(2.5, -4.0) + 0.2, -4.0), 0.8, 7))
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
	_mesh_node(root, "Floor", floor_mesh, floor_mat, Vector3.ZERO, &"sd_ground")
	_field(root, [floor_mat], true)
	var bricks := SDMaterials.from_texture_set(TEX + "brick_wall_001", SDMaterials.Mapping.UV, {"height_center": 1.0})
	var back := _mesh_node(root, "BrickWall", wall_quad(Vector2(9.0, 3.0), 3.0), bricks, Vector3(0.0, 0.0, -3.0))
	back.name = "BrickWall"
	var bricks_depth := SDMaterials.from_texture_set(TEX + "brick_wall_001", SDMaterials.Mapping.UV, {"height_center": 1.0}, SDMaterials.Quality.POM_SELF_SHADOW, true)
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
	var tri_bricks := SDMaterials.from_texture_set(TEX + "brick_wall_001", SDMaterials.Mapping.TRIPLANAR, {"height_center": 1.0})
	_mesh_node(root, "PomWallSegment", box, tri_bricks, Vector3(-1.3, 0.45, -0.5))
	root.add_child(hero_prop("res://demo/models/hero_brick_wall.glb", "brick_wall_001", Vector3(1.3, -0.02, -0.5)))
	root.add_child(hero_prop("res://demo/models/hero_rubble_pile.glb", "rubble", Vector3(3.2, 0.0, 0.8), 1.2))
	var rubble := SDMaterials.from_texture_set(TEX + "rubble", SDMaterials.Mapping.TRIPLANAR, {"height_m": 0.05, "height_center": 1.0})
	var block := BoxMesh.new()
	block.size = Vector3(0.8, 0.5, 0.6)
	_mesh_node(root, "RubbleBlock", block, rubble, Vector3(2.2, 0.25, -2.0))
	_views(root, {
		"Eye level": [Vector3(0.3, 1.7, 3.8), Vector3(-0.3, 0.8, -2.0)],
		"Grazing": [Vector3(-3.0, 1.2, -2.6), Vector3(4.0, 1.2, -2.95)],
		"Overview": [Vector3(4.0, 3.5, 5.0), Vector3(-0.5, 0.5, -1.5)],
	})
	return root
