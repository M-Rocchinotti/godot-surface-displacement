@tool
class_name GADSTextureSet
extends RefCounted
## Turns a downloaded PBR texture set (Substance, Quixel, Poly Haven, Blender bakes...) into a
## GADS material: [method detect] groups image files into sets and tells each file's role from
## its name (BaseColor / Albedo / Diffuse / BaseMap, Normal (OpenGL or DirectX), Roughness or
## Gloss / Smoothness (inverted), Metallic, AO, packed ORM / ARM, RMA and Unity's MaskMap,
## Height / Displacement, a Bump map only without them); [method recommend] proposes the texture size, the relief
## depth and the height remap; [method prepare] writes what the set lacks for GADS next to it (a
## remapped 16-bit EXR height, a packed ORM, an OpenGL normal map from a DirectX one) and
## [method create_material] builds and saves the material. The editor's Create GADS Material from
## Selected Textures runs all four.

const ROLE_WORDS := {
	"albedo": ["basecolor", "albedo", "diffuse", "diff", "color", "colour", "col", "basemap"],
	"normal": ["normal", "normalgl", "normaldx", "nor", "nrm", "norm", "normalmap"],
	"roughness": ["roughness", "rough", "rgh"],
	# Glossiness / smoothness: roughness inverted (Megascans' Gloss, Unity's Smoothness).
	"gloss": ["gloss", "glossiness", "smoothness"],
	"metallic": ["metallic", "metalness", "metal", "met"],
	"ao": ["ambientocclusion", "occlusion", "ao", "occ"],
	"orm": ["orm", "arm", "occlusionroughnessmetallic"],
	# Packed the other way round: R roughness, G metallic, B occlusion.
	"rma": ["rma"],
	# Unity HDRP / URP mask map: R metallic, G occlusion, B detail mask, A smoothness.
	"mask": ["maskmap"],
	"height": ["height", "displacement", "disp", "heightmap", "bump", "depth"],
}
## Name words that are no part of the set's name: resolutions, normal conventions, variants.
const NOISE_WORDS := ["1k", "2k", "3k", "4k", "8k", "16k", "gl", "dx", "opengl", "directx", "map", "tex", "texture", "t"]
const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "exr", "webp", "tga", "bmp", "hdr", "tif", "tiff"]
## Relief depth proposed per metre of texture: scanned ground and walls carry a few centimetres of
## relief over their usual 2 m (7 cm here).
const DEPTH_PER_METRE := 0.035


## The texture sets among [param paths]: [{"name", "dir", "files": {role: path}, "normal_dx":
## bool}], one per name and folder, roles found by the words of each file name. Files whose role
## is unknown are left out.
static func detect(paths: PackedStringArray) -> Array:
	var sets := {}
	for path in paths:
		if not path.get_extension().to_lower() in IMAGE_EXTENSIONS:
			continue
		var words := _words(path.get_file().get_basename())
		var role := ""
		var role_at := -1
		for i in range(words.size() - 1, -1, -1):
			for r: String in ROLE_WORDS:
				if words[i] in ROLE_WORDS[r]:
					role = r
					role_at = i
					break
			if not role.is_empty():
				break
		if role.is_empty():
			continue
		var dx := "dx" in words or "directx" in words or words[role_at] == "normaldx"
		var name_words := []
		for i in words.size():
			if i != role_at and not words[i] in NOISE_WORDS:
				name_words.append(words[i])
		var set_name := "_".join(name_words) if not name_words.is_empty() else path.get_base_dir().get_file()
		var key := path.get_base_dir() + "/" + set_name
		if not sets.has(key):
			sets[key] = {"name": set_name, "dir": path.get_base_dir(), "files": {}, "normal_dx": false}
		var s: Dictionary = sets[key]
		var files: Dictionary = s["files"]
		# Prefer the OpenGL normal map when both are there, and an EXR height over an 8-bit one.
		if role == "normal" and files.has("normal") and dx:
			continue
		# A height over a bump map (Megascans ships both; its Bump is fine detail), then an EXR.
		var rank := (0 if words[role_at] == "bump" else 2) + (1 if path.get_extension().to_lower() == "exr" else 0)
		if role == "height" and files.has("height") and int(s.get("height_rank", 0)) >= rank:
			continue
		if role == "height":
			s["height_rank"] = rank
		files[role] = path
		if role == "normal":
			s["normal_dx"] = dx
	var out := []
	for key in sets:
		out.append(sets[key])
	return out


