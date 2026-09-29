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
  Each screen also has a glass face (id `-1000 - index`, rank -1). It sits in front of every window.
  Inward rain (see Rain sources) that lands over the desktop enters there.
- `DETACHED`: face water that left the pane. It falls freely.

Particles interact only with particles of the same window and plane.
Water of a window is hidden behind every window in front of it, per pixel, in `splatFragment`.

## Rain sources

- Falling streaks: 35% of background streaks are aimed at a window (`RainEngine.aimedShare`). They strike its outline and splash there.
  An aimed streak starts on the straight path to a point on the outline. The top gets a share in proportion to its width,
  and the windward side in proportion to its height times the slant of the fall, which is the rain flux on each face.
  Wind reaches 600 pt/s, which slants the fastest streaks to about 25° and the slowest to about 30°.
  `WindowWater.edgeHit` finds the first entry point on any side, so wind-driven rain also meets the sides.
  Falling streaks never land on glass mid-fall; a drop that appeared there looked as if it came from nowhere.
- Inward rain (`InwardDrop`): drops moving toward the viewer, radius 2.4 to 7.2 pt, 35 per second per megapixel at full intensity. It is the only source of water on glass. The radius is 1.6× the first value (1.5 to 4.5 pt) so drops are large enough to refract; the rate is divided by 1.6², so water per second is unchanged.
  Each lands on the frontmost glass under its impact point: an app window's face, otherwise the screen glass.
- Downpour draws 1540 streaks per megapixel (medium intensity draws about 600).

Streaks have a dark offset under-stroke so they stay visible on light backgrounds.

## Forces and constraints

| Term | Law | Source |
|---|---|---|
| Incompressibility | PBF density constraint | Macklin and Mueller 2013 |
| Cohesion (surface tension) | Pair constraint toward `bondRest` for neighbours between `bondRest` and h | Macklin et al. 2014 |
| Adhesion to the edge | Akinci adhesion kernel on distance to the window solid | Akinci et al. 2013 |
| Viscosity | XSPH | Schechter and Bridson 2012 |
| Air drag | Linear toward wind velocity, weighted by exposure | |
| Contact-line pinning | Tangential slip held up to `pin * exposure * surface energy`, then viscous damping | Contact-angle hysteresis (Furmidge) |

Spray droplets of one to three particles render at a lowered field threshold, so impacts on edges show their splash.

Exposure is the offset of a particle's neighbourhood centroid.
It is near 0 in the bulk and near 1 at a free surface.
On the edge, the solid is filled with fixed ghost lattice points for exposure only.
So only the water-air boundary and the contact line count as exposed.

Because pinning scales with exposed particles (perimeter) and gravity with all particles (area), small drops stay and large drops slide.
Surface energy is smooth value noise plus sparse strong defects (weight 4). At weight 1.5 sliding drops left no trail.
Defects snag the back of a sliding drop, which leaves droplets behind it as a trail.

## Constants

Units are points and seconds. Particles have unit mass.

| Constant | Value | Reason |
|---|---|---|
| spacing, h | 0.8, 1.6 | 20 to 200 particles per visible drop |
| gravity | 1800 | With this cohesion, caps are about 3:1 wide to tall, like water on clean glass |
| bond, bondRest | 0.6, 1.8 spacing | A rest distance at the lattice spacing fights the second lattice ring and makes resting water jitter at 20 to 30 pt/s |
| adhesion | 6000 | Higher values spread drops into a single layer |
| pin | 2500 | Glass pane. Raindrop-sized drops stay; drops from radius about 2 pt slide |
| substrateDrag | 8 | Glass pane. Low friction, so merged drops trickle |
| edgePin, edgeDrag | 4000, 15 | Window frame edge, a different material. With pane values, water wicks along the top instead of running off the corner |
| evaporation | 0.03 per s per exposed particle | Faster than real drying in rain, chosen for the frame budget |

## Rejected approaches

- Akinci explicit cohesion above 20k: particles collapse and then explode.
- Tension through the density constraint (negative pressure): drops land as a layer one particle thick.
- Position-based curvature reduction: not derived from an energy. Free drops explode at any strength tried; it looked stable on the face only because glass drag damped it.
- Depth-scaled Coulomb friction on the edge: resting water carries almost no normal load, so it glides.

## Particle budget

Each visible drop is 20 to 200 particles, so realistic coverage of glass in a downpour would need over a million.
The limit is 98,304 particles. Above 60% occupancy, sleeping (still) water dries faster, up to 31× at the limit.
Moving water keeps the base rate. So arriving rain always enters the fluid, and trickles keep their water.

## Performance

Measured on the development Mac (Mac16,7): two large windows plus the screen glass, 120 s of rain.
Measured before the move of all glass water to inward rain; not measured since:

| Intensity | Particles | GPU per frame | Sliding particles |
|---|---|---|---|
| 0.5 (medium) | 65k | 5.9 ms | about 1.4k |
| 1.0 (downpour) | 86k | 9.5 ms | about 3k |

Three measures keep this cost down:

- Sleeping (deactivation): water still for 0.5 s is skipped until moving water or its window disturbs it.
- A cell sort every 30 frames keeps neighbour reads close in memory. It gave a 2.2× speedup.
- The frame step never blocks the main thread. It skips a frame if the GPU is still busy.

The Energy Saver quality runs at 30 fps, which halves the cost.

## Rendering

The splat pass sums particle kernels into a field. The composite pass treats the field as the water height over the glass.

Refraction is off by default. When it is on, a ScreenCaptureKit stream copies each display without Varsha's own windows. Leaving Varsha out stops the water from refracting itself.

For each water pixel, a vertical view ray refracts at the surface normal with Snell's law (`refract`, index 1.33). The ray travels through the water depth (`Fluid.lensDepth` × height) and reads the captured pixel it reaches. The content lies on the glass directly under the drop, so the image is magnified and not inverted.

Water below 18% of the height scale is not drawn, and it is fully drawn from 45%. At the first threshold of 8%, one-particle films between beads drew rims around every gap and looked etched. Only the thick upper-left slope of a bead (above 50% height) gets a highlight.

Apple's Liquid Glass (`glassEffect`, `NSGlassEffectView`) was rejected. Its lens profile is fixed and applies per view shape. It cannot follow a particle height field.

## Known limits
- Refraction reads a capture about one frame old, so drops can shimmer while content scrolls behind them.
- The ad-hoc signature changes on each build, so macOS can ask for Screen Recording permission again after a rebuild.

- A single raindrop is 5 to 19 particles. It lands as a thin layer and becomes a bead only after it merges with others.
- In the edge plane, water cannot spill over the front or back of the edge; it leaves only at the corners.
- Edge water drains only at the corners, so in a long downpour the edge film keeps thickening slowly.
- Screen-glass water is drawn in front of windows, but inward rain over a window lands on that window.
