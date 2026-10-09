@tool
class_name GADSProceduralGD
extends RefCounted
## GADSProcedural's maps in GDScript, for platforms without the GADS native library: the same
## kinds, parameters and outputs as the native GADSHeightGenerator, in seconds rather than
## milliseconds. The patterns are the native ones; the noise under them is value noise (a random
## grid per octave, upscaled bicubically by the engine) rather than gradient noise, so a map looks
## like the native one of the same seed without being the same. Ambient occlusion and curvature
## compare the relief with a blurred copy of itself (the native occlusion traces horizons).

const TAU_ := TAU


## A size x size height map (FORMAT_RF, 0..1) of [param kind]; null for an unknown kind.
static func generate(kind: String, size: int, params: Dictionary) -> Image:
	var kinds := ["noise", "ridged", "billow", "rock", "stones", "cracks", "bricks", "tiles", "waves", "ripples", "craters", "scales", "dunes"]
	var k := kinds.find(kind)
	if k < 0 or size < 4:
		return null
	var seed_value := int(params.get("seed", 1)) * 7919 + 1
	var scale := maxf(1.0, float(params.get("scale", 4.0)))
	var cells := maxi(1, roundi(scale))
	var octaves := clampi(int(params.get("octaves", 5)), 1, 16)
	var gain := float(params.get("gain", 0.5))
	var lacunarity := maxi(1, roundi(float(params.get("lacunarity", 2.0))))
	var warp := float(params.get("warp", 0.0))
	var width := float(params.get("width", 0.08))
	var bevel := float(params.get("bevel", 0.2))
	var variation := float(params.get("variation", 0.3))
	var aspect := float(params.get("aspect", 2.0))
	var roughness := float(params.get("roughness", 0.05))
	var sharp := clampf(float(params.get("sharpness", 0.3)), 0.0, 1.0)
	var count := int(params.get("count", 0))
	var fields := {}
	var field := func(name: String, base: int, octs: int, mode: int, s: int) -> PackedFloat32Array:
		if not fields.has(name):
			fields[name] = _fbm(size, base, octs, gain, lacunarity, mode, s)
		return fields[name]
	var warp_x := PackedFloat32Array()
	var warp_y := PackedFloat32Array()
	if warp != 0.0 or k == 12:
		warp_x = field.call("wx", cells, 3, 0, seed_value + 501)
		warp_y = field.call("wy", cells, 3, 0, seed_value + 907)
	var fine := PackedFloat32Array()
	if k >= 4 and k != 8 and k != 9:
		fine = field.call("fine", cells * 8, 3, 0, seed_value + 101)
	var main := PackedFloat32Array()
	var main_plain := PackedFloat32Array()
	if k <= 3:
		main = field.call("main", cells, octaves, [0, 1, 2, 1][k], seed_value)
		if k == 3:
			main_plain = field.call("plain", cells, octaves, 0, seed_value)
	var rows := maxi(2, cells + (cells & 1))
	var per_row := rows if k == 7 or k == 11 else maxi(1, roundi(rows / maxf(aspect, 0.1)))
	# Voronoi points (stones, cracks) on an n x n wrapped grid.
	var vor_x := PackedFloat32Array()
	var vor_y := PackedFloat32Array()
	if k == 4 or k == 5:
		vor_x.resize(cells * cells)
		vor_y.resize(cells * cells)
		for j in cells:
			for i in cells:
				vor_x[j * cells + i] = 0.5 + 0.8 * (_rnd(i, j, seed_value + 31) - 0.5)
				vor_y[j * cells + i] = 0.5 + 0.8 * (_rnd(i, j, seed_value + 48) - 0.5)
	var waves := []
	if k == 8:
		var main_dir := _rnd(1, 2, seed_value) * TAU_
		for i in 6:
			var ang := main_dir + (_rnd(i, 3, seed_value) - 0.5) * 1.2
			var mag := scale * (0.6 + 0.8 * _rnd(i, 4, seed_value)) * (1.0 + 0.35 * i)
			var a := roundi(mag * cos(ang))
			var b := roundi(mag * sin(ang))
			if a == 0 and b == 0:
				a = 1
			waves.append([a, b, _rnd(i, 5, seed_value) * TAU_, 1.0 / (1.0 + 0.6 * i)])
	var spots := []
	if k == 9 or k == 10:
		var n := count if count > 0 else (cells if k == 9 else cells * cells / 2 + 1)
		for i in n:
			var r := minf(0.2, (0.3 + 0.7 * _rnd(i, 9, seed_value)) * 0.5 / scale) if k == 10 else 0.0
			spots.append([_rnd(i, 7, seed_value), _rnd(i, 8, seed_value), r])
	var dune_a := cells
	var dune_b := roundi(cells * 0.6 * (_rnd(3, 1, seed_value) - 0.5))
	var out := PackedFloat32Array()
	out.resize(size * size)
	for row in size:
		for col in size:
			var u := (col + 0.5) / size
			var v := (row + 0.5) / size
			if warp != 0.0:
				u += warp * _at(warp_x, size, u, v) / cells
				v += warp * _at(warp_y, size, u, v) / cells
			var h := 0.0
			match k:
				0, 1, 2:
					h = _at(main, size, u, v)
				3:
					h = 0.65 * _at(main, size, u, v) + 0.35 * (0.5 + 0.5 * _at(main_plain, size, u + 0.37, v + 0.71))
				4, 5:
					var q := _voronoi(vor_x, vor_y, cells, u * cells, v * cells)
					var r := _rnd(q[1], q[2], seed_value + 61)
					if k == 4:
						h = _plateau(q[0], width, bevel) * (1.0 - variation * r)
					else:
						h = 1.0 - (1.0 - smoothstep(0.0, maxf(width, 1e-4), q[0])) * (1.0 - 0.5 * variation * r)
					h += roughness * _at(fine, size, u, v)
				6, 7:
					var fr := v * rows
					var r := floori(fr)
					var offset := 0.5 if k == 6 and posmod(r, rows) & 1 else 0.0
					var fc := u * per_row + offset
					var c := floori(fc)
					var fu := fc - c
					var fv := fr - r
					var dx := minf(fu, 1.0 - fu) * float(rows) / per_row
					var dy := minf(fv, 1.0 - fv)
					h = _plateau(minf(dx, dy), width, bevel) * (1.0 - variation * _rnd(posmod(c, per_row), posmod(r, rows), seed_value + 61))
					h += roughness * _at(fine, size, u, v)
				8:
					for w: Array in waves:
						var s := 0.5 + 0.5 * sin(TAU_ * (w[0] * u + w[1] * v) + w[2])
						h += w[3] * pow(s, 1.0 + 4.0 * sharp)
				9:
					var freq := 3.0 * scale
					for s: Array in spots:
						var dx := _torus(u - s[0])
						var dy := _torus(v - s[1])
						var r := sqrt(dx * dx + dy * dy)
						h += cos(TAU_ * r * freq) * exp(-r * 6.0) * (1.0 - smoothstep(0.3, 0.5, r))
				10:
					for s: Array in spots:
						var dx := _torus(u - s[0])
						var dy := _torus(v - s[1])
						var t: float = sqrt(dx * dx + dy * dy) / float(s[2])
						if t > 2.0:
							continue
						var bowl: float = -(1.0 - t * t) if t < 1.0 else 0.0
						var rim := 0.35 * exp(-pow((t - 1.0) / 0.25, 2.0))
						h += (bowl + rim) * (1.0 - smoothstep(1.5, 2.0, t))
					h += roughness * _at(fine, size, u, v)
				11:
					var fr := v * rows
					var r := floori(fr)
					var covered := false
					var rr := r + 1
					while rr >= r - 1 and not covered:
						var offset := 0.5 if posmod(rr, rows) & 1 else 0.0
						var fc := u * per_row - offset
						var c0 := floori(fc)
						for c in range(c0 - 1, c0 + 2):
							var du := (fc - (c + 0.5)) / 0.62
							var dv := (fr - (rr + 0.15)) / 0.85
							var t2 := du * du + dv * dv
							if t2 < 1.0:
								covered = true
								h = (0.25 + 0.75 * sqrt(1.0 - t2)) * (1.0 - variation * _rnd(posmod(c, per_row), posmod(rr, rows), seed_value + 61))
								break
						rr -= 1
					h += roughness * _at(fine, size, u, v)
				12:
					var w := 0.3 * _at(warp_x, size, u, v)
					var s := dune_a * u + dune_b * v + w
					s -= floorf(s)
					h = smoothstep(0.0, 1.0, s / 0.78) if s < 0.78 else 1.0 - smoothstep(0.0, 1.0, (s - 0.78) / 0.22)
					h += 0.06 * (0.5 + 0.5 * sin(TAU_ * (7 * dune_a * u + (7 * dune_b + 2) * v + 3.0 * w)))
					h += roughness * _at(fine, size, u, v)
			out[row * size + col] = h
	_normalise(out)
	return Image.create_from_data(size, size, false, Image.FORMAT_RF, out.to_byte_array())


