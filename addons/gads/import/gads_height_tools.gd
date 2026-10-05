@tool
class_name GADSHeightTools
extends RefCounted
## Height-map helpers for the editor: statistics (1st / 99th percentile, precision) and conversion
## of any height image Godot can load into the format the addon wants: one channel, 16-bit
## float, remapped so its 1st / 99th percentiles become 0 / 1, saved as EXR and imported
## lossless with mipmaps. (The repository's tools/prepare_textures.py does the same for Poly Haven
## downloads, including 16-bit PNGs, which Godot itself only loads as 8 bit.)


## {"p1", "p99", "min", "max", "levels" (distinct values in the sample), "format"} of the red
## channel of [param image], from a sample of up to 512 x 512 pixels.
static func analyse(image: Image) -> Dictionary:
	var img := image.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	if img.has_mipmaps():
		img.clear_mipmaps()
	if img.get_width() > 512 or img.get_height() > 512:
		img.resize(mini(img.get_width(), 512), mini(img.get_height(), 512), Image.INTERPOLATE_NEAREST)
	img.convert(Image.FORMAT_RF)
	var values := img.get_data().to_float32_array()
	var sorted := Array(values)
	sorted.sort()
	var distinct := {}
	for v in values:
		distinct[v] = true
	return {
		"p1": sorted[int(0.01 * (sorted.size() - 1))],
		"p99": sorted[int(0.99 * (sorted.size() - 1))],
		"min": sorted[0],
		"max": sorted[sorted.size() - 1],
		"levels": distinct.size(),
		"format": image.get_format(),
	}


## How much relief a height map carries at each scale: a Laplacian pyramid of its red channel (a
## sample of up to 1024 x 1024). Returns {"bands": PackedFloat32Array (RMS height difference
## between mip level k and level k + 1, finest first, in height units), "fine_fraction" (share of
## the finest band in the total), "useful_size" (the smallest size whose finer bands hold under 2 %
## of the relief: a larger map adds texels but no relief)}.
static func analyse_detail(image: Image) -> Dictionary:
	var img := image.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	if img.get_width() > 1024 or img.get_height() > 1024:
		img.resize(mini(img.get_width(), 1024), mini(img.get_height(), 1024), Image.INTERPOLATE_BILINEAR)
	img.convert(Image.FORMAT_RF)
	var bands := PackedFloat32Array()
	var size := img.get_width()
	while img.get_width() >= 8 and img.get_height() >= 8:
		var coarse := img.duplicate() as Image
		coarse.resize(img.get_width() / 2, img.get_height() / 2, Image.INTERPOLATE_BILINEAR)
		var up := coarse.duplicate() as Image
		up.resize(img.get_width(), img.get_height(), Image.INTERPOLATE_BILINEAR)
		var a := img.get_data().to_float32_array()
		var b := up.get_data().to_float32_array()
		var sum := 0.0
		for i in a.size():
			var d := a[i] - b[i]
			sum += d * d
		bands.append(sqrt(sum / maxf(a.size(), 1.0)))
		img = coarse
	var total := 0.0
	for e in bands:
		total += e
	var useful := size
	var finer := 0.0
	for k in bands.size():
		finer += bands[k]
		if total > 0.0 and finer / total < 0.02:
			useful = size >> (k + 1)
	return {
		"bands": bands,
		"fine_fraction": bands[0] / total if total > 0.0 and not bands.is_empty() else 0.0,
		"useful_size": useful,
	}


## Writes [param dst_path] (.exr): the red channel of the image at [param src_path], remapped by
## its percentiles when [param remap], as one 16-bit float channel, and an .import file that keeps
## it lossless with mipmaps. Returns the analysis of the source.
static func convert_to_half_exr(src_path: String, dst_path: String, remap := true) -> Dictionary:
	# Loading from the global path reads the source file itself (not its imported texture) without
	# Godot's "will not work on export" warning; this is an editor tool.
	var src := Image.load_from_file(ProjectSettings.globalize_path(src_path))
	if src == null or src.is_empty():
		push_error("GADSHeightTools: cannot load %s" % src_path)
		return {}
	var stats := analyse(src)
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RF)
	if remap:
		var lo: float = stats["p1"]
		var span := maxf(float(stats["p99"]) - lo, 1e-6)
		var data := img.get_data().to_float32_array()
		for i in data.size():
			data[i] = clampf((data[i] - lo) / span, 0.0, 1.0)
		img = Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RF, data.to_byte_array())
	img.convert(Image.FORMAT_RH)
	# grayscale = false keeps the single channel named R, which Godot loads back as one channel
	# (a "Y" channel would load as three).
	var err := img.save_exr(ProjectSettings.globalize_path(dst_path), false)
	if err != OK:
		push_error("GADSHeightTools: cannot write %s (%s)" % [dst_path, error_string(err)])
		return {}
	write_import(dst_path)
	return stats


## The .import settings for a height EXR: lossless (half floats stay uncompressed), mipmaps on,
## no "detect 3D" recompression.
static func write_import(path: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("remap", "importer", "texture")
	cfg.set_value("remap", "type", "CompressedTexture2D")
	# Rewriting the settings of an existing file keeps its UID, so references to it stay valid.
	var existing := ConfigFile.new()
	if existing.load(path + ".import") == OK and existing.has_section_key("remap", "uid"):
		cfg.set_value("remap", "uid", existing.get_value("remap", "uid"))
	cfg.set_value("params", "compress/mode", 0)
	cfg.set_value("params", "mipmaps/generate", true)
	cfg.set_value("params", "mipmaps/limit", -1)
	cfg.set_value("params", "detect_3d/compress_to", 0)
	cfg.set_value("params", "process/hdr_clamp_exposure", false)
	cfg.save(path + ".import")
