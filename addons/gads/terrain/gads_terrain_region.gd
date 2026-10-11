@tool
class_name GADSTerrainRegion
extends Resource
## One region's persisted slice of a [GADSTerrain3D]'s editable maps (Stage 3b).
##
## A large world is saved as one of these resources per region (see [method GADSTerrain3D.save_regions]),
## so a 16k terrain lives as a set of per-region files on disk rather than one giant texture. Each
## file holds this region's tile of each editable map that exists (height, splat, holes) plus enough
## header to put the tile back in its place and to reconstruct the terrain's grid:
## [member GADSTerrain3D.load_regions] reads the set, reassembles the whole maps and rebuilds.
##
## The tiles are stored as the terrain's own flat arrays (the region store's slices), not as images:
## a height tile is one float per vertex (0..1 over the terrain's height scale, the heightmap's red
## channel), a splat tile four floats a texel (RGBA), a holes tile one byte a vertex (non-zero = a
## hole). That is exactly what [method GADSTerrain3D._region_slice] returns and what
## [method GADSTerrain3D._region_coalesce] reassembles, so a terrain loaded from region files is
## byte-identical to the same terrain imported from a whole heightmap / splat.
##
## The header is the WHOLE (coalesced) map's dimensions per map ([member height_dims] etc.) and the
## terrain's grid (size, spacing, chunk quads, region size and the region-grid dimensions). The
## whole-map dimensions are what the split used, so coalescing reproduces the map; the grid header
## lets a terrain reconstruct its geometry from the files alone.

## This region's integer coordinate in the terrain's sparse region grid (not assumed to start at the
## origin, so a world laid out far from it addresses the same way).
@export var coord := Vector2i.ZERO
## The terrain's region grid (columns, rows) at save: how many regions the maps were split into.
## The last region on each axis may be partial; with (1, 1) the whole terrain is a single region.
@export var region_grid := Vector2i.ONE
## The terrain's [member GADSTerrain3D.region_size] (m) at save.
@export var region_size := 1024.0
## The terrain's [member GADSTerrain3D.size] (m) at save (after rounding to whole chunks).
@export var terrain_size := Vector2.ZERO
## The terrain's resolved vertex spacing (m) at save ([method GADSTerrain3D.get_vertex_spacing], not
## the requested value): restoring it as the terrain's vertex spacing reproduces the same grid, since
## it already divides the size into a whole number of chunks.
@export var vertex_spacing := 1.0
## The terrain's [member GADSTerrain3D.chunk_quads] at save (the region size is a whole number of
## chunks, so this is needed to reproduce the split).
@export var chunk_quads := 64
## The WHOLE height map's dimensions (width, height, channels) -- the heightmap's resolution, not the
## grid's -- or [constant Vector3i.ZERO] if the terrain has no height map. The channel count is the
## values a texel ([member height_tile] has one: the red channel).
@export var height_dims := Vector3i.ZERO
## The WHOLE splat map's dimensions (width, height, channels = 4), or zero if there is no splat map.
@export var splat_dims := Vector3i.ZERO
## The WHOLE hole map's dimensions (width, height, channels = 1 = one vertex), or zero if none.
@export var holes_dims := Vector3i.ZERO
## This region's height texels (row-major over the region's rectangle, one float a texel), empty if
## [member height_dims] is zero.
@export var height_tile := PackedFloat32Array()
## This region's splat texels (row-major, four floats a texel: RGBA), empty if no splat map.
@export var splat_tile := PackedFloat32Array()
## This region's hole flags (row-major, one byte a vertex: non-zero = a hole), empty if no hole map.
@export var holes_tile := PackedByteArray()
