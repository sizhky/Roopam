import CoreGraphics
import Foundation

/// Pure simulation of falling rain for one screen. No AppKit, so tests can drive it.
struct RainParams {
    var intensity: CGFloat = 0.5   // 0 drizzle ... 1 downpour
    var wind: CGFloat = 0          // -1 left ... 1 right
    var depth: CGFloat = 0.5       // 0 flat ... 1 deep
    var densityScale: CGFloat = 1  // quality scaling
}

struct RainDrop {
    var x: CGFloat
    var y: CGFloat
    var near: CGFloat   // 0 far ... 1 near; drives speed, length, opacity
    var front: Bool     // drawn in front of windows
    var seed = CGFloat.random(in: 0.7...1.3)
    var window: Int? = nil
    var impacted = false
}

/// Rain moving toward the viewer. It is seen falling and growing until it meets the glass at `target`.
struct InwardDrop {
    var target: CGPoint   // screen-local impact point
    var life: CGFloat     // seconds from appearing to impact
    var radius: CGFloat   // drop radius on arrival, points
    var drift: CGVector   // on-screen velocity while approaching
    var age: CGFloat = 0

    var progress: CGFloat { min(1, age / life) }
    var head: CGPoint { CGPoint(x: target.x - drift.dx * (life - age), y: target.y - drift.dy * (life - age)) }
}

final class RainEngine {
    private(set) var drops: [RainDrop] = []
    private(set) var inward: [InwardDrop] = []
    private var inwardDue: CGFloat = 0
    var size: CGSize

    init(size: CGSize, drops: [RainDrop] = []) { self.size = size; self.drops = drops }

    static func targetCount(area: CGFloat, params p: RainParams) -> Int {
        let perMegapixel = 40 + 1500 * pow(p.intensity, 1.4)
        return Int(area / 1_000_000 * perMegapixel * p.densityScale)
    }

    static func windSpeed(_ p: RainParams) -> CGFloat { p.wind * 600 }

    /// Share of background rain aimed at a window's outline; the rest falls behind every window.
    static let aimedShare: CGFloat = 0.35

    /// Radius scale of inward drops. The rate falls with its square, so water per second stays the same.
    static let inwardSize: CGFloat = 1.6

    /// Inward drops per second per megapixel of screen.
    static func inwardRate(area: CGFloat, params p: RainParams) -> CGFloat {
        area / 1_000_000 * 90 * pow(p.intensity, 1.2) * p.densityScale / (inwardSize * inwardSize)
    }

    /// Screen-local outlines of the windows rain can be aimed at, by window id.
    var targets: [Int: CGRect] = [:]

    func step(dt: CGFloat, params p: RainParams, windowIDs: [Int] = [],
              lands: ((CGPoint, CGPoint, RainDrop) -> CGPoint?)? = nil,
              strikes: ((InwardDrop) -> Void)? = nil) {
        guard dt > 0 else { return }
        stepInward(dt: dt, params: p, strikes: strikes)
        let target = Self.targetCount(area: size.width * size.height, params: p)
        while drops.count < target { drops.append(spawn(params: p, anywhere: true, windowIDs: windowIDs)) }
        if drops.count > target { drops.removeLast(drops.count - target) }
        let sway = Self.windSpeed(p)
        for i in drops.indices {
            if drops[i].impacted || (drops[i].window.map { !windowIDs.contains($0) } ?? false) {
                drops[i] = spawn(params: p, anywhere: false, windowIDs: windowIDs)
            }
            let speed = 520 + 900 * drops[i].near
            let from = CGPoint(x: drops[i].x, y: drops[i].y)
            drops[i].y += speed * dt
            drops[i].x += sway * (0.4 + drops[i].near) * dt
            if drops[i].window != nil, let hit = lands?(from, CGPoint(x: drops[i].x, y: drops[i].y), drops[i]) {
                drops[i].x = hit.x
                drops[i].y = hit.y
                drops[i].impacted = true
                continue
            }
            if drops[i].y > size.height + 60 { drops[i] = spawn(params: p, anywhere: false, windowIDs: windowIDs) }
            if drops[i].x < -80 { drops[i].x += size.width + 160 }
            if drops[i].x > size.width + 80 { drops[i].x -= size.width + 160 }
        }
    }

