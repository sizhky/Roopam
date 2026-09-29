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
    var pane: CGFloat? = nil   // fraction of the target window's height where the drop crosses its glass
    var impacted = false
}

final class RainEngine {
    private(set) var drops: [RainDrop] = []
    var size: CGSize

    init(size: CGSize, drops: [RainDrop] = []) { self.size = size; self.drops = drops }

    static func targetCount(area: CGFloat, params p: RainParams) -> Int {
        let perMegapixel = 40 + 900 * pow(p.intensity, 1.4)
        return Int(area / 1_000_000 * perMegapixel * p.densityScale)
    }

    static func windSpeed(_ p: RainParams) -> CGFloat { p.wind * 320 }

    /// Share of rain aimed at a window that crosses its glass instead of its top edge.
    static let faceShare: CGFloat = 0.3

    func step(dt: CGFloat, params p: RainParams, windowIDs: [Int] = [],
              lands: ((CGPoint, CGPoint, RainDrop) -> CGPoint?)? = nil) {
        guard dt > 0 else { return }
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

    static func length(of drop: RainDrop, params p: RainParams) -> CGFloat {
        (8 + 34 * drop.near) * (0.6 + 0.6 * p.intensity) * drop.seed
    }

    private func spawn(params p: RainParams, anywhere: Bool, windowIDs: [Int]) -> RainDrop {
        let frontShare = 0.04 + 0.32 * p.depth
        let front = CGFloat.random(in: 0...1) < frontShare
        let flat = 1 - p.depth * 0.7
        let near = front ? CGFloat.random(in: 0.6...1) : CGFloat.random(in: 0...0.6) * flat + 0.2 * (1 - flat)
        let window = !front && CGFloat.random(in: 0...1) < 0.8 ? windowIDs.randomElement() : nil
        return RainDrop(x: .random(in: -80...(size.width + 80)),
                        y: anywhere ? .random(in: 0...size.height) : .random(in: -120...(-10)),
                        near: near, front: front, window: window,
                        pane: window != nil && CGFloat.random(in: 0...1) < Self.faceShare ? .random(in: 0.03...0.97) : nil)
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