## Lower-case words of a file name: split at separators and between a lower-case letter and an
## upper-case one (BaseColor -> base, color), joined back where a role is two words.
static func _words(stem: String) -> PackedStringArray:
	var spaced := ""
	for i in stem.length():
		var c := stem[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower() and stem[i - 1] == stem[i - 1].to_lower() and stem[i - 1] != stem[i - 1].to_upper():
			spaced += " "
		spaced += c
	var words := PackedStringArray()
	for w in spaced.to_lower().replace("-", " ").replace("_", " ").replace(".", " ").split(" ", false):
		words.append(w)
	# Roles written as several words: occlusion roughness metallic, base color, ambient
	# occlusion, normal gl / dx.
	var joined := PackedStringArray()
	var i := 0
	while i < words.size():
		var triple := "".join(words.slice(i, i + 3))
		var pair := "".join(words.slice(i, i + 2))
		if i + 2 < words.size() and triple == "occlusionroughnessmetallic":
			joined.append(triple)
			i += 3
		elif i + 1 < words.size() and pair in ["basecolor", "ambientocclusion", "normalgl", "normaldx", "heightmap", "normalmap", "basemap", "maskmap"]:
			joined.append(pair)
			i += 2
		else:
			joined.append(words[i])
			i += 1
	return joined


## Proposed material parameters for [param texture_set]: {"texture_size_m": Vector2,
## "height_m", "height_remap": Vector2 (the height map's 1st / 99th percentiles, or (0, 1)),
## "height_levels" (distinct values: under 1024 means 8-bit), "notes": [String]}.
static func recommend(texture_set: Dictionary, texture_size_m := 2.0) -> Dictionary:
	var out := {"texture_size_m": Vector2(texture_size_m, texture_size_m), "height_m": snappedf(DEPTH_PER_METRE * texture_size_m, 0.001),
		"height_remap": Vector2(0, 1), "height_levels": 0, "notes": []}
	var files: Dictionary = texture_set["files"]
	if not files.has("height"):
		(out["notes"] as Array).append("no height map: the material will be flat (normal mapped only)")
		return out
	var img := GADSHeightImport.load_height(files["height"])
	if img == null:
		(out["notes"] as Array).append("cannot read the height map")
		return out
	var stats := GADSHeightTools.analyse(img)
	out["height_remap"] = Vector2(stats["p1"], stats["p99"])
	out["height_levels"] = stats["levels"]
	if stats["levels"] <= 256:
		(out["notes"] as Array).append("8-bit height map: its 256 steps may show as terraces; a 16-bit or EXR source is better")
	return out


## Writes what the set needs for GADS next to its files (the set's "dir"): "<name>_gads_height.exr"
## (remapped half float, with mipmaps), "<name>_gads_orm.png" when there is no ORM / ARM texture
## but roughness, AO or metallic maps, "<name>_gads_normal.png" with the green channel flipped
## when the normal map is DirectX. Returns {role: path} of the files the material should use
## (the written ones and the set's own). Import them (the editor does) before create_material().
static func prepare(texture_set: Dictionary) -> Dictionary:
	var files: Dictionary = texture_set["files"]
	var base := String(texture_set["dir"]).path_join(texture_set["name"])
	var use := {}
	if files.has("albedo"):
		use["albedo"] = files["albedo"]
	if files.has("height"):
		var dst := base + "_gads_height.exr"
		if not GADSHeightTools.convert_to_half_exr(files["height"], dst).is_empty():
			use["height"] = dst
	if files.has("normal"):
		if texture_set.get("normal_dx", false):
			var img := Image.load_from_file(ProjectSettings.globalize_path(files["normal"]))
			if img != null and not img.is_empty():
				if img.is_compressed():
					img.decompress()
				img.convert(Image.FORMAT_RGB8)
				var data := img.get_data()
				for i in range(1, data.size(), 3):
					data[i] = 255 - data[i]
				img = Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8, data)
				var dst := base + "_gads_normal.png"
				img.save_png(ProjectSettings.globalize_path(dst))
				_write_import(dst, true)
				use["normal"] = dst
		else:
			use["normal"] = files["normal"]
	if files.has("orm"):
		use["orm"] = files["orm"]
	elif files.has("rma") or files.has("mask") or files.has("roughness") or files.has("gloss") or files.has("ao") or files.has("metallic"):
		var orm: Image
		if files.has("rma"):
			orm = repack_orm(files["rma"], "rma")
		elif files.has("mask"):
			orm = repack_orm(files["mask"], "mask")
		else:
			orm = pack_orm(files.get("ao", ""), files.get("roughness", ""), files.get("metallic", ""), files.get("gloss", ""))
		if orm != null:
			var dst := base + "_gads_orm.png"
			orm.save_png(ProjectSettings.globalize_path(dst))
			_write_import(dst, false)
			use["orm"] = dst
	return use


