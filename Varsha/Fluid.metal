// docs/varsha/physics.md: Solver, Forces, Glass face, Rendering
#include <metal_stdlib>
using namespace metal;

struct Particle { float2 x; float2 v; float2 p; int window; int mode; };
struct Window { float2 origin; float2 size; float2 velocity; int id; int rank; };
struct Params {
    float2 gravity;
    float2 wind;
    float dt;
    float h;
    float rho0;
    float radius;
    float adhesion;
    float viscosity;
    float airDrag;
    float contactRange;
    float pin;
    float edgePin;
    float edgeDrag;
    float substrateDrag;
    float evaporation;
    float corner;
    float scorrK;
    float scorrW;
    float bond;
    float bondRest;
    float sleepSpeed;
    float sleepTime;
    float frameDt;
    float restEvaporation;
    float maxSpeed;
    float killY;
    uint count;
    uint windowCount;
    uint tableMask;
    uint seed;
    float shapeDecay;
};
struct View { float2 origin; float2 size; float radius; float corner; uint windowCount; float threshold; float angle; float rim; };
struct Lens { float scale; float gap; float eta; float shift; float change; uint on; };

constant int DEAD = 0;
constant int SIDE = 1;
constant int FACE = 2;
constant int DETACHED = 3;
constant uint K = 16;

inline int plane(int mode) { return mode == SIDE ? 0 : 1; }
inline int2 cellOf(float2 p, float h) { return int2(floor(p / h)); }
inline uint cellHash(int2 c, uint mask) { return (uint(c.x) * 73856093u ^ uint(c.y) * 19349663u) & mask; }

inline float poly6(float r2, float h) {
    float d = h * h - r2;
    return d > 0 ? 4.0 / (M_PI_F * pow(h, 8.0)) * d * d * d : 0.0;
}

inline float2 spikyGrad(float2 r, float h) {
    float l = length(r);
    if (l <= 1e-6 || l >= h) return float2(0);
    float d = h - l;
    return -30.0 / (M_PI_F * pow(h, 5.0)) * d * d * (r / l);
}

/// Akinci adhesion profile over distance to the solid, peak 1 at 3h/4.
inline float adhesionKernel(float phi, float h) {
    float q = phi / h;
    if (q <= 0.5 || q >= 1.0) return 0.0;
    return pow(max(0.0, -4.0 * q * q + 6.0 * q - 2.0), 0.25) / 0.7071;
}

inline float roundedBox(float2 p, Window w, float corner) {
    float2 extent = w.size * 0.5;
    float r = min(corner, min(extent.x, extent.y));
    float2 q = abs(p - (w.origin + extent)) - extent + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

inline float2 boxNormal(float2 p, Window w, float corner) {
    float e = 0.05;
    float2 g = float2(roundedBox(p + float2(e, 0), w, corner) - roundedBox(p - float2(e, 0), w, corner),
                      roundedBox(p + float2(0, e), w, corner) - roundedBox(p - float2(0, e), w, corner));
    return g / max(length(g), 1e-9);
}

inline int findWindow(int id, constant Window *ws, uint n) {
    for (uint k = 0; k < n; k++) { if (ws[k].id == id) return int(k); }
    return -1;
}

inline float hash01(uint a, uint b) {
    uint h = a * 747796405u + b * 2891336453u + 12345u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    h = (h >> 22u) ^ h;
    return float(h) / 4294967295.0;
}

/// Smooth value noise; the glass surface energy varies on this field.
inline float valueNoise(float2 p, int seed) {
    float2 i = floor(p), f = p - i;
    float2 s = f * f * (3.0 - 2.0 * f);
    uint sx = uint(int(i.x)), sy = uint(int(i.y)), ss = uint(seed) * 2654435761u;
    float a = hash01(sx ^ ss, sy), b = hash01((sx + 1u) ^ ss, sy);
    float c = hash01(sx ^ ss, sy + 1u), d = hash01((sx + 1u) ^ ss, sy + 1u);
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}


inline bool asleep(device const float *idle, uint i, constant Params &P) { return idle[i] >= P.sleepTime; }

// Visits every live neighbour j of particle i that shares its window and plane.
#define FOR_NEIGHBORS(POS, BODY) { \
    int2 base = cellOf(POS, P.h); \
    for (int oy = -1; oy <= 1; oy++) for (int ox = -1; ox <= 1; ox++) { \
        int2 cc = base + int2(ox, oy); \
        uint hc = cellHash(cc, P.tableMask); \
        uint nb_ = min(counts[hc], K); \
        for (uint k_ = 0; k_ < nb_; k_++) { \
            uint j = cells[hc * K + k_]; \
            if (j == i || any(cellCoord[j] != cc)) continue; \
            Particle o = ps[j]; \
            if (o.mode == DEAD || o.window != me.window || plane(o.mode) != plane(me.mode)) continue; \
            BODY \
        } \
    } }

