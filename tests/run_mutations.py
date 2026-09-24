#!/usr/bin/env python
"""Mutation checks: prove that the tests catch the bugs they are meant to catch.

Each mutation re-introduces one known bug (or removes one safeguard), runs the tests that should
catch it and expects them to FAIL. The files are restored afterwards, also when the run is
interrupted; mutations of an .import file re-import before and after. Render suites run headed.

    python tests/run_mutations.py              # all mutations
    python tests/run_mutations.py sign seam    # only mutations whose name contains a word

Exit code 0 = every mutation was caught, 1 = a mutation survived (or no longer applies).
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "tools" / "godot.py"
SH = "addons/surface_displacement/shaders/"
CORE = SH + "sd_core.gdshaderinc"
COMMON = SH + "sd_common.gdshaderinc"
MARCH = SH + "sd_march.gdshaderinc"
SURFACE = SH + "sd_surface.gdshaderinc"
FIELD_SH = SH + "sd_field.gdshaderinc"
GROUND = SH + "sd_ground.gdshaderinc"
PEBBLES = SH + "sd_pebble_process.gdshader"
FIELD = "addons/surface_displacement/nodes/displacement_field_3d.gd"
MANAGER = "addons/surface_displacement/nodes/surface_displacement.gd"
BAKE = "addons/surface_displacement/core/sd_ground_bake.gd"
MATERIALS = "addons/surface_displacement/core/sd_materials.gd"
SCATTER = "addons/surface_displacement/nodes/pebble_scatter_3d.gd"
CONVERTER = "addons/surface_displacement/tools/material_converter.gd"
HEIGHT_IMPORT = "demo/textures/clean_pebbles/clean_pebbles_height.exr.import"

# (name, what it breaks, [(file, old, new)], [(suite, name filter)]); suite is "logic",
# "render" (tests/render_tests.gd) or "field" (tests/field_tests.gd).
MUTATIONS = [
    ("no mipmaps", "the demo height map imported without mipmaps (a common POM bug: the full-size map is sampled at every distance)",
     [(HEIGHT_IMPORT, "mipmaps/generate=true", "mipmaps/generate=false")],
     [("logic", ""), ("render", "shimmer")]),
    ("march reads mip 0", "the march samples the full-size height map at every distance",
     [(CORE, "	return max(0.5 * log2(max(rho2, 1e-12)) + sd_pom_range.z, 0.0);", "	return 0.0 * rho2;")],
     [("render", "shimmer")]),
    ("wrong parallax sign", "the view ray walks the relief the wrong way (relief that swims against the view)",
     [(CORE, "	return vec2(dot(p.gu, v), dot(p.gv, v)) * (dot(n, p.axis) / nv);", "	return -vec2(dot(p.gu, v), dot(p.gv, v)) * (dot(n, p.axis) / nv);")],
     [("render", "pom_matches,swim")]),
    ("no binary refinement", "the linear search is followed by the secant step only",
     [(MARCH, "		if (j >= refine) {", "		if (j >= 0) {")],
     [("render", "pom_matches")]),
    ("world rotation sign", "world-planar u gradient rotated the wrong way",
     [(CORE, "	p.gu = vec3(c, 0.0, -s) / texture_size_m.x;", "	p.gu = vec3(c, 0.0, s) / texture_size_m.x;")],
     [("render", "pom_matches")]),
    ("triplanar X plane mirrored", "the X plane's u axis points the other way",
     [(CORE, "		right = vec3(0.0, 0.0, -sg);", "		right = vec3(0.0, 0.0, sg);")],
     [("render", "pom_matches")]),
    ("zero-weight planes marched", "triplanar marches all three planes, also those with no weight",
     [(SURFACE, "		if (wa <= 0.0) {\n			continue; // Zero-weight planes are neither marched nor sampled.", "		if (false) {\n			continue; // Zero-weight planes are neither marched nor sampled.")],
     [("render", "triplanar")]),
    ("no distance fade", "the relief keeps its full depth at every distance",
     [(SURFACE, "	float amp = height_m * fade;", "	float amp = height_m + 0.0 * fade;")],
     [("render", "fade")]),
    ("LIGHT_VERTEX not written", "lighting and received shadows use the flat surface, not the relief",
     [(SURFACE, "	LIGHT_VERTEX = VERTEX + offset_view;", "	LIGHT_VERTEX = VERTEX + 0.0 * offset_view;")],
     [("render", "light_vertex")]),
    ("self-shadow ray reversed", "the self-shadow march walks away from the light",
     [(CORE, "	vec2 duv_dz = vec2(dot(sd_ss_gu, l), dot(sd_ss_gv, l)) * (na / max(n_dot_l, SD_MIN_NDOTV));",
       "	vec2 duv_dz = -vec2(dot(sd_ss_gu, l), dot(sd_ss_gv, l)) * (na / max(n_dot_l, SD_MIN_NDOTV));")],
     [("render", "self_shadow")]),
    ("light(): Lambert diffuse", "light() uses Lambert while the engine shades with Burley",
     [(COMMON, "		float diffuse_brdf_nl = (1.0 / SD_PI) * fd_v * fd_l * c_n_dot_l;", "		float diffuse_brdf_nl = (1.0 / SD_PI) * c_n_dot_l + 0.0 * fd_v * fd_l;")],
     [("render", "light_function")]),
    ("light(): clamped GGX", "D clamped to 1 (the engine's saturateHalf is not a clamp)",
     [(COMMON, "	return k * k * (1.0 / SD_PI);", "	return clamp(k * k * (1.0 / SD_PI), 0.0, 1.0);")],
     [("render", "light_function")]),
    ("light(): no energy compensation", "direct specular without the engine's multiple-scattering term",
     [(COMMON, "		vec3 energy_compensation = 1.0 + f0 * (1.0 / max(e, 1e-4) - 1.0);", "		vec3 energy_compensation = vec3(1.0) + 0.0 * e;")],
     [("render", "light_function")]),
    ("depth-write leak", "every POM variant writes DEPTH, not only the opt-in ones",
     [(SURFACE, "#ifdef SD_DEPTH_WRITE\n	// With the depth pre-pass on,", "#ifdef SD_POM\n	// With the depth pre-pass on,")],
     [("render", "depth")]),
    ("depth not rounded", "the opt-in depth write without the rounding that keeps both passes equal",
     [(SURFACE, "	DEPTH = round(depth / depth_step) * depth_step;", "	DEPTH = depth + 0.0 * depth_step;")],
     [("render", "depth")]),
    ("no LOD seam stitch", "rings do not geomorph towards the next ring (open T-junctions at ring seams)",
     [(FIELD_SH, "	vec2 lattice_m = lattice - odd * spacing_units * m;", "	vec2 lattice_m = lattice - odd * spacing_units * m * 0.0;")],
     [("field", "cracks,swim")]),
    ("no grid snapping", "the grid follows the camera continuously (vertices slide over the height map)",
     [(FIELD, "	return Vector3(floorf(p.x / snap + 0.5) * snap, 0.0, floorf(p.z / snap + 0.5) * snap)", "	return Vector3(p.x, 0.0, p.z) + 0.0 * snap * Vector3.ONE")],
     [("field", "vertex,swim")]),
    ("vertex fetch at mip 0", "the geometry samples the full-size height map (aliasing, sparkle)",
     [(FIELD_SH, "	float lod = log2(base_spacing) + (level + m);", "	float lod = -20.0 + 0.0 * (log2(base_spacing) + level + m);")],
     [("field", "vertex")]),
    ("relief pushed down", "the field displaces downwards (the ground would hide it)",
     [(FIELD_SH, "	float y = ground + lift + sd_field_fade(xz) * sd_fade(view_distance) * sd_field_relief(xz, lod, w_relief);",
       "	float y = ground + lift - sd_field_fade(xz) * sd_fade(view_distance) * sd_field_relief(xz, lod, w_relief);")],
     [("field", "vertex")]),
    ("pebbles hashed by window slot", "each pebble's random position, size and turn seeded by its slot in the camera window, not its world cell",
     [(PEBBLES, "	uint state = sd_hash(uint(world_cell.x) * 73856093u ^ uint(world_cell.y) * 19349663u",
       "	uint state = sd_hash(uint(cell_xy.x) * 73856093u ^ uint(cell_xy.y) * 19349663u")],
     [("field", "pebbles")]),
    ("bake ignores layers", "every ground surface is captured as 'not displaceable'",
     [(BAKE, "			copy.set_surface_override_material(s, materials[layer_index(surface_material(mi, s), layers) + 1])",
       "			copy.set_surface_override_material(s, materials[0 * layer_index(surface_material(mi, s), layers)])")],
     [("field", "bake")]),
    ("inverted remap flattens", "height_remap (1, 0) clamps its negative span to 1e-5 (every height becomes 0)",
     [(COMMON, "	span = abs(span) < 1e-5 ? 1e-5 : span;", "	span = max(span, 1e-5);")],
     [("render", "inverted_height_remap")]),
    ("field parallax sign", "the field's fragments march the view ray the wrong way",
     [(FIELD_SH, "		vec2 dxz_dz = v.xz * (n.y / nv);", "		vec2 dxz_dz = -v.xz * (n.y / nv);")],
     [("field", "field_pom")]),
    ("field self-shadow reversed", "the field's self-shadow march walks away from the light",
     [(FIELD_SH, "	vec2 dxz_dz = vec2(dot(f_ss_x, l), dot(f_ss_z_axis, l)) * (na / max(n_dot_l, SD_MIN_NDOTV));",
       "	vec2 dxz_dz = -vec2(dot(f_ss_x, l), dot(f_ss_z_axis, l)) * (na / max(n_dot_l, SD_MIN_NDOTV));")],
     [("field", "field_pom")]),
    ("ground steps not marked (shader)", "the field treats kerbs as ground (drapes a ramp over them)",
     [(GROUND, "	float limit = ground_decode.z;", "	float limit = 1e9 + 0.0 * ground_decode.z;")],
     [("field", "baked_ground")]),
    ("ground steps not marked (CPU)", "SDGroundBake.sample() treats kerbs as ground",
     [(BAKE, "			ok = ok and covered[n] and absf(h[n] - h[c]) <= step_limit", "			ok = ok and covered[n]")],
     [("logic", "")]),
    ("ground beyond the bake displaced", "texels outside the bake count as covered (the field continues past the ground's edge)",
     [(GROUND, "		covered[k] = p == pc && d.a > 0.5;", "		covered[k] = d.a > 0.5;")],
     [("field", "baked_ground")]),
    ("field relief lifted", "the field marches its relief from ground + lift, not from the ground (a 2 mm shift against the ground's parallax)",
     [(FIELD_SH, "	float z_hit = wpos.y - f_ground;", "	float z_hit = wpos.y - (f_ground + lift);")],
     [("field", "edge_blends")]),
    ("hard mip cut", "the relief ends at the mip limit instead of fading out over the last level (an edge that moves with the camera)",
     [(COMMON, "	return 1.0 - smoothstep(sd_pom_range.w - 1.0, sd_pom_range.w, lod);", "	return lod < sd_pom_range.w ? 1.0 : 0.0;")],
     [("render", "mip_level")]),
    ("field fragments ignore the mip fade", "the field marches the full relief where the ground's parallax has faded out by mip level",
     [(FIELD_SH, "	vec4 w_relief = w * mip_fades * pom_fade;", "	vec4 w_relief = w * pom_fade + 0.0 * mip_fades;")],
     [("field", "edge_blends")]),
    ("field vertices ignore the mip fade", "the field's geometry keeps its relief where the parallax has faded out by mip level",
     [(FIELD_SH, "	vec4 w_relief = w * sd_field_mip_fades(log2(max(footprint, 1e-6)) + sd_pom_range.z);", "	vec4 w_relief = w + 0.0 * footprint;")],
     [("field", "vertex_heights")]),
    ("field hit on the lifted proxy", "where no relief is left to march, the field shades the proxy point (2 mm up) instead of the ground the view ray meets",
     [(FIELD_SH, "			z_hit = 0.0;\n			xz_hit = base_xz;", "			xz_hit = wpos.xz;")],
     [("field", "edge_blends")]),
    ("debug views lit (surface)", "the self-shadowing variants' light() adds the specular highlight to the debug views' read-back",
     [(SURFACE, "	if (debug_view == 0) {\n		sd_brdf(", "	if (!shadow_view) {\n		sd_brdf(")],
     [("field", "debug_views")]),
    ("debug views lit (field)", "the field's light() adds the specular highlight to the debug views' read-back",
     [(FIELD_SH, "	if (debug_view == 0) {\n		sd_brdf(", "	if (!shadow_view) {\n		sd_brdf(")],
     [("field", "debug_views")]),
    ("depth-write switch ignored", "opted-in materials keep the depth write at Low and with the DEPTH_WRITE switch off",
     [(MATERIALS, "	var shader := get_shader(info[\"mapping\"], quality, opted_in and allow_depth_write)",
       "	var shader := get_shader(info[\"mapping\"], quality, opted_in and (allow_depth_write or true))")],
     [("logic", "")]),
    ("depth-write switch forgets the opt-in", "switching the depth write off loses the material's opt-in, so it never comes back",
     [(MATERIALS, "	if opted_in:\n		material.set_meta(&\"sd_depth_write\", true)", "	if false:\n		material.set_meta(&\"sd_depth_write\", true)")],
     [("logic", "")]),
    ("bake size unguarded", "the ground bake uses the asked texel whatever the ground's size (a 1 km ground: 400 million texels, Image.create fails)",
     [(BAKE, "	var fitted := fit_texel(size_m, texel)", "	var fitted := texel + 0.0 * fit_texel(size_m, texel)")],
     [("field", "huge_ground")]),
    ("bake side unguarded", "fit_texel() caps the texel count but not the side (a 2 km strip: a 40000-texel texture)",
     [(BAKE, "	t = maxf(t, maxf(size_m.x, size_m.y) / MAX_SIDE)", "	t = maxf(t, 0.0 * maxf(size_m.x, size_m.y) / MAX_SIDE)"),
      (BAKE, " or maxi(ceili(size_m.x / t), ceili(size_m.y / t)) > MAX_SIDE:", ":")],
     [("logic", "")]),
    ("field bakes while hidden", "the field bakes its ground at startup although the preset hides it (Medium)",
     [(FIELD, "		_start_pending_bake.call_deferred()", "		bake_ground.call_deferred()")],
     [("field", "demo_scenes")]),
    ("pebbles never re-copy", "the pebble scatter copies the field's parameters once and misses later layer changes",
     [(SCATTER, "	if field.get_params_version() != _copied_version:", "	if _copied_version == -1 and field.get_params_version() >= 0:")],
     [("field", "pebbles")]),
    ("converter: first reason only", "a skipped material reports only the first thing that blocks its conversion",
     [(CONVERTER, '	return "; ".join(skip_reasons(m))', '	return skip_reasons(m)[0] if not skip_reasons(m).is_empty() else ""')],
     [("logic", "")]),
    ("converter: silent losses", "a conversion drops rim, clearcoat, cull mode ... without saying so",
     [(CONVERTER, "				if not lost.is_empty():", "				if false and not lost.is_empty():")],
     [("logic", "")]),
    ("feature switch adds features", "a feature switch turns on what the preset leaves out",
     [(MANAGER, "	base.near_field_enabled = base.near_field_enabled and near_field", "	base.near_field_enabled = near_field")],
     [("logic", "")]),
]

SUITES = {
    "logic": (["--headless", "--script", "tests/run_logic_tests.gd"], r"logic tests: \d+ passed, \d+ failed"),
    "render": (["--script", "tests/render_tests.gd"], r"render tests: \d+ passed, \d+ failed"),
    "field": (["--script", "tests/field_tests.gd"], r"field tests: \d+ passed, \d+ failed"),
}


def godot(args: list[str], timeout: int = 1800) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(RUNNER), "--timeout", str(timeout)] + args,
                          cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")


def reimport() -> None:
    godot(["--headless", "--import"], 900)


def run_tests(targets: list[tuple[str, str]]) -> tuple[bool, list[str]]:
    """True when at least one targeted test failed; also the FAIL lines and measurements."""
    caught = False
    lines = []
    for suite, only in targets:
        args, summary = SUITES[suite]
        proc = godot(args + (["--", "--only=" + only] if only else []))
        out = proc.stdout + proc.stderr
        fails = [line.strip() for line in out.splitlines() if line.strip().startswith("FAIL")]
        measured = [line.rstrip() for line in out.splitlines() if line.startswith("  ") and not line.strip().startswith(("ok", "FAIL", "at:", "GDScript", "["))]
        m = re.search(summary, out)
        lines.append(f"{suite} '{only}': {m.group(0) if m else 'no summary (exit %d)' % proc.returncode}")
        lines += ["|" + line for line in measured[:12]] + fails
        caught = caught or (proc.returncode != 0 and bool(fails))
    return caught, lines


def main() -> int:
    words = sys.argv[1:]
    selected = [m for m in MUTATIONS if not words or any(w in m[0] for w in words)]
    survived = []
    for name, description, edits, targets in selected:
        originals: dict[str, str] = {}
        imports = any(path.endswith(".import") for path, _, _ in edits)
        try:
            for path, old, new in edits:
                file = ROOT / path
                current = file.read_text(encoding="utf-8")
                originals.setdefault(path, current)
                if old not in current:
                    raise LookupError(f"pattern not found in {path}: {old!r}")
                file.write_text(current.replace(old, new, 1), encoding="utf-8", newline="\n")
            if imports:
                reimport()
            caught, lines = run_tests(targets)
            print(f"{'CAUGHT  ' if caught else 'SURVIVED'} {name}: {description}", flush=True)
            for line in lines:
                print(f"         {line}", flush=True)
            if not caught:
                survived.append(name)
        except LookupError as error:
            # The code the mutation targets changed: the mutation must be updated, not skipped.
            print(f"STALE    {name}: {error}", flush=True)
            survived.append(name)
        finally:
            for path, text in originals.items():
                (ROOT / path).write_text(text, encoding="utf-8", newline="\n")
            if imports:
                reimport()
    print(f"\n{len(selected) - len(survived)}/{len(selected)} mutations caught")
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