## Tangent-space normals (OpenGL convention, RGB8) of a height map spanning [param depth_m] over
## [param tile_m].
static func normal_map(height: Image, depth_m: float, tile_m: Vector2) -> Image:
	var h := _floats(height)
	var w := height.get_width()
	var ht := height.get_height()
	var tx := tile_m.x / w
	var ty := tile_m.y / ht
	var out := PackedByteArray()
	out.resize(w * ht * 3)
	for y in ht:
		for x in w:
			var du := (h[y * w + posmod(x + 1, w)] - h[y * w + posmod(x - 1, w)]) * depth_m / (2.0 * tx)
			var dv := (h[posmod(y + 1, ht) * w + x] - h[posmod(y - 1, ht) * w + x]) * depth_m / (2.0 * ty)
			var n := Vector3(-du, dv, 1.0).normalized()
			var i := (y * w + x) * 3
			out[i] = clampi(roundi((0.5 + 0.5 * n.x) * 255.0), 0, 255)
			out[i + 1] = clampi(roundi((0.5 + 0.5 * n.y) * 255.0), 0, 255)
			out[i + 2] = clampi(roundi((0.5 + 0.5 * n.z) * 255.0), 0, 255)
	return Image.create_from_data(w, ht, false, Image.FORMAT_RGB8, out)