kernel void predict(device Particle *ps [[buffer(0)]], device const float2 *accel [[buffer(1)]],
                    device const float *idle [[buffer(2)]], constant Params &P [[buffer(3)]],
                    uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle q = ps[i];
    if (q.mode == DEAD || asleep(idle, i, P)) return;
    float2 v = q.v + P.dt * (P.gravity + accel[i]);
    float s = length(v);
    if (s > P.maxSpeed) v *= P.maxSpeed / s;
    q.v = v;
    q.p = q.x + P.dt * v;
    ps[i] = q;
}

kernel void clearGrid(device uint *counts [[buffer(0)]], uint i [[thread_position_in_grid]]) { counts[i] = 0; }

kernel void insert(device const Particle *ps [[buffer(0)]], device atomic_uint *counts [[buffer(1)]],
                   device uint *cells [[buffer(2)]], device int2 *cellCoord [[buffer(3)]],
                   constant Params &P [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= P.count || ps[i].mode == DEAD) return;
    int2 c = cellOf(ps[i].p, P.h);
    cellCoord[i] = c;
    uint hc = cellHash(c, P.tableMask);
    uint slot = atomic_fetch_add_explicit(&counts[hc], 1u, memory_order_relaxed);
    if (slot < K) cells[hc * K + slot] = i;
}

/// PBF density constraint (Macklin & Mueller 2013), plus the exposure of each particle from the offset of its
/// neighbourhood. Near an edge the solid is filled with fixed ghost lattice points for exposure only,
/// so only the water-air boundary, and the contact line where it meets glass, reads as surface.
kernel void solveLambda(device const Particle *ps [[buffer(0)]], device const uint *counts [[buffer(1)]],
                        device const uint *cells [[buffer(2)]], device const int2 *cellCoord [[buffer(3)]],
                        device float *lambda [[buffer(4)]], device float *surface [[buffer(5)]],
                        device const float *idle [[buffer(6)]], constant Window *ws [[buffer(7)]],
                        constant Params &P [[buffer(8)]],
                        uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle me = ps[i];
    if (me.mode == DEAD) return;
    if (asleep(idle, i, P)) { lambda[i] = 0.0; return; }
    float rho = poly6(0.0, P.h), sum2 = 0.0, weight = 0.0;
    float2 gi = float2(0), offset = float2(0);
    FOR_NEIGHBORS(me.p, {
        float2 r = me.p - o.p;
        float r2 = dot(r, r);
        if (r2 < P.h * P.h) {
            float w = poly6(r2, P.h);
            rho += w;
            weight += w;
            offset += w * r;
            float2 g = spikyGrad(r, P.h) / P.rho0;
            gi += g;
            sum2 += dot(g, g);
        }
    })
    int wi = me.mode == SIDE ? findWindow(me.window, ws, P.windowCount) : -1;
    if (wi >= 0) {
        float phi = roundedBox(me.p, ws[wi], P.corner);
        if (phi < P.h) {
            float2 nw = boxNormal(me.p, ws[wi], P.corner), tw = float2(-nw.y, nw.x);
            float d = 2.0 * P.radius, row = d * 0.8660254;
            float t = dot(me.p - ws[wi].origin, tw), base = floor(t / d);
            for (int k = 0; k < 3; k++) {
                for (int m = -2; m <= 3; m++) {
                    float tg = (base + float(m) + (k & 1 ? 0.5 : 0.0)) * d;
                    float2 r = nw * (phi + 0.5 * d + float(k) * row) + tw * (t - tg);
                    float r2 = dot(r, r);
                    if (r2 < P.h * P.h) { float w = poly6(r2, P.h); weight += w; offset += w * r; }
                }
            }
        }
    }
    surface[i] = weight > 0.0 ? clamp(length(offset) / (weight * P.h) * 4.0, 0.0, 1.0) : 1.0;
    float C = max(rho / P.rho0 - 1.0, 0.0);
    lambda[i] = -C / (sum2 + dot(gi, gi) + 0.05);
}

