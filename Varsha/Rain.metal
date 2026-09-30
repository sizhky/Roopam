// docs/varsha/physics.md: Rain streaks
#include <metal_stdlib>
using namespace metal;

struct Streak { float2 a; float2 b; float radius; float cover; };
struct StreakView { float2 size; float scale; float reach; float sky; uint backdrop; };

struct StreakOut {
    float4 position [[position]];
    float2 world;
    float2 a [[flat]];
    float2 b [[flat]];
    float radius [[flat]];
    float cover [[flat]];
};

/// One quad per streak: the capsule from a to b, padded by one pixel for the filter.
vertex StreakOut streakVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant Streak *streaks [[buffer(0)]], constant StreakView &V [[buffer(1)]]) {
    Streak s = streaks[iid];
    float2 along = s.b - s.a;
    float2 dir = length(along) > 1e-4 ? normalize(along) : float2(0, 1);
    float2 side = float2(-dir.y, dir.x);
    float pad = s.radius + 1.0 / V.scale;
    float2 end = (vid & 2) ? s.b + dir * pad : s.a - dir * pad;
    float2 world = end + side * ((vid & 1) ? pad : -pad);
    StreakOut o;
    o.position = float4(world.x / V.size.x * 2.0 - 1.0, 1.0 - world.y / V.size.y * 2.0, 0, 1);
    o.world = world;
    o.a = s.a; o.b = s.b; o.radius = s.radius; o.cover = s.cover;
    return o;
}

/// A pixel of the streak sees the drop for `cover` of the exposure and the background for the rest.
/// The drop refracts a wide cone of the scene behind it, so its radiance is the average of a wide ring of the
/// backdrop, mixed with the sky that lies outside the screen. Pixel coverage is the exact box filter of the width.
fragment float4 streakFragment(StreakOut in [[stage_in]], texture2d<float> backdrop [[texture(0)]],
                               constant StreakView &V [[buffer(0)]]) {
    float2 ab = in.b - in.a;
    float t = clamp(dot(in.world - in.a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    float x = length(in.world - (in.a + ab * t)) * V.scale;
    float w = in.radius * V.scale;
    float width = clamp(min(x + 0.5, w) - max(x - 0.5, -w), 0.0, 1.0);
    float alpha = width * in.cover;
    if (alpha <= 0.0) discard_fragment();
    float3 sky = float3(0.82, 0.86, 0.9);
    float3 scene = sky;
    if (V.backdrop != 0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 centre = in.world / V.size;
        float2 reach = V.reach / V.size;
        float3 sum = float3(0);
        for (int k = 0; k < 8; k++) {
            float angle = float(k) * (M_PI_F / 4.0);
            sum += backdrop.sample(s, centre + reach * float2(cos(angle), sin(angle))).rgb;
        }
        scene = mix(sum / 8.0, sky, V.sky);
    }
    return float4(scene * alpha, alpha);
}
