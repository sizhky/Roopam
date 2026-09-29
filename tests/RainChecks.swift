import Foundation
import simd

/// Geometry checks plus headless GPU checks of behaviour that must emerge from the fluid (docs/varsha/physics.md).
@main
struct RainChecks {
    static let dt: CGFloat = 1.0 / 60
    static let calm = RainParams(intensity: 0)
    static let win = WindowFrame(id: 1, rect: CGRect(x: 100, y: 100, width: 400, height: 300))
    static var source = ""

    static func close(_ a: CGFloat, _ b: CGFloat, _ message: String) {
        precondition(abs(a - b) < 1e-7 * max(1, abs(b)), "\(message): \(a) != \(b)")
    }

    static func main() {
        source = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let start = Date()
        geometry()
        impacts()
        let physics = Date()
        edges()
        glass()
        motion()
        print("ok: geometry and rain checks (\(ms(physics.timeIntervalSince(start))) ms), fluid checks (\(ms(Date().timeIntervalSince(physics))) ms)")
    }

    static func ms(_ t: TimeInterval) -> Int { Int(t * 1000) }

    static func water(_ windows: [WindowFrame] = [win], evaporation: Float = 0) -> WindowWater {
        let w = WindowWater(source: source, evaporation: evaporation)
        w.step(dt: dt, windows: windows, params: calm)
        w.wait()
        return w
    }

    static func run(_ w: WindowWater, frames: Int, windows: [WindowFrame] = [win]) {
        for _ in 0..<frames { w.step(dt: dt, windows: windows, params: calm); w.wait() }
    }

    static func centroid(_ ps: [Particle]) -> CGPoint {
        let n = CGFloat(max(1, ps.count))
        return CGPoint(x: ps.reduce(0) { $0 + CGFloat($1.x.x) } / n, y: ps.reduce(0) { $0 + CGFloat($1.x.y) } / n)
    }

