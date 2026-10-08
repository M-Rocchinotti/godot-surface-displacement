@tool
class_name GADSHeightImport
extends RefCounted
## Height maps at full precision, with mipmaps made for displacement. Godot's image loader reads
## 16-bit PNGs as 8 bits (256 steps: terraces once displaced) and has no loader for the RAW / R16
## heightmaps terrain tools write (World Machine, Gaea, Unity); [method load_height] reads both
## at their 65 536 steps (and every other format through the engine). [method build_mipmaps]
## makes the mip chain by averaging, or by keeping each block's highest or lowest value, so
## distant parallax keeps (Max) the peaks an average would flatten. The GADS Height Map importer
## ("Import As" in the Import dock) runs these on import.
## [codeblock]
## var height := GADSHeightImport.load_height("res://terrain/world.r16")  # FORMAT_RF, 0..1
## var tex := GADSHeightImport.make_texture(height, {"mip_filter": GADSHeightImport.MipFilter.MAX})
## [/codeblock]

enum Channel { RED, GREEN, BLUE, ALPHA, LUMINANCE }
## How each mip level is made from the one above: the mean of each 2 x 2 block (the engine's
## mipmaps), or its highest or lowest value (conservative: relief does not shrink or swell with
## distance).
enum MipFilter { AVERAGE, MAX, MIN }
## What the values are remapped to 0..1 from: nothing (as stored), the map's lowest and highest
## values, or its 1st and 99th percentiles (clips outliers, as Prepare Height Maps does).
enum Remap { NONE, MIN_MAX, PERCENTILES }

## Extensions [method load_height] reads with its own decoders: raw 16-bit unsigned samples.
const RAW_EXTENSIONS := ["r16", "raw"]
const _PNG_SIGNATURE := [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]


## The height map at [param path] as one FORMAT_RF channel (no mipmaps), or null with an error
## pushed. 16-bit PNGs and RAW / R16 files keep their 16 bits; other images load through the
## engine. Options: "channel" ([enum Channel], red), "raw_width" (0: square), "raw_big_endian"
## (false: the usual Windows byte order).
static func load_height(path: String, options := {}) -> Image:
	var channel: int = options.get("channel", Channel.RED)
	var global := ProjectSettings.globalize_path(path)
	var ext := path.get_extension().to_lower()
	if ext in RAW_EXTENSIONS:
		var raw := FileAccess.get_file_as_bytes(global)
		if raw.is_empty():
			push_error("GADSHeightImport: cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())])
			return null
		return decode_raw16(raw, int(options.get("raw_width", 0)), bool(options.get("raw_big_endian", false)), path)
	if ext == "png":
		var bytes := FileAccess.get_file_as_bytes(global)
		if bytes.size() > 8 and bytes.slice(0, 8) == PackedByteArray(_PNG_SIGNATURE) and _png_bit_depth(bytes) == 16:
			var decoded := decode_png16(bytes, channel)
			if decoded != null:
				return decoded
	# Loading from the global path reads the source file itself (not its imported texture) without
	# Godot's "will not work on export" warning; this runs in the editor.
	var img := Image.load_from_file(global)
	if img == null or img.is_empty():
		push_error("GADSHeightImport: cannot load %s" % path)
		return null
	return extract_channel(img, channel)


## One channel of [param image] (any format) as FORMAT_RF without mipmaps.
static func extract_channel(image: Image, channel: int) -> Image:
	var img := image.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	if channel == Channel.RED:
		img.convert(Image.FORMAT_RF)
		return img
	img.convert(Image.FORMAT_RGBAF)
	var src := img.get_data().to_float32_array()
	var out := PackedFloat32Array()
	out.resize(src.size() / 4)
	for i in out.size():
		if channel == Channel.LUMINANCE:
			out[i] = (src[i * 4] + src[i * 4 + 1] + src[i * 4 + 2]) / 3.0
		else:
			out[i] = src[i * 4 + channel]
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RF, out.to_byte_array())