## An ORM image (R = ambient occlusion, G = roughness, B = metallic) from separate maps (paths;
## empty: AO 1, roughness 1, metallic 0), at the largest of their sizes. Without a roughness map
## a gloss / smoothness one ([param gloss_path]) gives it inverted.
static func pack_orm(ao_path: String, roughness_path: String, metallic_path: String, gloss_path := "") -> Image:
	var sources: Array[Image] = []
	var size := Vector2i.ZERO
	var invert_roughness := roughness_path.is_empty() and not gloss_path.is_empty()
	if invert_roughness:
		roughness_path = gloss_path
	for p in [ao_path, roughness_path, metallic_path]:
		var img: Image = null
		if not p.is_empty():
			img = Image.load_from_file(ProjectSettings.globalize_path(p))
			if img != null and not img.is_empty():
				if img.is_compressed():
					img.decompress()
				img.clear_mipmaps()
				size = size.max(img.get_size())
			else:
				img = null
		sources.append(img)
	if size == Vector2i.ZERO:
		return null
	var defaults := [255, 255, 0]
	var channels: Array[PackedByteArray] = []
	for k in 3:
		var img := sources[k]
		var values := PackedByteArray()
		if img == null:
			values.resize(size.x * size.y)
			values.fill(defaults[k])
		else:
			img = img.duplicate() as Image
			if img.get_size() != size:
				img.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
			img.convert(Image.FORMAT_L8)
			values = img.get_data()
			if k == 1 and invert_roughness:
				for i in values.size():
					values[i] = 255 - values[i]
		channels.append(values)
	var data := PackedByteArray()
	data.resize(size.x * size.y * 3)
	for i in size.x * size.y:
		data[i * 3] = channels[0][i]
		data[i * 3 + 1] = channels[1][i]
		data[i * 3 + 2] = channels[2][i]
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGB8, data)


## An ORM image from a map packed another way: [param layout] "rma" (R roughness, G metallic,
## B occlusion) or "mask" (Unity's mask map: R metallic, G occlusion, A smoothness). Null when the
## file cannot be read.
static func repack_orm(path: String, layout: String) -> Image:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	var src := img.get_data()
	var data := PackedByteArray()
	data.resize(img.get_width() * img.get_height() * 3)
	for i in img.get_width() * img.get_height():
		var r := src[i * 4]
		var g := src[i * 4 + 1]
		var b := src[i * 4 + 2]
		var a := src[i * 4 + 3]
		if layout == "mask":
			data[i * 3] = g
			data[i * 3 + 1] = 255 - a
			data[i * 3 + 2] = r
		else:
			data[i * 3] = b
			data[i * 3 + 1] = r
			data[i * 3 + 2] = g
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8, data)


## Import settings for a written texture: VRAM compressed with mipmaps (a normal map as one).
static func _write_import(path: String, normal_map: bool) -> void:
	var cfg := ConfigFile.new()
	var existing := ConfigFile.new()
	cfg.set_value("remap", "importer", "texture")
	cfg.set_value("remap", "type", "CompressedTexture2D")
	if existing.load(path + ".import") == OK and existing.has_section_key("remap", "uid"):
		cfg.set_value("remap", "uid", existing.get_value("remap", "uid"))
	cfg.set_value("params", "compress/mode", 2)
	cfg.set_value("params", "compress/normal_map", 1 if normal_map else 2)
	cfg.set_value("params", "mipmaps/generate", true)
	cfg.set_value("params", "detect_3d/compress_to", 0)
	cfg.save(path + ".import")


## A GADS material from [param use] ({role: path}, see [method prepare}; the files must be
## imported) and [param params] (as [method recommend] returns them, or your own), saved to
## [param save_path] when it is not empty. The height map from prepare() is remapped already, so
## the height remap stays (0, 1).
static func create_material(use: Dictionary, params: Dictionary, mapping := GADSMaterials.Mapping.UV,
		quality := GADSMaterials.Quality.POM_SELF_SHADOW, save_path := "") -> ShaderMaterial:
	var textures := {}
	for role: String in ["albedo", "normal", "orm", "height"]:
		if use.has(role):
			var tex := load(use[role]) as Texture2D
			if tex != null:
				textures[role] = tex
	var p := {
		"height_m": params.get("height_m", 0.05),
		"texture_size_m": params.get("texture_size_m", Vector2(2, 2)),
		"height_center": 1.0 if mapping != GADSMaterials.Mapping.WORLD else 0.0,
	}
	if not use.get("height", "").ends_with("_gads_height.exr"):
		p["height_remap"] = params.get("height_remap", Vector2(0, 1))
	if mapping == GADSMaterials.Mapping.UV:
		p.erase("texture_size_m")
	if not textures.has("orm"):
		p["ao_strength"] = 0.0
	var material := GADSMaterials.create(mapping, textures, p, quality)
	if not save_path.is_empty():
		material.resource_name = save_path.get_file().get_basename()
		var err := ResourceSaver.save(material, save_path)
		if err != OK:
			push_error("GADS: cannot save %s (%s)" % [save_path, error_string(err)])
		else:
			material.take_over_path(save_path)
	return material
