@tool
class_name GADSHeightImport
extends RefCounted
## Height maps at full precision, with mipmaps made for displacement. Godot's image loader reads
## 16-bit PNGs as 8 bits (256 steps: terraces once displaced) and has no loader for the RAW / R16
## heightmaps terrain tools write (World Machine, Gaea, Unity); [method load_height] reads both
## at their 65 536 steps (and every other format through the engine). [method build_mipmaps]
## makes the mip chain by averaging, or by keeping each block's highest or lowest value, so
## distant parallax keeps (Max) the peaks an average would flatten. The GADS Height Map importer
## ("Import As" in the Import dock) runs these on import. [method import_as_regions] bridges the
## loader to the terrain's region system: a large heightmap (World Machine / Unreal / Unity /
## HTerrain) becomes a set of per-region files a streaming [GADSTerrain3D] loads sparsely.
## [codeblock]
## var height := GADSHeightImport.load_height("res://terrain/world.r16")  # FORMAT_RF, 0..1
## var tex := GADSHeightImport.make_texture(height, {"mip_filter": GADSHeightImport.MipFilter.MAX})
## # A 16k heightmap -> per-region files a streaming terrain loads (Stage 4a):
## GADSHeightImport.import_as_regions("res://terrain/world_16k.r16", "res://terrain/regions",
##     {"size": Vector2(4096, 4096), "height_scale": 600.0, "region_size": 256.0})
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


# --- Region import (Stage 5) --------------------------------------------------------------------
# Bridges the single-file loader above to the terrain's region system: a large heightmap (up to ~16k,
# from World Machine / Unreal / Unity / HTerrain) becomes a set of per-region files that a streaming
# GADSTerrain3D loads sparsely (Stage 4a), instead of one texture the whole world must hold. These
# are a thin orchestration layer -- load_height reads the heightmap, GADSTerrain3D.build_region_store
# splits it into the region grid and save_regions writes the files; no new parsing or splitting here.
#
# PER-TOOL CONVENTIONS (which options to pass). The terrain's vertex grid is "size / vertex_spacing"
# quads, rounded to a whole number of "chunk_quads", plus one (n * chunk_quads + 1 vertices). The
# region files are one texel per vertex, so the import fits the source heightmap to that grid (the
# same bilinear get_height samples it with); a heightmap already at the grid resolution is byte-exact.
#   - Unreal Engine: 16-bit RAW, little-endian, grey, sized (n * chunk_component) + 1 (e.g. 505, 1009,
#     2017, 4033, 8129). Pass the file (".raw"/".r16" use decode_raw16); the default scale is Z 100
#     (the landscape's Scale maps 0..65535 to -256..256 m by default), so set "height_scale" to your
#     landscape's metres and "remap" NONE. A square map auto-detects its width; otherwise set "raw_width".
#   - Unity: terrain exports 16-bit RAW, usually little-endian (set "raw_big_endian" if a Mac export),
#     sized 2^k + 1 (513, 1025, 2049, 4097). "height_scale" = the terrain's Y size; "remap" NONE.
#   - World Machine: r16 (16-bit RAW) or EXR, often a power of two (1024, 4096) rather than n + 1 --
#     then the fit resamples it onto the grid. r16 is little-endian; EXR loads through the engine at
#     full float. Use its "Height Output"/"Terrain Scalar" for "height_scale". Tiled builds: see
#     [method import_tiles_as_regions].
#   - HTerrain (Godot plugin): exports a 16-bit RAW ("terrain export" / RAW) or an EXR, sized 2^k + 1.
#     EXR keeps full precision; r16 is little-endian. "height_scale" = the HTerrain height range.