## Ambient occlusion (FORMAT_RF, 1 = open): how far the relief within [param radius_m] rises
## above each point, from a blurred copy.
static func ambient_occlusion(height: Image, depth_m: float, tile_m: Vector2, radius_m: float) -> Image:
	var h := _floats(height)
	var w := height.get_width()
	var ht := height.get_height()
	var radius_texels := radius_m / maxf(tile_m.x / w, 1e-9)
	var blur := _blurred(height, radius_texels)
	var out := PackedFloat32Array()
	out.resize(h.size())
	for i in h.size():
		var slope := maxf(blur[i] - h[i], 0.0) * depth_m / maxf(radius_m * 0.25, 1e-9)
		out[i] = 1.0 - 0.8 * slope / sqrt(1.0 + slope * slope)
	return Image.create_from_data(w, ht, false, Image.FORMAT_RF, out.to_byte_array())


## Curvature (FORMAT_RF, 0.5 flat): the relief against its blur over [param radius_texels].
static func curvature(height: Image, radius_texels: float, gain: float) -> Image:
	var h := _floats(height)
	var blur := _blurred(height, radius_texels)
	var out := PackedFloat32Array()
	out.resize(h.size())
	for i in h.size():
		out[i] = clampf(0.5 + gain * (h[i] - blur[i]), 0.0, 1.0)
	return Image.create_from_data(height.get_width(), height.get_height(), false, Image.FORMAT_RF, out.to_byte_array())


## Albedo (RGB8): low to high by height, darker where occluded and in hollows.
static func albedo_map(height: Image, low: Color, high: Color, ao: Image, curv: Image, ao_strength: float, cavity_strength: float) -> Image:
	var h := _floats(height)
	var a := _floats(ao) if ao != null else PackedFloat32Array()
	var c := _floats(curv) if curv != null else PackedFloat32Array()
	var out := PackedByteArray()
	out.resize(h.size() * 3)
	for i in h.size():
		var t := clampf(h[i], 0.0, 1.0)
		var shade := 1.0
		if i < a.size():
			shade *= 1.0 - ao_strength * (1.0 - clampf(a[i], 0.0, 1.0))
		if i < c.size():
			shade *= 1.0 - cavity_strength * clampf((0.5 - c[i]) * 2.0, 0.0, 1.0)
		var col := low.lerp(high, t) * shade
		out[i * 3] = clampi(roundi(col.r * 255.0), 0, 255)
		out[i * 3 + 1] = clampi(roundi(col.g * 255.0), 0, 255)
		out[i * 3 + 2] = clampi(roundi(col.b * 255.0), 0, 255)
	return Image.create_from_data(height.get_width(), height.get_height(), false, Image.FORMAT_RGB8, out)


