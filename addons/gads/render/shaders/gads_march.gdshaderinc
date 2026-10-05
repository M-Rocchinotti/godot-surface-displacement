// The relief march shared by the surface materials and the GADSDisplacementField3D shader.
// Before including, define GADS_RELIEF(coord, lod, arg): the relief height in metres at a 2D
// coordinate (uv for surfaces, world XZ for the field) on mip level lod. `arg` is passed through
// unchanged: the amplitude for surfaces, the layer weights for the field; its type is
// GADS_RELIEF_ARG (float unless defined otherwise).

#ifndef GADS_MARCH_INCLUDED
#define GADS_MARCH_INCLUDED

#ifndef GADS_RELIEF_ARG
#define GADS_RELIEF_ARG float
#endif

// Walks the view ray from z_top down to z_bot in `steps` equal steps, brackets the first crossing
// below the relief, refines the bracket by `refine` bisection steps and places the hit by a final
// secant (linear interpolation of the ray-minus-relief function). Returns the hit height z and
// writes its uv. When the ray reaches z_bot without crossing (only possible for z_bot above the
// lowest relief) it returns z_bot.
float gads_march(vec2 uv0, vec2 duv_dz, float z_top, float z_bot, GADS_RELIEF_ARG amp, float lod, int steps, int refine,
		out vec2 uv_hit, inout float steps_used) {
	float dz = (z_top - z_bot) / float(steps);
	float z_above = z_top;
	float f_above = z_top - GADS_RELIEF(uv0 + duv_dz * z_top, lod, amp);
	float z_below = z_bot;
	float f_below = 0.0;
	bool hit = f_above <= 0.0;
	if (hit) {
		z_below = z_top;
		f_below = f_above;
	}
	for (int i = 1; i <= GADS_MAX_STEPS; i++) {
		if (hit || i > steps) {
			break;
		}
		float z = z_top - dz * float(i);
		float f = z - GADS_RELIEF(uv0 + duv_dz * z, lod, amp);
		steps_used += 1.0;
		if (f <= 0.0) {
			hit = true;
			z_below = z;
			f_below = f;
		} else {
			z_above = z;
			f_above = f;
		}
	}
	if (!hit) {
		uv_hit = uv0 + duv_dz * z_bot;
		return z_bot;
	}
	for (int j = 0; j < GADS_MAX_REFINE; j++) {
		if (j >= refine) {
			break;
		}
		float zm = 0.5 * (z_above + z_below);
		float fm = zm - GADS_RELIEF(uv0 + duv_dz * zm, lod, amp);
		steps_used += 1.0;
		if (fm <= 0.0) {
			z_below = zm;
			f_below = fm;
		} else {
			z_above = zm;
			f_above = fm;
		}
	}
	float denom = f_above - f_below;
	float z_hit = denom > 1e-9 ? z_above - f_above * (z_above - z_below) / denom : z_below;
	uv_hit = uv0 + duv_dz * z_hit;
	return z_hit;
}

#endif // GADS_MARCH_INCLUDED
