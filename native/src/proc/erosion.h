// Erosion of height fields (engine-independent): hydraulic (water droplets that pick sediment up
// where they speed up and drop it where they slow down, carving gullies and filling valleys) and
// thermal (material slides down slopes steeper than a talus angle, softening cliffs into scree).
//
// Heights are `w` x `h` floats, row-major, in any unit: `height_m` metres per unit and `cell_m`
// metres between texels make the slopes physical, so the same parameters erode a 40 m hill and a
// 4 m one alike. Deterministic: the same field and parameters give the same result on any
// machine (own random generator, single thread).
#pragma once

#include <vector>

namespace gads {

struct ErosionParams {
	// Hydraulic.
	int droplets = 0; // droplets to simulate (0: none)
	int seed = 1;
	int max_steps = 64; // a droplet's lifetime (texel steps)
	double inertia = 0.05; // 0: follows the slope at once, 1: keeps its direction
	double capacity = 0.3; // sediment it can carry per unit of speed, water and drop (in texels)
	double min_capacity = 0.01;
	double erosion = 0.3; // fraction of the free capacity it takes per step
	double deposition = 0.3; // fraction of the excess sediment it drops per step
	double evaporation = 0.02; // water lost per step
	double gravity = 4.0;
	int radius = 3; // the erosion brush (texels)
	// Thermal.
	int thermal_iterations = 0;
	double talus_deg = 35.0; // slopes steeper than this slide
	double thermal_rate = 0.5; // fraction of the excess moved per iteration (0..1)
	// Scale.
	double cell_m = 1.0;
	double height_m = 1.0;
	bool wrap = false; // a tileable field (neighbours wrap around)
};

// Erodes `field` in place: hydraulic first, then thermal.
void erode(std::vector<float> &field, int w, int h, const ErosionParams &p);

} // namespace gads