## ORM (RGB8): occlusion, roughness a little lower on crests and higher in hollows, metallic 0.
static func orm_map(ao: Image, curv: Image, roughness: float, variation: float) -> Image:
	var ref := ao if ao != null else curv
	var a := _floats(ao) if ao != null else PackedFloat32Array()
	var c := _floats(curv) if curv != null else PackedFloat32Array()
	var n := ref.get_width() * ref.get_height()
	var out := PackedByteArray()
	out.resize(n * 3)
	for i in n:
		var cv := (c[i] - 0.5) * 2.0 if i < c.size() else 0.0
		out[i * 3] = clampi(roundi((a[i] if i < a.size() else 1.0) * 255.0), 0, 255)
		out[i * 3 + 1] = clampi(roundi(clampf(roughness - variation * cv, 0.0, 1.0) * 255.0), 0, 255)
		out[i * 3 + 2] = 0
	return Image.create_from_data(ref.get_width(), ref.get_height(), false, Image.FORMAT_RGB8, out)


# --- Helpers ------------------------------------------------------------------------------------

## Uniform in [0, 1) for a lattice point and a seed (an integer hash).
static func _rnd(x: int, y: int, seed_value: int) -> float:
	var h := (x * 374761393 + y * 668265263 + seed_value * 2147483647) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0


static func _torus(d: float) -> float:
	return d - floorf(d + 0.5)


static func _plateau(border: float, width: float, bevel: float) -> float:
	if border < 0.5 * width:
		return 0.0
	var s := clampf((border - 0.5 * width) / maxf(bevel, 1e-6), 0.0, 1.0)
	return sqrt(s * (2.0 - s))


## A size x size field (wrapped) sampled at tile coordinates (u, v), bilinear.
static func _at(f: PackedFloat32Array, size: int, u: float, v: float) -> float:
	var x := u * size - 0.5
	var y := v * size - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var xa := posmod(x0, size)
	var xb := posmod(x0 + 1, size)
	var ya := posmod(y0, size) * size
	var yb := posmod(y0 + 1, size) * size
	return lerpf(lerpf(f[ya + xa], f[ya + xb], fx), lerpf(f[yb + xa], f[yb + xb], fx), fy)


## Fractal value noise, size x size, tileable: octave o has period base * lacunarity^o cells,
## each a random grid in -1..1 upscaled bicubically by the engine (with wrapped borders); mode 1
## ridged, 2 billow, as the native noise.
static func _fbm(size: int, base: int, octaves: int, gain: float, lacunarity: int, mode: int, seed_value: int) -> PackedFloat32Array:
	var sum := PackedFloat32Array()
	sum.resize(size * size)
	var amp := 1.0
	var norm := 0.0
	var period := base
	for o in octaves:
		if period > size / 2:
			break
		var layer := _octave(size, period, seed_value + o * 1013)
		for i in sum.size():
			var n := layer[i]
			if mode == 1:
				n = 1.0 - absf(n)
				n *= n
			elif mode == 2:
				n = absf(n)
			sum[i] += amp * n
		norm += amp
		amp *= gain
		period *= lacunarity
	if norm > 0.0:
		for i in sum.size():
			sum[i] /= norm
	return sum


static func _octave(size: int, period: int, seed_value: int) -> PackedFloat32Array:
	const PAD := 2
	var n := period + 2 * PAD
	var grid := PackedFloat32Array()
	grid.resize(n * n)
	for y in n:
		for x in n:
			grid[y * n + x] = _rnd(posmod(x - PAD, period), posmod(y - PAD, period), seed_value) * 2.0 - 1.0
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RF, grid.to_byte_array())
	var cell := float(size) / period
	var big := roundi(n * cell)
	img.resize(big, big, Image.INTERPOLATE_CUBIC)
	var origin := roundi(PAD * cell)
	return img.get_region(Rect2i(origin, origin, size, size)).get_data().to_float32_array()