## Decodes a non-interlaced 16-bit PNG (grey, grey and alpha, RGB or RGBA) into [param channel]
## as FORMAT_RF 0..1 (65 535 is 1). Returns null when it is not one (the engine loads the rest).
static func decode_png16(bytes: PackedByteArray, channel := Channel.RED) -> Image:
	var pos := 8
	var width := 0
	var height := 0
	var colour_type := -1
	var idat := PackedByteArray()
	while pos + 8 <= bytes.size():
		var length := _u32(bytes, pos)
		var type := bytes.slice(pos + 4, pos + 8).get_string_from_ascii()
		if type == "IHDR":
			width = _u32(bytes, pos + 8)
			height = _u32(bytes, pos + 12)
			colour_type = bytes[pos + 17]
			if bytes[pos + 16] != 16 or bytes[pos + 20] != 0 or not colour_type in [0, 2, 4, 6]:
				return null # not 16 bits, interlaced or palette: the engine's loader
		elif type == "IDAT":
			idat.append_array(bytes.slice(pos + 8, pos + 8 + length))
		elif type == "IEND":
			break
		pos += 12 + length
	if width <= 0 or height <= 0 or idat.is_empty():
		return null
	var channels: int = {0: 1, 2: 3, 4: 2, 6: 4}[colour_type]
	var bpp := 2 * channels
	var stride := width * bpp
	# PNG's image data is one zlib stream, which DEFLATE mode inflates (zlib header included).
	var data := idat.decompress((stride + 1) * height, FileAccess.COMPRESSION_DEFLATE)
	if data.size() != (stride + 1) * height:
		push_error("GADSHeightImport: a 16-bit PNG's image data is damaged")
		return null
	# Which samples to read: one channel, or (luminance) the three colour ones; grey stands for all.
	var picks: Array[int] = []
	if channels <= 2:
		picks = [1 if channel == Channel.ALPHA and channels == 2 else 0]
	elif channel == Channel.LUMINANCE:
		picks = [0, 1, 2]
	elif channel == Channel.ALPHA:
		picks = [3 if channels == 4 else 0]
	else:
		picks = [channel]
	var no_alpha := channel == Channel.ALPHA and channels in [1, 3]
	var scale := 1.0 / (65535.0 * picks.size())
	var out := PackedFloat32Array()
	out.resize(width * height)
	var prev := PackedByteArray()
	prev.resize(stride)
	var o := 0
	for y in height:
		var s := y * (stride + 1)
		var cur := data.slice(s + 1, s + 1 + stride)
		match data[s]:
			1: # Sub
				for i in range(bpp, stride):
					cur[i] = (cur[i] + cur[i - bpp]) & 255
			2: # Up
				for i in stride:
					cur[i] = (cur[i] + prev[i]) & 255
			3: # Average
				for i in stride:
					var a := cur[i - bpp] if i >= bpp else 0
					cur[i] = (cur[i] + ((a + prev[i]) >> 1)) & 255
			4: # Paeth
				for i in stride:
					var a := 0
					var c := 0
					if i >= bpp:
						a = cur[i - bpp]
						c = prev[i - bpp]
					var b := prev[i]
					var p := a + b - c
					var pa := absi(p - a)
					var pb := absi(p - b)
					var pc := absi(p - c)
					cur[i] = (cur[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
		if no_alpha:
			for x in width:
				out[o] = 1.0
				o += 1
		elif picks.size() == 1:
			var k := picks[0] * 2
			for x in width:
				out[o] = ((cur[k] << 8) | cur[k + 1]) * scale
				k += bpp
				o += 1
		else:
			var k := 0
			for x in width:
				out[o] = (((cur[k] << 8) | cur[k + 1]) + ((cur[k + 2] << 8) | cur[k + 3]) + ((cur[k + 4] << 8) | cur[k + 5])) * scale
				k += bpp
				o += 1
		prev = cur
	return Image.create_from_data(width, height, false, Image.FORMAT_RF, out.to_byte_array())


## Raw 16-bit unsigned samples ([param bytes]) as a FORMAT_RF image 0..1, [param width] wide (0:
## square), little-endian unless [param big_endian]. Null with an error when the size does not fit.
static func decode_raw16(bytes: PackedByteArray, width := 0, big_endian := false, label := "raw data") -> Image:
	var samples := bytes.size() / 2
	if bytes.size() % 2 != 0 or samples == 0:
		push_error("GADSHeightImport: %s is not 16-bit samples (%d bytes)" % [label, bytes.size()])
		return null
	if width <= 0:
		width = roundi(sqrt(float(samples)))
		if width * width != samples:
			push_error("GADSHeightImport: %s is not square (%d samples); set its width in the import options" % [label, samples])
			return null
	if samples % width != 0:
		push_error("GADSHeightImport: %s has %d samples, not a multiple of the width %d" % [label, samples, width])
		return null
	var out := PackedFloat32Array()
	out.resize(samples)
	if big_endian:
		for i in samples:
			out[i] = ((bytes[2 * i] << 8) | bytes[2 * i + 1]) / 65535.0
	else:
		for i in samples:
			out[i] = bytes.decode_u16(2 * i) / 65535.0
	return Image.create_from_data(width, samples / width, false, Image.FORMAT_RF, out.to_byte_array())


## [param image] (FORMAT_RF) remapped to 0..1 by [enum Remap], optionally inverted.
static func remap_height(image: Image, mode: int, invert := false) -> Image:
	if mode == Remap.NONE and not invert:
		return image
	var data := image.get_data().to_float32_array()
	var lo := 0.0
	var hi := 1.0
	if mode == Remap.MIN_MAX:
		lo = INF
		hi = -INF
		for v in data:
			lo = minf(lo, v)
			hi = maxf(hi, v)
	elif mode == Remap.PERCENTILES:
		var stats := GADSHeightTools.analyse(image)
		lo = stats["p1"]
		hi = stats["p99"]
	var span := maxf(hi - lo, 1e-9)
	for i in data.size():
		var v := clampf((data[i] - lo) / span, 0.0, 1.0)
		data[i] = 1.0 - v if invert else v
	return Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RF, data.to_byte_array())


## [param image] (FORMAT_RF, level 0) with its full mip chain made by [param filter]. Each texel of
## a level covers the texels of the level above that fall in its area (three along an odd edge),
## so Max and Min keep every peak and pit down to the 1 x 1 level.
static func build_mipmaps(image: Image, filter: int) -> Image:
	if filter == MipFilter.AVERAGE:
		var img := image.duplicate() as Image
		img.clear_mipmaps()
		img.generate_mipmaps()
		return img
	var w := image.get_width()
	var h := image.get_height()
	var level := image.get_data().to_float32_array()
	var chain := level.duplicate()
	var take_max := filter == MipFilter.MAX
	while w > 1 or h > 1:
		var nw := maxi(w >> 1, 1)
		var nh := maxi(h >> 1, 1)
		var next := PackedFloat32Array()
		next.resize(nw * nh)
		for y in nh:
			var y0 := y * h / nh
			var y1 := (y + 1) * h / nh
			for x in nw:
				var x0 := x * w / nw
				var x1 := (x + 1) * w / nw
				var v := level[y0 * w + x0]
				for sy in range(y0, y1):
					var row := sy * w
					for sx in range(x0, x1):
						v = maxf(v, level[row + sx]) if take_max else minf(v, level[row + sx])
				next[y * nw + x] = v
		chain.append_array(next)
		level = next
		w = nw
		h = nh
	return Image.create_from_data(image.get_width(), image.get_height(), true, Image.FORMAT_RF, chain.to_byte_array())


## A texture of [param height] (FORMAT_RF, level 0) for GADS materials and terrains: mipmaps by
## "mip_filter" ([enum MipFilter], average; "mipmaps": false for none), stored as "float" 32-bit
## or else half floats (11 bits of precision: plenty for material relief; terrains of tens of
## metres want 32).
static func make_texture(height: Image, options := {}) -> ImageTexture:
	var img := height
	if bool(options.get("mipmaps", true)):
		img = build_mipmaps(height, int(options.get("mip_filter", MipFilter.AVERAGE)))
	else:
		img = height.duplicate() as Image
		img.clear_mipmaps()
	if not bool(options.get("float", false)):
		img.convert(Image.FORMAT_RH)
	return ImageTexture.create_from_image(img)


## [method load_height], [method remap_height] and [method make_texture] in one: what the importer does.
## Extra options: "remap" ([enum Remap]), "invert".
static func import_texture(path: String, options := {}) -> ImageTexture:
	var height := load_height(path, options)
	if height == null:
		return null
	height = remap_height(height, int(options.get("remap", Remap.NONE)), bool(options.get("invert", false)))
	return make_texture(height, options)


static func _u32(b: PackedByteArray, at: int) -> int:
	return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]


## The bit depth in a PNG's header (its first chunk), or 0.
static func _png_bit_depth(bytes: PackedByteArray) -> int:
	if bytes.size() < 33 or bytes.slice(12, 16).get_string_from_ascii() != "IHDR":
		return 0
	return bytes[24]