## Imports the heightmap at [param height_path] into a per-region file set under [param out_dir] that
## a streaming [GADSTerrain3D] loads (Stage 5). Loads it with [method load_height] (so [param params]
## may carry "channel", "raw_width", "raw_big_endian" and "remap"/"invert" exactly as the single-file
## importer takes them), configures an off-tree terrain with the geometry from [param params]
## ("size" in metres -- default the heightmap sized at "vertex_spacing" per texel -- "vertex_spacing",
## "chunk_quads", "region_size", "height_scale", "height_offset") and that map, then calls
## [method GADSTerrain3D.save_regions]. "splat" and "holes" ([Image], [Texture2D] or a path) add those
## maps. Returns [constant OK] or an error. Editor use: holding the whole heightmap in memory for this
## one-time import is fine; it is the runtime residency the region files keep sparse.
static func import_as_regions(height_path: String, out_dir: String, params := {}) -> Error:
	var height := load_height(height_path, params)
	if height == null:
		return ERR_FILE_CANT_READ
	height = remap_height(height, int(params.get("remap", Remap.NONE)), bool(params.get("invert", false)))
	return _save_image_as_regions(height, out_dir, params)


## Imports a heightmap already split into one file per tile (e.g. a World Machine tiled build) into a
## per-region file set under [param out_dir]. Reassembles the tiles into the whole heightmap with
## [method assemble_tiles], then does exactly what [method import_as_regions] does (so the same
## [param params] apply, plus the tile options [method assemble_tiles] reads). A pre-tiled set imports
## into the same region set as the equivalent whole map. Returns [constant OK] or an error.
static func import_tiles_as_regions(tiles_dir: String, out_dir: String, params := {}) -> Error:
	var whole := assemble_tiles(tiles_dir, params)
	if whole == null:
		return ERR_FILE_NOT_FOUND
	whole = remap_height(whole, int(params.get("remap", Remap.NONE)), bool(params.get("invert", false)))
	return _save_image_as_regions(whole, out_dir, params)


## Reassembles a grid of heightmap tiles under [param tiles_dir] into one FORMAT_RF [Image], or null
## with an error. A tile's file name ends in its grid position: [code]<name>_<col>_<row>.<ext>[/code]
## (the common terrain-tool naming); the two trailing integers are column then row, or row then column
## with "tile_row_first" true. [param params] options: "tile_extension" (the tiles' extension, default
## "r16"), "overlap" (texels shared on the border between neighbours, default 0 -- set 1 for tools that
## repeat the edge row/column), and the [method load_height] options for the tiles ("raw_width",
## "raw_big_endian", "channel"). Every tile must be the same size and the whole grid must be present.
static func assemble_tiles(tiles_dir: String, params := {}) -> Image:
	var ext := str(params.get("tile_extension", "r16")).to_lower()
	var overlap := int(params.get("overlap", 0))
	var row_first := bool(params.get("tile_row_first", false))
	var da := DirAccess.open(tiles_dir)
	if da == null:
		push_error("GADSHeightImport: cannot open tiles directory %s" % tiles_dir)
		return null
	var tiles := {} # Vector2i(col, row) -> path
	for f in da.get_files():
		if f.get_extension().to_lower() != ext:
			continue
		var coord := _tile_coord(f, row_first)
		if coord.x >= 0:
			tiles[tiles_dir.path_join(f)] = coord
	if tiles.is_empty():
		push_error("GADSHeightImport: no tiles named <name>_<col>_<row>.%s under %s" % [ext, tiles_dir])
		return null
	var cols := 0
	var rows := 0
	for coord: Vector2i in tiles.values():
		cols = maxi(cols, coord.x + 1)
		rows = maxi(rows, coord.y + 1)
	# Load each tile at full precision (through load_height, so RAW options apply) and check it is
	# present and the same size as the rest; tiles are assumed equal-sized and abutting.
	var images := {} # Vector2i -> Image
	var tw := 0
	var th := 0
	for path: String in tiles:
		var coord: Vector2i = tiles[path]
		var img := load_height(path, params)
		if img == null:
			return null
		if tw == 0:
			tw = img.get_width()
			th = img.get_height()
		elif img.get_width() != tw or img.get_height() != th:
			push_error("GADSHeightImport: tile %s is %d x %d, not the grid's %d x %d" % [path, img.get_width(), img.get_height(), tw, th])
			return null
		images[coord] = img
	for ry in rows:
		for rx in cols:
			if not images.has(Vector2i(rx, ry)):
				push_error("GADSHeightImport: the %d x %d tile grid is missing (%d, %d)" % [cols, rows, rx, ry])
				return null
	var step_x := tw - overlap
	var step_y := th - overlap
	var whole_w := step_x * (cols - 1) + tw
	var whole_h := step_y * (rows - 1) + th
	var out := PackedFloat32Array()
	out.resize(whole_w * whole_h)
	for coord: Vector2i in images:
		var data := (images[coord] as Image).get_data().to_float32_array()
		var ox := coord.x * step_x
		var oy := coord.y * step_y
		for y in th:
			var dst := (oy + y) * whole_w + ox
			var srow := y * tw
			for x in tw:
				out[dst + x] = data[srow + x]
	return Image.create_from_data(whole_w, whole_h, false, Image.FORMAT_RF, out.to_byte_array())