## [distance to the cell border (cells), cell i, cell j] of point (x, y) (cells) on the wrapped grid.
static func _voronoi(px: PackedFloat32Array, py: PackedFloat32Array, n: int, x: float, y: float) -> Array:
	var cx := floori(x)
	var cy := floori(y)
	var best := INF
	var bx := 0.0
	var by := 0.0
	var bi := cx
	var bj := cy
	for j in range(-1, 2):
		for i in range(-1, 2):
			var k := posmod(cy + j, n) * n + posmod(cx + i, n)
			var qx := cx + i + px[k]
			var qy := cy + j + py[k]
			var d := (qx - x) * (qx - x) + (qy - y) * (qy - y)
			if d < best:
				best = d
				bx = qx
				by = qy
				bi = cx + i
				bj = cy + j
	var edge := INF
	for j in range(-2, 3):
		for i in range(-2, 3):
			if i == 0 and j == 0:
				continue
			var k := posmod(bj + j, n) * n + posmod(bi + i, n)
			var qx := bi + i + px[k]
			var qy := bj + j + py[k]
			var dx := qx - bx
			var dy := qy - by
			var len := sqrt(dx * dx + dy * dy)
			if len < 1e-9:
				continue
			edge = minf(edge, ((0.5 * (qx + bx) - x) * dx + (0.5 * (qy + by) - y) * dy) / len)
	return [edge, posmod(bi, n), posmod(bj, n)]


static func _normalise(h: PackedFloat32Array) -> void:
	if h.is_empty():
		return
	var lo := INF
	var hi := -INF
	for v in h:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var inv := 1.0 / (hi - lo) if hi - lo > 1e-12 else 0.0
	for i in h.size():
		h[i] = (h[i] - lo) * inv


static func _floats(img: Image) -> PackedFloat32Array:
	var copy := img.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	copy.clear_mipmaps()
	copy.convert(Image.FORMAT_RF)
	return copy.get_data().to_float32_array()


## A blur of [param img] over about [param radius] texels: down to the radius's scale and back up
## bicubically (wrapped borders, so a tile stays a tile).
static func _blurred(img: Image, radius: float) -> PackedFloat32Array:
	var w := img.get_width()
	var h := img.get_height()
	var factor := maxi(roundi(radius), 1)
	var small := maxi(w / factor, 2)
	var smallh := maxi(h / factor, 2)
	var copy := img.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	copy.clear_mipmaps()
	copy.convert(Image.FORMAT_RF)
	# Halving with bilinear filtering averages 2 x 2 texels a step (one bilinear resize to the
	# small size would point-sample instead).
	while copy.get_width() > small * 2 or copy.get_height() > smallh * 2:
		copy.resize(maxi(copy.get_width() / 2, small), maxi(copy.get_height() / 2, smallh), Image.INTERPOLATE_BILINEAR)
	copy.resize(small, smallh, Image.INTERPOLATE_BILINEAR)
	# Wrap two texels around the small image, upscale, crop the middle.
	const PAD := 2
	var padded := Image.create_empty(small + 2 * PAD, smallh + 2 * PAD, false, Image.FORMAT_RF)
	for y in smallh + 2 * PAD:
		for x in small + 2 * PAD:
			padded.set_pixel(x, y, copy.get_pixel(posmod(x - PAD, small), posmod(y - PAD, smallh)))
	var sx := float(w) / small
	var sy := float(h) / smallh
	padded.resize(roundi((small + 2 * PAD) * sx), roundi((smallh + 2 * PAD) * sy), Image.INTERPOLATE_CUBIC)
	return padded.get_region(Rect2i(roundi(PAD * sx), roundi(PAD * sy), w, h)).get_data().to_float32_array()


## Hydraulic, then thermal erosion of [param height]'s red channel, as the native
## GADSHeightGenerator.erode (the same algorithm, parameters and random sequence): FORMAT_RF.
## Much slower: a 257 x 257 terrain's default 33 000 droplets take tens of seconds.
static func erode(height: Image, params: Dictionary) -> Image:
	var w := height.get_width()
	var h := height.get_height()
	var src := _floats(height)
	var cell_m := float(params.get("cell_m", 1.0))
	var height_m := float(params.get("height_m", 1.0))
	if w < 2 or h < 2 or cell_m <= 0.0 or height_m <= 0.0:
		return Image.create_from_data(w, h, false, Image.FORMAT_RF, src.to_byte_array())
	# In texel units vertically too, so slopes are rise over run.
	var to_texels := height_m / cell_m
	var v := PackedFloat64Array()
	v.resize(w * h)
	for i in v.size():
		v[i] = src[i] * to_texels
	var wrap := bool(params.get("wrap", false))
	_hydraulic(v, w, h, wrap, params)
	_thermal(v, w, h, wrap, params)
	var out := PackedFloat32Array()
	out.resize(v.size())
	for i in v.size():
		out[i] = v[i] / to_texels
	return Image.create_from_data(w, h, false, Image.FORMAT_RF, out.to_byte_array())


