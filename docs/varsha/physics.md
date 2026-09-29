# Varsha water physics

Water on and around app windows is one particle fluid, solved on the GPU with Position Based Fluids.
No code handles beads, spills, drips, trails or splashes as cases.
Those behaviours are outcomes of the solver, the boundaries and the material constants below.

Code: `Varsha/Fluid.metal` (kernels and rendering), `Varsha/WindowWater.swift` (buffers, spawning, frame loop).
Checks: `tests/RainChecks.swift`, run by `make varsha-test`.

## Solver

Each frame runs 8 substeps. Each substep:

1. `predict`: integrate gravity and the forces from the previous substep.
2. `insert`: hash every particle into a grid of cell size h.
3. Three iterations of `solveLambda`, `solveDelta`, `applyDelta`.
4. `finish`: contact with glass, velocity update, evaporation.
5. `forces`: viscosity, adhesion, air drag for the next substep.

`solveLambda` is the PBF density constraint (Macklin and Mueller 2013), compression only, with relaxation 0.05.
`solveDelta` adds cohesion as a pair constraint (Macklin et al. 2014).
Each density correction is capped at h/4 per iteration so that fast impacts cannot launch particles.

## Planes

Every particle belongs to one window and one plane.

- Edge plane (`SIDE`): the side view. The window is a solid rounded rectangle. Rain that hits the top edge enters here.
- Glass face (`FACE`): the view through the pane. Rain that crosses the glass enters here.
- `DETACHED`: face water that left the pane. It falls freely.

Particles interact only with particles of the same window and plane.
Water of a window is hidden behind every window in front of it, per pixel, in `splatFragment`.

## Forces and constraints

| Term | Law | Source |
|---|---|---|
| Incompressibility | PBF density constraint | Macklin and Mueller 2013 |
| Cohesion (surface tension) | Pair constraint toward `bondRest` for neighbours between `bondRest` and h | Macklin et al. 2014 |
| Adhesion to the edge | Akinci adhesion kernel on distance to the window solid | Akinci et al. 2013 |
| Viscosity | XSPH | Schechter and Bridson 2012 |
| Air drag | Linear toward wind velocity, weighted by exposure | |
| Contact-line pinning | Tangential slip held up to `pin * exposure * surface energy`, then viscous damping | Contact-angle hysteresis (Furmidge) |

Exposure is the offset of a particle's neighbourhood centroid.
It is near 0 in the bulk and near 1 at a free surface.
On the edge, the solid is filled with fixed ghost lattice points for exposure only.
So only the water-air boundary and the contact line count as exposed.

Because pinning scales with exposed particles (perimeter) and gravity with all particles (area), small drops stay and large drops slide.
Surface energy is smooth value noise plus sparse strong defects.
Defects snag the back of a sliding drop, which leaves droplets behind it as a trail.

## Constants

Units are points and seconds. Particles have unit mass.

| Constant | Value | Reason |
|---|---|---|
| spacing, h | 0.8, 1.6 | 20 to 200 particles per visible drop |
| gravity | 1800 | With this cohesion, caps are about 3:1 wide to tall, like water on clean glass |
| bond, bondRest | 0.6, 1.8 spacing | A rest distance at the lattice spacing fights the second lattice ring and makes resting water jitter at 20 to 30 pt/s |
| adhesion | 6000 | Higher values spread drops into a single layer |
| pin | 4000 | Face drops below radius about 3.5 pt stay; larger ones slide |
| substrateDrag | 15 | Sliding drops move at 10 to 50 pt/s |
| evaporation | 0.02 per s per exposed particle | Faster than real drying in rain, chosen for the frame budget |

## Rejected approaches

- Akinci explicit cohesion above 20k: particles collapse and then explode.
- Tension through the density constraint (negative pressure): drops land as a layer one particle thick.
- Position-based curvature reduction: not derived from an energy. Free drops explode at any strength tried; it looked stable on the face only because glass drag damped it.
- Depth-scaled Coulomb friction on the edge: resting water carries almost no normal load, so it glides.

## Performance

Measured on the development Mac (Mac16,7), two large windows, heavy rain:

| Time | Particles | GPU per frame | Asleep |
|---|---|---|---|
| 10 s | 21k | 2.0 ms | 26% |
| 60 s | 63k | 4.9 ms | 42% |
| 120 s | 77k | 5.6 ms | 50% |

Edge water levels off near 36k, where corner runoff matches the rain. Face water still grows by about 2k per 10 s at 120 s.

Three measures keep this cost down:

- Sleeping (deactivation): water still for 0.5 s is skipped until moving water or its window disturbs it.
- A cell sort every 30 frames keeps neighbour reads close in memory. It gave a 2.2× speedup.
- The frame step never blocks the main thread. It skips a frame if the GPU is still busy.

The particle limit is 131,072. Past it, new rain does not enter the fluid.

## Known limits

- A single raindrop is 5 to 19 particles. It lands as a thin layer and becomes a bead only after it merges with others.
- In the edge plane, water cannot spill over the front or back of the edge; it leaves only at the corners.
- In a 20 s heavy-rain scene, few face drops grow large enough to slide. Sliding comes after minutes of merging.
