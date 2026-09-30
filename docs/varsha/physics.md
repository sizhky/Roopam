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
- Inward rain (`InwardDrop`): drops moving toward the viewer, 90 per second per megapixel at full intensity, radius 2.4 to 7.2 pt. It is the only source of water on glass.
  Each lands on the frontmost glass under its impact point: an app window's face, otherwise the screen glass.
- Downpour draws 1540 streaks per megapixel (medium intensity draws about 600).


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
| substrateDrag | 18 | Glass pane. Sliding drops reach about gravity / drag = 100 pt/s, so merged drops trickle slowly |
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

The splat pass sums particle kernels into a two-channel field: kernel weight, and kernel weight times particle height. The composite pass divides them to get the water height in points.

A drop on glass is a spherical cap: surface tension under a uniform internal pressure gives constant curvature (Young-Laplace). The particle density is flat inside a drop, so density alone gave a flat top and a 1 pt slope at the rim, and only the rim refracted. The `shape` kernel gives each particle its distance `d` to the contact line and its drop radius `a`:
- `d` relaxes over the neighbour graph (Bellman-Ford). Exposed particles are 0; every other particle takes the minimum over neighbours of their `d` plus the gap to them.
- `a` is the largest `d` in the drop, spread by a maximum over neighbours. It shrinks at `Fluid.shapeDecay` (10 pt/s), so a drop that splits resizes.
- It runs four passes in the first substep of each frame, so a 7 pt drop settles in about three frames.

Particle height is `sqrt(R² − (a − d)²) − R cos θ` with `R = a / sin θ`, both offset by `Fluid.rim` (0.6 pt) from the outermost particle centres to the contact line. The contact angle θ is `Fluid.contactAngle` (60°, weathered window glass).

Refraction is off by default. When it is on, a ScreenCaptureKit stream copies each display without Varsha's own windows. Leaving Varsha out stops the water from refracting itself.

For each water pixel, a vertical view ray refracts at the surface normal with Snell's law (`refract`, index 1.33). The ray travels through the water height and a further `Fluid.contentGap` (10 pt) to the content, then reads the captured pixel it reaches. The cap is a plano-convex lens of focal length `R / (n − 1)`, so magnification is about `f / (f − gap)`: 1.4× for a 7 pt drop.

Tuned by headless renders over a dark and a white screenshot. A 4 pt gap magnified about 1.1×, which was not visible. A 24 pt gap put the content past the focal length of most drops, which inverted and smeared it. At 60° and 10 pt, drops under 3 pt are near focus and show mostly the dark surroundings, as small real drops do. The specular exponent is 160, because the broader normals of a cap made the old exponent of 36 a large white blob.

The capture is at least one frame behind the screen. The window server composites frame N, ScreenCaptureKit then delivers it, and the water drawn from it appears over frame N+1. No capture-based renderer can remove this lag. A zero-lag lens needs the window server itself (`CABackdropLayer`), which is private and has no displacement filter.

The composite hides the lag in two ways. Both let the live pixel under the overlay show through, only darkened by the drop, instead of the captured one.
- Near the drop centre, the ray lands close to its own pixel, so the live pixel is almost the refracted one. The captured image fades in with the ray offset and replaces the live pixel fully at `Fluid.liveShift` (0.75 pt). Stale colour can then appear only on the rim.
- Where the last two captures differ, the screen is changing, so the newest capture is probably stale too. The captured image fades out and is gone at a colour change of `Fluid.staleChange` (0.12 per channel). The test runs at both the pixel and the point the ray lands on.

Apple's Liquid Glass (`glassEffect`, `NSGlassEffectView`) was rejected. Its lens profile is fixed and applies per view shape. It cannot follow a particle height field.

## Rain streaks

A falling streak is the motion blur of one drop over one exposure (`RainEngine.exposure`, 1/40 s), after Garg and Nayar, "Photorealistic Rendering of Rain Streaks" (SIGGRAPH 2006). Its length is the drop's screen speed times the exposure. Its width is the drop's apparent diameter. Nearer drops look larger, and heavier rain has larger drops.

A point on the streak sees the drop for `2r / (v T)` of the exposure (`RainEngine.coverTime`) and the background for the rest. That share is the streak's alpha. The streak is uniform along its length, as constant-velocity blur is.

A drop refracts a wide cone of the scene behind it. With a backdrop, its radiance is the mean of eight backdrop samples on a ring (`RainStreaks.reach`, 90 pt), mixed with a fixed overcast sky (`RainStreaks.sky`, 45%) for the part of the cone outside the screen. Streaks therefore show clearly against dark content and faintly against bright content. Without a backdrop, the radiance is the sky alone.

Streaks render on the GPU (`Rain.metal`) at the layer's backing scale. Pixel coverage is the exact box filter of the streak width, so sub-pixel drops fade instead of aliasing. Both overlay layers read the screen's backdrop.

Rejected: a dark offset under-stroke for light backgrounds. Clear water casts no such outline.

## Known limits
- Refraction reads a capture about one frame old, so drops can shimmer while content scrolls behind them.
- The ad-hoc signature changes on each build, so macOS can ask for Screen Recording permission again after a rebuild.

- A single raindrop is 5 to 19 particles. It lands as a thin layer and becomes a bead only after it merges with others.
- In the edge plane, water cannot spill over the front or back of the edge; it leaves only at the corners.
- Edge water drains only at the corners, so in a long downpour the edge film keeps thickening slowly.
- Screen-glass water is drawn in front of windows, but inward rain over a window lands on that window.