# xorshift64* as the native library runs it on unsigned 64-bit integers: GDScript's are signed, so
# right shifts are masked to stay logical (multiplications wrap the same way).
const _RNG_SEED_MUL := -7046029254386353131 # 0x9E3779B97F4A7C15
const _RNG_SEED_ADD := 7146057691288625177 # 0x632BE59BD9B4E019
const _RNG_MUL := 2685821657736338717


static func _rng_next(state: PackedInt64Array) -> float:
	var s := state[0]
	s ^= (s >> 12) & ((1 << 52) - 1)
	s ^= s << 25
	s ^= (s >> 27) & ((1 << 37) - 1)
	state[0] = s
	return float(((s * _RNG_MUL) >> 11) & ((1 << 53) - 1)) * (1.0 / 9007199254740992.0)


static func _hydraulic(v: PackedFloat64Array, w: int, h: int, wrap: bool, p: Dictionary) -> void:
	var droplets := int(p.get("droplets", 0))
	if droplets <= 0:
		return
	var max_steps := int(p.get("max_steps", 64))
	var inertia := clampf(float(p.get("inertia", 0.05)), 0.0, 1.0)
	var capacity := float(p.get("capacity", 0.3))
	var min_capacity := float(p.get("min_capacity", 0.01))
	var erosion := float(p.get("erosion", 0.3))
	var deposition := float(p.get("deposition", 0.3))
	var evaporation := float(p.get("evaporation", 0.02))
	var gravity := float(p.get("gravity", 4.0))
	var r := maxi(int(p.get("radius", 3)), 1)
	var bdx := PackedInt32Array()
	var bdy := PackedInt32Array()
	var bw := PackedFloat64Array()
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var d := sqrt(float(dx * dx + dy * dy))
			if d < r:
				bdx.append(dx)
				bdy.append(dy)
				bw.append(r - d)
	var nb := bdx.size()
	var state := PackedInt64Array([int(p.get("seed", 1)) * _RNG_SEED_MUL + _RNG_SEED_ADD])
	var wmax := float(w if wrap else w - 1)
	var hmax := float(h if wrap else h - 1)
	for drop in droplets:
		var x := _rng_next(state) * wmax
		var y := _rng_next(state) * hmax
		var dir_x := 0.0
		var dir_y := 0.0
		var speed := 1.0
		var water := 1.0
		var sediment := 0.0
		var left := false
		for step in max_steps:
			var ix := floori(x)
			var iy := floori(y)
			var u := x - ix
			var t := y - iy
			# Bilinear height and gradient here.
			var x0 := posmod(ix, w) if wrap else ix
			var x1 := posmod(ix + 1, w) if wrap else ix + 1
			var y0 := (posmod(iy, h) if wrap else iy) * w
			var y1 := (posmod(iy + 1, h) if wrap else iy + 1) * w
			var h00 := v[y0 + x0]
			var h10 := v[y0 + x1]
			var h01 := v[y1 + x0]
			var h11 := v[y1 + x1]
			var gx := (h10 - h00) * (1.0 - t) + (h11 - h01) * t
			var gy := (h01 - h00) * (1.0 - u) + (h11 - h10) * u
			var here := h00 * (1.0 - u) * (1.0 - t) + h10 * u * (1.0 - t) + h01 * (1.0 - u) * t + h11 * u * t
			dir_x = dir_x * inertia - gx * (1.0 - inertia)
			dir_y = dir_y * inertia - gy * (1.0 - inertia)
			var length := sqrt(dir_x * dir_x + dir_y * dir_y)
			if length < 1e-12:
				break
			dir_x /= length
			dir_y /= length
			var nx := x + dir_x
			var ny := y + dir_y
			if not wrap and (nx < 0.0 or ny < 0.0 or nx >= w - 1 or ny >= h - 1):
				left = true # what it carries flows off the field
				break
			var jx := floori(nx)
			var jy := floori(ny)
			var nu := nx - jx
			var nt := ny - jy
			var a0 := posmod(jx, w) if wrap else jx
			var a1 := posmod(jx + 1, w) if wrap else jx + 1
			var b0 := (posmod(jy, h) if wrap else jy) * w
			var b1 := (posmod(jy + 1, h) if wrap else jy + 1) * w
			var new_height := v[b0 + a0] * (1.0 - nu) * (1.0 - nt) + v[b0 + a1] * nu * (1.0 - nt) + v[b1 + a0] * (1.0 - nu) * nt + v[b1 + a1] * nu * nt
			var delta := new_height - here
			var cap := maxf(-delta * speed * water * capacity, min_capacity)
			if sediment > cap or delta > 0.0:
				# Uphill: fill the pit behind it (at most to its level); else drop the excess.
				var amount := minf(delta, sediment) if delta > 0.0 else (sediment - cap) * deposition
				sediment -= amount
				v[y0 + x0] += amount * (1.0 - u) * (1.0 - t)
				v[y0 + x1] += amount * u * (1.0 - t)
				v[y1 + x0] += amount * (1.0 - u) * t
				v[y1 + x1] += amount * u * t
			else:
				# Take sediment from around it (never more than the drop to the next step).
				var amount := minf((cap - sediment) * erosion, -delta)
				var total := 0.0
				for k in nb:
					var bx := ix + bdx[k]
					var by := iy + bdy[k]
					if wrap or (bx >= 0 and by >= 0 and bx < w and by < h):
						total += bw[k]
				for k in nb:
					var bx := ix + bdx[k]
					var by := iy + bdy[k]
					if wrap:
						bx = posmod(bx, w)
						by = posmod(by, h)
					elif bx < 0 or by < 0 or bx >= w or by >= h:
						continue
					var take := amount * bw[k] / total
					v[by * w + bx] -= take
					sediment += take
			# Faster going down, slower going up.
			speed = sqrt(maxf(0.0, speed * speed - delta * gravity))
			water *= 1.0 - evaporation
			x = fmod(nx + w, float(w)) if wrap else nx
			y = fmod(ny + h, float(h)) if wrap else ny
		# A droplet that stops (stalls or runs out of steps) leaves its sediment where it is.
		if not left and sediment > 0.0:
			var ix := floori(x)
			var iy := floori(y)
			var u := x - ix
			var t := y - iy
			var x0 := posmod(ix, w) if wrap else ix
			var x1 := posmod(ix + 1, w) if wrap else ix + 1
			var y0 := (posmod(iy, h) if wrap else iy) * w
			var y1 := (posmod(iy + 1, h) if wrap else iy + 1) * w
			v[y0 + x0] += sediment * (1.0 - u) * (1.0 - t)
			v[y0 + x1] += sediment * u * (1.0 - t)
			v[y1 + x0] += sediment * (1.0 - u) * t
			v[y1 + x1] += sediment * u * t