/// Density correction plus cohesion as a pair constraint (Macklin et al. 2014). Cohesion draws neighbours near
/// the kernel edge back toward bondRest, beyond the second lattice ring, so it holds a surface without
/// fighting the bulk lattice. Cohesion against gravity sets the drop shape.
kernel void solveDelta(device const Particle *ps [[buffer(0)]], device const uint *counts [[buffer(1)]],
                       device const uint *cells [[buffer(2)]], device const int2 *cellCoord [[buffer(3)]],
                       device const float *lambda [[buffer(4)]], device float2 *dp [[buffer(5)]],
                       device const float *idle [[buffer(6)]], constant Params &P [[buffer(7)]],
                       uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle me = ps[i];
    if (me.mode == DEAD) return;
    if (asleep(idle, i, P)) { dp[i] = float2(0); return; }
    float2 d = float2(0);
    FOR_NEIGHBORS(me.p, {
        float2 r = me.p - o.p;
        float r2 = dot(r, r);
        if (r2 < P.h * P.h) {
            float w = poly6(r2, P.h) / P.scorrW;
            float corr = -P.scorrK * w * w * w * w;
            d += (lambda[i] + lambda[j] + corr) * spikyGrad(r, P.h) / P.rho0;
            float l = sqrt(r2);
            if (l > P.bondRest) d -= 0.5 * P.bond * (l - P.bondRest) * (1.0 - (l - P.bondRest) / (P.h - P.bondRest)) * (r / l);
        }
    })
    float l = length(d), cap = 0.25 * P.h;
    dp[i] = l > cap ? d * (cap / l) : d;
}