## The (col, row) a tile file name ends in ([code]<name>_<col>_<row>.<ext>[/code]: the two trailing
## integers), or (-1, -1) when it has none. [param row_first] reads them as row then column instead.
static func _tile_coord(file: String, row_first := false) -> Vector2i:
	var parts := file.get_basename().split("_")
	if parts.size() < 2:
		return Vector2i(-1, -1)
	var a := parts[parts.size() - 2]
	var b := parts[parts.size() - 1]
	if not a.is_valid_int() or not b.is_valid_int():
		return Vector2i(-1, -1)
	return Vector2i(int(b), int(a)) if row_first else Vector2i(int(a), int(b))


## An optional splat / hole map from [param value] ([Image], [Texture2D] or a path), or null.
static func _optional_map_image(value: Variant) -> Image:
	if value is Image:
		return value
	if value is Texture2D:
		return (value as Texture2D).get_image()
	if value is String and not (value as String).is_empty():
		var img := Image.load_from_file(ProjectSettings.globalize_path(value))
		if img == null or img.is_empty():
			push_error("GADSHeightImport: cannot load map %s" % value)
			return null
		return img
	return null


## Configures an off-tree [GADSTerrain3D] with [param params]' geometry and [param height] (plus an
## optional "splat" / "holes" map) and writes its region files to [param out_dir]. Shared by
## [method import_as_regions] and [method import_tiles_as_regions]. The terrain is never added to the
## scene: [method GADSTerrain3D.build_region_store] builds only the maps the save needs, no geometry.
static func _save_image_as_regions(height: Image, out_dir: String, params := {}) -> Error:
	var vertex_spacing := float(params.get("vertex_spacing", 1.0))
	var default_size := Vector2(maxi(height.get_width() - 1, 1), maxi(height.get_height() - 1, 1)) * vertex_spacing
	var t := GADSTerrain3D.new()
	t.chunk_quads = int(params.get("chunk_quads", 64))
	t.vertex_spacing = vertex_spacing
	t.size = params.get("size", default_size)
	t.region_size = float(params.get("region_size", 1024.0))
	t.height_scale = float(params.get("height_scale", 40.0))
	t.height_offset = float(params.get("height_offset", 0.0))
	t.heightmap = ImageTexture.create_from_image(height)
	var splat := _optional_map_image(params.get("splat"))
	if splat != null:
		t.splatmap = ImageTexture.create_from_image(splat)
	var holes := _optional_map_image(params.get("holes"))
	if holes != null:
		t.holes = ImageTexture.create_from_image(holes)
	t.build_region_store()
	var err := t.save_regions(out_dir)
	t.free() # off-tree, built no geometry: frees its maps at once, nothing to wait on
	return err


static func _u32(b: PackedByteArray, at: int) -> int:
	return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]


## The bit depth in a PNG's header (its first chunk), or 0.
static func _png_bit_depth(bytes: PackedByteArray) -> int:
	if bytes.size() < 33 or bytes.slice(12, 16).get_string_from_ascii() != "IHDR":
		return 0
	return bytes[24]