static func _thermal(v: PackedFloat64Array, w: int, h: int, wrap: bool, p: Dictionary) -> void:
	var iterations := int(p.get("thermal_iterations", 0))
	if iterations <= 0:
		return
	var talus := tan(deg_to_rad(clampf(float(p.get("talus_deg", 35.0)), 0.0, 89.0)))
	var rate := clampf(float(p.get("thermal_rate", 0.5)), 0.0, 1.0)
	var ndx := [1, -1, 0, 0, 1, -1, 1, -1]
	var ndy := [0, 0, 1, -1, 1, 1, -1, -1]
	var delta := PackedFloat64Array()
	delta.resize(v.size())
	var excess := PackedFloat64Array()
	excess.resize(8)
	for it in iterations:
		delta.fill(0.0)
		for y in h:
			for x in w:
				var hc := v[y * w + x]
				var total := 0.0
				var most := 0.0
				for k in 8:
					excess[k] = 0.0
					var nx: int = x + ndx[k]
					var ny: int = y + ndy[k]
					if wrap:
						nx = posmod(nx, w)
						ny = posmod(ny, h)
					elif nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var e := hc - v[ny * w + nx] - talus * (1.0 if k < 4 else 1.41421356237309505)
					if e > 0.0:
						excess[k] = e
						total += e
						most = maxf(most, e)
				if total <= 0.0:
					continue
				# Half the steepest excess (so the two cells end level at most), shared by excess.
				var move := rate * most * 0.5
				for k in 8:
					if excess[k] > 0.0:
						var share := move * excess[k] / total
						var nx: int = posmod(x + ndx[k], w)
						var ny: int = posmod(y + ndy[k], h)
						delta[ny * w + nx] += share
						delta[y * w + x] -= share
		for i in v.size():
			v[i] += delta[i]
