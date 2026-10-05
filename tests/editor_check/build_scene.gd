extends SceneTree
## Writes res://check_scene.tscn for the editor check: a ground plane with a world-planar Surface
## Displacement material (generated height map saved as a resource), a box with a
## StandardMaterial3D height map (to convert), a CSG box with one (to convert), a box with a
## transparent one (to skip) and a camera; plus res://height_source.png for the height-map tool.

func _initialize() -> void:
	var img := Image.create(64, 64, true, Image.FORMAT_RF)
	for y in 64:
		for x in 64:
			img.set_pixel(x, y, Color(0.3 + 0.4 * sin(x * TAU / 16.0) * cos(y * TAU / 16.0), 0, 0))
	img.generate_mipmaps()
	ResourceSaver.save(ImageTexture.create_from_image(img), "res://height.res")
	var height := load("res://height.res") as Texture2D
	var root := Node3D.new()
	root.name = "CheckScene"
	var ground_mat := SDMaterials.create(SDMaterials.Mapping.WORLD, {"height": height}, {"height_center": 0.0, "height_m": 0.03})
	ground_mat.resource_name = "ground"
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	ground.mesh = plane
	ground.material_override = ground_mat
	root.add_child(ground)
	ground.owner = root
	for i in 2:
		var box := MeshInstance3D.new()
		box.name = ["HeightBox", "GlassBox"][i]
		box.mesh = BoxMesh.new()
		box.position = Vector3(i * 1.5, 0.5, 0)
		var m := StandardMaterial3D.new()
		m.resource_name = box.name
		m.heightmap_enabled = true
		m.heightmap_texture = height
		if i == 1:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		box.material_override = m
		root.add_child(box)
		box.owner = root
	var csg := CSGBox3D.new()
	csg.name = "HeightCSG"
	csg.position = Vector3(-1.5, 0.5, 0)
	var csg_mat := StandardMaterial3D.new()
	csg_mat.resource_name = "HeightCSG"
	csg_mat.heightmap_enabled = true
	csg_mat.heightmap_texture = height
	csg.material = csg_mat
	root.add_child(csg)
	csg.owner = root
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.position = Vector3(1, 2, 5)
	root.add_child(cam)
	cam.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, "res://check_scene.tscn")
	root.free()
	var png := Image.create(32, 32, false, Image.FORMAT_L8)
	for y in 32:
		for x in 32:
			png.set_pixel(x, y, Color(float(x) / 31.0, 0, 0))
	var err2 := png.save_png("res://height_source.png")
	print("check scene saved: ", error_string(err), ", png: ", error_string(err2))
	quit(0 if err == OK and err2 == OK else 1)