    private func stepInward(dt: CGFloat, params p: RainParams, strikes: ((InwardDrop) -> Void)?) {
        inwardDue += Self.inwardRate(area: size.width * size.height, params: p) * dt
        while inwardDue >= 1 {
            inwardDue -= 1
            let u = CGFloat.random(in: 0...1)
            let fall = CGFloat.random(in: 450...900)
            inward.append(InwardDrop(target: CGPoint(x: .random(in: 0...size.width), y: .random(in: 0...size.height)),
                                     life: .random(in: 0.08...0.18), radius: (1.5 + 3.0 * u * u) * Self.inwardSize,
                                     drift: CGVector(dx: Self.windSpeed(p) * 0.8, dy: fall)))
        }
        for i in inward.indices { inward[i].age += dt }
        for d in inward where d.age >= d.life { strikes?(d) }
        inward.removeAll { $0.age >= $0.life }
    }

    static func length(of drop: RainDrop, params p: RainParams) -> CGFloat {
        (8 + 30 * drop.near + 70 * pow(drop.near, 4)) * (0.6 + 0.6 * p.intensity) * drop.seed
    }

    private func spawn(params p: RainParams, anywhere: Bool, windowIDs: [Int]) -> RainDrop {
        let frontShare = 0.04 + 0.32 * p.depth
        let front = CGFloat.random(in: 0...1) < frontShare
        let flat = 1 - p.depth * 0.7
        let near = front ? 0.6 + 0.4 * pow(CGFloat.random(in: 0...1), 3) : CGFloat.random(in: 0...0.6) * flat + 0.2 * (1 - flat)
        let window = !front && CGFloat.random(in: 0...1) < Self.aimedShare ? windowIDs.randomElement() : nil
        var drop = RainDrop(x: .random(in: -80...(size.width + 80)),
                            y: anywhere ? .random(in: 0...size.height) : .random(in: -120...(-10)),
                            near: near, front: front, window: window)
        if !anywhere, let id = window, let rect = targets[id] { aim(&drop, at: rect, params: p) }
        return drop
    }

    /// Starts an aimed drop on the straight path that meets its window's outline. Rain meets the top in
    /// proportion to its width and the windward side in proportion to height times the slant of the fall.
    private func aim(_ d: inout RainDrop, at r: CGRect, params p: RainParams) {
        let slope = Self.windSpeed(p) * (0.4 + d.near) / (520 + 900 * d.near)
        let corner = min(Glass.cornerRadius, r.width / 2, r.height / 2), side = (r.height - 2 * corner) * abs(slope)
        let target: CGPoint
        if CGFloat.random(in: 0...(r.width + side)) < side {
            target = CGPoint(x: slope > 0 ? r.minX : r.maxX, y: .random(in: (r.minY + corner)...(r.maxY - corner)))
        } else {
            target = CGPoint(x: .random(in: r.minX...r.maxX), y: r.minY)
        }
        d.x = target.x - slope * (target.y - d.y)
    }
}

enum Occlusion {
    /// Parameter ranges of segment a→b that lie outside every rect.
    /// >>> spans(from: (0,0), to: (0,10), outside: [rect y 4...6]) == [0...0.4, 0.6...1]
    static func spans(from a: CGPoint, to b: CGPoint, outside rects: [CGRect]) -> [ClosedRange<CGFloat>] {
        var open: [ClosedRange<CGFloat>] = [0...1]
        for r in rects {
            guard let hidden = inside(r, from: a, to: b) else { continue }
            open = open.flatMap { s -> [ClosedRange<CGFloat>] in
                guard hidden.lowerBound < s.upperBound, hidden.upperBound > s.lowerBound else { return [s] }
                var parts: [ClosedRange<CGFloat>] = []
                if hidden.lowerBound > s.lowerBound { parts.append(s.lowerBound...hidden.lowerBound) }
                if hidden.upperBound < s.upperBound { parts.append(hidden.upperBound...s.upperBound) }
                return parts
            }
            if open.isEmpty { break }
        }
        return open
    }

    /// Liang-Barsky clip of segment a→b against r.
    private static func inside(_ r: CGRect, from a: CGPoint, to b: CGPoint) -> ClosedRange<CGFloat>? {
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        for (p, q) in [(-dx, a.x - r.minX), (dx, r.maxX - a.x), (-dy, a.y - r.minY), (dy, r.maxY - a.y)] {
            if p == 0 { if q < 0 { return nil }; continue }
            let t = q / p
            if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
        }
        return t0 < t1 ? t0...t1 : nil
    }
}