/// Applies the density correction, then keeps particles out of their own window's solid edge.
kernel void applyDelta(device Particle *ps [[buffer(0)]], device const float2 *dp [[buffer(1)]],
                       device const float *idle [[buffer(2)]], constant Window *ws [[buffer(3)]],
                       constant Params &P [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle q = ps[i];
    if (q.mode == DEAD || asleep(idle, i, P)) return;
    float2 p = q.p + dp[i];
    int wi = q.mode == SIDE ? findWindow(q.window, ws, P.windowCount) : -1;
    if (wi >= 0) {
        float phi = roundedBox(p, ws[wi], P.corner);
        if (phi < P.radius) p += boxNormal(p, ws[wi], P.corner) * (P.radius - phi);
    }
    q.p = p;
    ps[i] = q;
}

/// Contact with glass, on the face or on an edge: the exposed contact line holds tangential slip up to
/// pin * surface energy (contact-angle hysteresis), and slip over the glass is viscously damped.
/// Surface energy is a smooth field plus sparse strong defects, the spots that snag a receding contact line.
kernel void finish(device Particle *ps [[buffer(0)]], device const float *surface [[buffer(1)]],
                   device float *idle [[buffer(2)]], constant Window *ws [[buffer(3)]],
                   constant Params &P [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle q = ps[i];
    if (q.mode == DEAD || asleep(idle, i, P)) return;
    float s = surface[i];
    int wi = q.mode == FACE || q.mode == SIDE ? findWindow(q.window, ws, P.windowCount) : -1;
    if (q.mode == FACE && (wi < 0 || roundedBox(q.p, ws[wi], P.corner) > 0.0)) { q.mode = DETACHED; wi = -1; }
    float2 n = float2(0);
    bool contact = wi >= 0 && q.mode == FACE;
    if (wi >= 0 && q.mode == SIDE && roundedBox(q.p, ws[wi], P.corner) < P.contactRange) {
        contact = true;
        n = boxNormal(q.p, ws[wi], P.corner);
    }
    if (contact) {
        Window w = ws[wi];
        float2 local = q.p - w.origin;
        float defect = valueNoise(local / 2.5 + 17.0, w.id + 7);
        float energy = 0.6 + 0.8 * valueNoise(local / 10.0, w.id) + 4.0 * pow(defect, 6.0);
        float2 slip = (q.p - q.x) - w.velocity * P.dt;
        float2 normal = dot(slip, n) * n, tangent = slip - normal;
        float hold = (q.mode == SIDE ? P.edgePin : P.pin) * s * energy * P.dt * P.dt, l = length(tangent);
        tangent = l <= hold ? float2(0) : tangent * (1.0 - hold / l);
        q.p = q.x + w.velocity * P.dt + normal + tangent * exp(-(q.mode == SIDE ? P.edgeDrag : P.substrateDrag) * P.dt);
    }
    q.v = (q.p - q.x) / P.dt;
    q.x = q.p;
    idle[i] = length(q.v) < P.sleepSpeed ? idle[i] + P.dt : 0.0;
    if (idle[i] >= P.sleepTime) q.v = float2(0);
    if (q.x.y > P.killY || hash01(i, P.seed) < P.evaporation * s * P.dt) q.mode = DEAD;
    ps[i] = q;
}

/// XSPH viscosity, Akinci et al. 2013 adhesion to the window edge, and air drag on exposed water.
kernel void forces(device const Particle *ps [[buffer(0)]], device const uint *counts [[buffer(1)]],
                   device const uint *cells [[buffer(2)]], device const int2 *cellCoord [[buffer(3)]],
                   device const float *surface [[buffer(4)]], device float2 *accel [[buffer(5)]],
                   device const float *idle [[buffer(6)]], constant Window *ws [[buffer(7)]],
                   constant Params &P [[buffer(8)]], uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle me = ps[i];
    if (me.mode == DEAD || asleep(idle, i, P)) return;
    float2 a = float2(0), xsph = float2(0);
    FOR_NEIGHBORS(me.x, {
        float2 r = me.x - o.x;
        xsph += (o.v - me.v) * poly6(dot(r, r), P.h);
    })
    a += P.viscosity * xsph / (P.rho0 * P.dt);
    int wi = me.mode == SIDE ? findWindow(me.window, ws, P.windowCount) : -1;
    if (wi >= 0) {
        float phi = roundedBox(me.x, ws[wi], P.corner);
        if (phi < P.h) a -= P.adhesion * adhesionKernel(phi, P.h) * boxNormal(me.x, ws[wi], P.corner);
    }
    a += P.airDrag * (0.25 + 0.75 * surface[i]) * (P.wind - me.v);
    accel[i] = a;
}

/// Deactivation (as in rigid-body engines): water still for sleepTime stops being integrated and acts as a
/// fixed neighbour. It wakes when its window moves or when moving water of the same plane reaches it.
/// Sleeping water keeps evaporating, once per frame, at the budgeted rate (docs/varsha/physics.md: Particle budget).
kernel void wake(device Particle *ps [[buffer(0)]], device const uint *counts [[buffer(1)]],
                 device const uint *cells [[buffer(2)]], device const int2 *cellCoord [[buffer(3)]],
                 device float *idle [[buffer(4)]], device const float *surface [[buffer(5)]],
                 constant Window *ws [[buffer(6)]], constant Params &P [[buffer(7)]],
                 uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle me = ps[i];
    if (me.mode == DEAD || !asleep(idle, i, P)) return;
    if (hash01(i, P.seed ^ 0x9e3779b9u) < P.restEvaporation * surface[i] * P.frameDt) { ps[i].mode = DEAD; return; }
    int wi = findWindow(me.window, ws, P.windowCount);
    bool stir = wi < 0 || length(ws[wi].velocity) > 0.0;
    FOR_NEIGHBORS(me.x, { if (!asleep(idle, j, P) && length(o.v) >= P.sleepSpeed) stir = true; })
    if (stir) idle[i] = 0.0;
}

/// docs/varsha/physics.md: Rendering. Distance from each particle to its drop's contact line, relaxed over the
/// neighbour graph (Bellman-Ford), and the largest such distance in its drop, which is the drop's radius.
/// Exposed particles lie on the contact line. The radius decays slowly, so a drop that splits shrinks to fit.
kernel void shape(device const Particle *ps [[buffer(0)]], device const uint *counts [[buffer(1)]],
                  device const uint *cells [[buffer(2)]], device const int2 *cellCoord [[buffer(3)]],
                  device const float *surface [[buffer(4)]], device const float2 *edgeIn [[buffer(5)]],
                  device float2 *edgeOut [[buffer(6)]], constant Params &P [[buffer(7)]],
                  uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle me = ps[i];
    if (me.mode == DEAD) { edgeOut[i] = float2(0); return; }
    float d = surface[i] >= 0.5 ? 0.0 : 1e4, a = 0.0;
    FOR_NEIGHBORS(me.x, {
        float l = length(me.x - o.x);
        if (l < P.h) { float2 e = edgeIn[j]; d = min(d, e.x + l); a = max(a, e.y); }
    })
    if (d >= 1e4) d = 0.0;
    edgeOut[i] = float2(d, max(d, a - P.shapeDecay * P.frameDt * 0.25));
}

struct SplatOut {
    float4 position [[position]];
    float2 uv;
    float2 world;
    int rank [[flat]];
    float height [[flat]];
};

vertex SplatOut splatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            device const Particle *ps [[buffer(0)]], constant View &V [[buffer(1)]],
                            constant Window *ws [[buffer(2)]], device const float2 *edge [[buffer(3)]]) {
    SplatOut o;
    Particle q = ps[iid];
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 world = q.x + corner * V.radius;
    float2 local = world - V.origin;
    o.position = q.mode == DEAD ? float4(-4, -4, 0, 1)
                                : float4(local.x / V.size.x * 2.0 - 1.0, 1.0 - local.y / V.size.y * 2.0, 0, 1);
    o.uv = corner;
    o.world = world;
    int k = findWindow(q.window, ws, V.windowCount);
    o.rank = k < 0 ? 0 : ws[k].rank;
    // Spherical cap of contact angle V.angle over the drop's footprint: surface tension under uniform pressure.
    float a = edge[iid].y + V.rim, r = a - (edge[iid].x + V.rim), Rc = a / sin(V.angle);
    o.height = max(0.0, sqrt(max(Rc * Rc - r * r, 0.0)) - Rc * cos(V.angle));
    return o;
}

/// Water of window k is hidden wherever a window in front of k covers it. Screen glass has rank -1:
/// nothing covers it, and it covers nothing.
fragment float2 splatFragment(SplatOut in [[stage_in]], constant View &V [[buffer(0)]], constant Window *ws [[buffer(1)]]) {
    float r2 = dot(in.uv, in.uv);
    if (r2 >= 1.0) discard_fragment();
    for (uint k = 0; k < V.windowCount; k++) {
        if (ws[k].rank >= 0 && ws[k].rank < in.rank && roundedBox(in.world, ws[k], V.corner) < 0.0) discard_fragment();
    }
    float w = 1.0 - r2;
    w = w * w * w;
    return float2(w, w * in.height);
}

struct FullOut { float4 position [[position]]; };

vertex FullOut fullscreen(uint vid [[vertex_id]]) {
    FullOut o;
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    return o;
}

/// docs/varsha/physics.md: Rendering. The field holds splat weight and weight times cap height, so their ratio is the
/// water height in points. The weight fades the height to zero at the contact line.
/// A view ray refracts at the water surface (Snell) and travels through the water and the gap to the content below.
/// The capture is one frame older than the screen under the overlay. Where the ray lands near its own pixel, or where
/// the last two captures differ, the drop lets the live pixel through and only darkens it, so stale colour never shows.
fragment float4 composite(FullOut in [[stage_in]], texture2d<float> field [[texture(0)]],
                          texture2d<float> backdrop [[texture(1)]], constant View &V [[buffer(0)]],
                          constant Lens &lens [[buffer(1)]], texture2d<float> previous [[texture(2)]]) {
    int2 c = int2(in.position.xy);
    int2 last = int2(field.get_width() - 1, field.get_height() - 1);
    auto height = [&](int2 o) {
        float2 f = field.read(uint2(clamp(c + o, int2(0), last))).rg;
        float fade = smoothstep(V.threshold * 0.45, V.threshold * 2.2, f.r);
        return f.r > 1e-4 ? f.g / f.r * fade : 0.0;
    };
    float2 f0 = field.read(uint2(c)).rg;
    float z = smoothstep(V.threshold * 0.45, V.threshold * 2.2, f0.r);
    if (z <= 0.0) return float4(0);
    float h = height(int2(0)), dx = 0.0, dy = 0.0;
    for (int k = 1; k <= 3; k++) {
        dx += (height(int2(k, 0)) - height(int2(-k, 0))) / float(2 * k);
        dy += (height(int2(0, k)) - height(int2(0, -k))) / float(2 * k);
    }
    dx *= lens.scale / 3.0; dy *= lens.scale / 3.0;
    float cover = smoothstep(0.0, 0.08, z);
    float3 n = normalize(float3(-dx, -dy, 1.0));
    float3 L = normalize(float3(-0.45, -0.75, 0.55));
    float3 H = normalize(L + float3(0, 0, 1));
    float spec = pow(max(dot(n, H), 0.0), 160.0) * 0.9;
    float slope = 1.0 - n.z;
    float edge = smoothstep(0.05, 0.5, slope);
    float focus = max(0.0, dot(normalize(n.xy + 1e-6), -L.xy)) * smoothstep(0.02, 0.25, slope) * (1.0 - edge * 0.6) * 0.5;
    float light = min(1.0, spec + focus);
    if (lens.on != 0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 t = refract(float3(0, 0, -1), n, lens.eta);
        float2 hit = in.position.xy + t.xy / max(-t.z, 0.2) * (h + lens.gap) * lens.scale;
        float2 pixels = float2(field.get_width(), field.get_height());
        float2 at = hit / pixels, here = in.position.xy / pixels;
        float3 behind = backdrop.sample(s, at).rgb;
        float3 change = max(abs(behind - previous.sample(s, at).rgb), abs(backdrop.sample(s, here).rgb - previous.sample(s, here).rgb));
        float fresh = 1.0 - smoothstep(lens.change * 0.25, lens.change, max(change.r, max(change.g, change.b)));
        float image = smoothstep(lens.shift * 0.25, lens.shift, length(hit - in.position.xy)) * fresh;
        float keep = 0.98 * (1.0 - 0.2 * edge);
        float3 water = behind * float3(0.97, 0.985, 1.0) * (1.0 - 0.2 * edge);
        float alpha = 1.0 - (1.0 - image) * keep * (1.0 - spec);
        return cover * float4((1.0 - spec) * image * water + spec, alpha);
    }
    float dark = cover * 0.32 * edge;
    float body = cover * 0.03;
    float alpha = min(1.0, light * cover + (dark + body) * (1.0 - light));
    float3 rgb = cover * light * float3(1.0) + body * float3(0.85, 0.93, 1.0);
    return float4(rgb, alpha);
}