    /// Clusters of particles closer than the kernel radius.
    static func clusters(_ ps: [Particle]) -> Int {
        var parent = Array(ps.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
        for i in ps.indices {
            for j in ps.indices where j > i && simd_distance(ps[i].x, ps[j].x) < Fluid.h {
                parent[root(j)] = root(i)
            }
        }
        return Set(ps.indices.map(root)).count
    }

    static func geometry() {
        precondition(win.topHit(from: CGPoint(x: 101, y: 90), to: CGPoint(x: 101, y: 110)) == nil, "rounded corner has no flat ledge")
        let corner = win.topHit(from: CGPoint(x: 101, y: 90), to: CGPoint(x: 101, y: 125))!
        close(corner.y, win.rect.minY + Glass.inset(1, width: win.rect.width), "rounded impact")
        let diagonal = win.topHit(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 250, y: 120))!
        close(diagonal.x, 150, "wind uses swept intersection, not segment endpoint")
        let spans = Occlusion.spans(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 10),
                                    outside: [CGRect(x: -5, y: 4, width: 10, height: 2), CGRect(x: 1, y: 0, width: 5, height: 10)])
        precondition(spans.count == 2, "a streak splits around the window in front of it")
        close(spans[0].upperBound, 0.4, "hidden span starts at the occluder top")
        close(spans[1].lowerBound, 0.6, "hidden span ends at the occluder bottom")
        precondition(Occlusion.spans(from: .zero, to: CGPoint(x: 0, y: 10), outside: [CGRect(x: -1, y: -1, width: 2, height: 20)]).isEmpty,
                     "covered streak is hidden")
    }

    static func impacts() {
        let front = WindowFrame(id: 2, rect: CGRect(x: 0, y: 0, width: 300, height: 300))
        let w = water([front, win])
        precondition(w.catchRain(from: CGPoint(x: 400, y: 90), to: CGPoint(x: 400, y: 110)) != nil, "visible edge catches rain")
        precondition(w.catchRain(from: CGPoint(x: 200, y: 90), to: CGPoint(x: 200, y: 110)) == nil, "covered edge catches nothing")
        precondition(w.catchRain(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 400, y: 260), on: 1, pane: 0.5)?.y == 250,
                     "rain crossing the glass strikes it at its pane height")
        precondition(w.catchRain(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200, y: 260), on: 1, pane: 0.5) == nil,
                     "glass covered by a window in front catches nothing")
        precondition(w.catchRain(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 400, y: 240), on: 1, pane: 0.5) == nil,
                     "rain that has not yet reached its pane height passes on")

        let lower = WindowFrame(id: 2, rect: CGRect(x: 100, y: 180, width: 400, height: 200))
        let layered = water([lower, win])
        close(layered.catchRain(from: CGPoint(x: 300, y: 90), to: CGPoint(x: 300, y: 190))!.y, 100, "first crossed surface wins")
        close(layered.catchRain(from: CGPoint(x: 300, y: 90), to: CGPoint(x: 300, y: 190), on: 2)!.y, 180, "lower window receives its own rain")

        let target = WindowFrame(id: 1, rect: CGRect(x: 0, y: 100, width: 200, height: 120))
        let contact = water([target])
        let engine = RainEngine(size: CGSize(width: 200, height: 200), drops: [RainDrop(x: 100, y: 90, near: 0.4, front: false, window: 1)])
        engine.step(dt: dt, params: calm, windowIDs: [1]) { a, b, d in contact.catchRain(from: a, to: b, on: d.window) }
        precondition(engine.drops[0].impacted, "impact stays visible for one frame")
        close(engine.drops[0].y, 100, "rendered head reaches physical impact")
        engine.step(dt: dt, params: calm, windowIDs: [1])
        precondition(!engine.drops[0].impacted && engine.drops[0].y < 100, "impacted rain respawns next frame")
        run(contact, frames: 1, windows: [target])
        precondition(!contact.snapshot().isEmpty, "a caught drop enters the fluid")
    }

    /// Water on a window edge: beads, merging, conservation, runoff at the corner.
    static func edges() {
        let w = water()
        w.spawn(at: CGPoint(x: 300, y: 97), radius: 2, velocity: CGVector(dx: 0, dy: 50), window: 1, mode: Particle.side)
        run(w, frames: 1)
        let count = w.snapshot().count
        run(w, frames: 120)
        let bead = w.snapshot()
        precondition(bead.count == count, "without evaporation no water is created or lost")
        precondition(bead.allSatisfy { $0.x.y <= Float(win.rect.minY) + 0.05 }, "water stays out of the window")
        let xs = bead.map(\.x.x), ys = bead.map(\.x.y)
        let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!
        precondition(width < 9 && height > 1, "a small drop on the edge rests as a bead, not a film: \(width) x \(height)")
        precondition(clusters(bead) == 1, "the bead holds together")

        let pair = water()
        pair.spawn(at: CGPoint(x: 300, y: 97), radius: 2, velocity: .zero, window: 1, mode: Particle.side)
        pair.spawn(at: CGPoint(x: 305, y: 97), radius: 2, velocity: .zero, window: 1, mode: Particle.side)
        run(pair, frames: 90)
        precondition(clusters(pair.snapshot()) == 1, "touching beads coalesce")

        let spill = water()
        spill.spawn(at: CGPoint(x: 492, y: 94), radius: 5, velocity: .zero, window: 1, mode: Particle.side)
        run(spill, frames: 120)
        precondition(spill.snapshot().contains { $0.x.x > Float(win.rect.maxX) && $0.x.y > Float(win.rect.minY) + 10 },
                     "water that reaches the rounded corner runs down the side")
    }

    /// Water on the glass face: pinning, sliding, trails, evaporation.
    static func glass() {
        let w = water()
        w.spawn(at: CGPoint(x: 200, y: 200), radius: 2, velocity: .zero, window: 1, mode: Particle.face)
        w.spawn(at: CGPoint(x: 400, y: 150), radius: 6, velocity: .zero, window: 1, mode: Particle.face)
        run(w, frames: 1)
        let before = w.snapshot()
        let small = centroid(before.filter { $0.x.x < 300 }), large = centroid(before.filter { $0.x.x >= 300 })
        run(w, frames: 90)
        let after = w.snapshot()
        let pinned = centroid(after.filter { $0.x.x < 300 })
        precondition(hypot(pinned.x - small.x, pinned.y - small.y) < 1, "a small drop is pinned by the glass")
        let slid = after.filter { $0.x.x >= 300 }
        let lead = slid.map { CGFloat($0.x.y) }.max()!
        precondition(lead - large.y > 20, "a large drop slides down")
        precondition(slid.contains { CGFloat($0.x.y) < lead - 15 }, "a sliding drop leaves water behind")

        let dry = water(evaporation: 0.5)
        dry.spawn(at: CGPoint(x: 200, y: 200), radius: 2, velocity: .zero, window: 1, mode: Particle.face)
        run(dry, frames: 1)
        let wet = dry.snapshot().count
        run(dry, frames: 120)
        precondition(dry.snapshot().count < wet, "exposed water evaporates, asleep or awake")
    }

    /// Window motion is only a moving boundary; shedding and carrying must follow from it.
    static func motion() {
        let w = water()
        w.spawn(at: CGPoint(x: 300, y: 97), radius: 2, velocity: .zero, window: 1, mode: Particle.side)
        run(w, frames: 60)
        let dropped = WindowFrame(id: 1, rect: win.rect.offsetBy(dx: 0, dy: 80))
        run(w, frames: 2, windows: [dropped])
        precondition(w.snapshot().allSatisfy { $0.x.y < Float(dropped.rect.minY) - 2 }, "a window pulled down faster than gravity leaves its water in the air")

        let carried = water()
        carried.spawn(at: CGPoint(x: 200, y: 200), radius: 2, velocity: .zero, window: 1, mode: Particle.face)
        run(carried, frames: 30)
        let start = centroid(carried.snapshot())
        var rect = win.rect
        for _ in 0..<30 { rect.origin.x += 1; run(carried, frames: 1, windows: [WindowFrame(id: 1, rect: rect)]) }
        let end = centroid(carried.snapshot())
        precondition(abs(end.x - start.x - 30) < 1.5, "slow window motion carries pinned water with the glass")
    }
}
