import AppKit
import QuartzCore

enum RainLayer { case back, front }

/// Draws one layer of one screen. Coordinates are top-left, in points.
final class RainView: NSView {
    let layer_: RainLayer
    let screenOrigin: CGPoint   // screen origin in global top-left coordinates
    unowned let engine: RainEngine
    unowned let water: WindowWater
    unowned let streaks: RainStreaks
    var params = RainParams()
    var drawFront = true
    var backdrop: Backdrop?
    private let rain = CAMetalLayer()
    private let waterLayer = CAMetalLayer()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(frame: NSRect, layer: RainLayer, screenOrigin: CGPoint, engine: RainEngine, water: WindowWater,
         streaks: RainStreaks) {
        self.layer_ = layer
        self.screenOrigin = screenOrigin
        self.engine = engine
        self.water = water
        self.streaks = streaks
        super.init(frame: frame)
        wantsLayer = true
        for l in layer == .front ? [rain, waterLayer] : [rain] {
            l.device = water.device
            l.pixelFormat = .bgra8Unorm
            l.isOpaque = false
            l.framebufferOnly = true
            l.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            self.layer?.addSublayer(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        rain.frame = bounds
        waterLayer.frame = bounds
        viewDidChangeBackingProperties()
    }

    override func viewDidChangeBackingProperties() {
        let scale = window?.backingScaleFactor ?? 2
        for l in [rain, waterLayer] {
            l.contentsScale = scale
            l.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
    }

    /// Rain and window water both render on the GPU at Retina scale and read the same backdrop.
    func refresh() {
        streaks.render(visibleStreaks(), into: rain, size: bounds.size, backdrop: backdrop?.texture)
        if layer_ == .front { water.render(into: waterLayer, origin: screenOrigin, size: bounds.size, backdrop: backdrop?.texture) }
    }

    /// docs/varsha/physics.md: Rain streaks. Each streak is the path one drop covers during the exposure.
    /// Rain aimed at a window's edge is hidden behind that window and every window in front of it.
    private func visibleStreaks() -> [Streak] {
        let foreground = layer_ == .front
        let sway = RainEngine.windSpeed(params)
        var occluders: [Int: [CGRect]] = [:], above: [CGRect] = []
        for w in water.windows {
            above.append(w.rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y))
            occluders[w.id] = above
        }
        var out: [Streak] = []
        for d in engine.drops where foreground ? (d.window != nil || (d.front && drawFront)) : (!d.front && d.window == nil) {
            let speed = RainEngine.speed(of: d), len = RainEngine.length(of: d)
            let dx = sway * (0.4 + d.near) / speed * len
            let a = CGPoint(x: d.x - dx, y: d.y - len), b = CGPoint(x: d.x, y: d.y)
            let r = RainEngine.radius(of: d, params: params)
            let cover = Float(RainEngine.coverTime(radius: r, speed: hypot(sway * (0.4 + d.near), speed)))
            let hidden = d.window.map { occluders[$0] ?? [] } ?? []
            for s in Occlusion.spans(from: a, to: b, outside: hidden) {
                out.append(Streak(a: point(a, b, s.lowerBound), b: point(a, b, s.upperBound), radius: Float(r), cover: cover))
            }
        }
        if foreground { out += inwardStreaks() }
        return out
    }

    private func point(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> SIMD2<Float> {
        SIMD2(Float(a.x + (b.x - a.x) * t), Float(a.y + (b.y - a.y) * t))
    }

    /// Rain approaching the glass: it looks larger as it nears impact, and streaks over one exposure like any drop.
    private func inwardStreaks() -> [Streak] {
        engine.inward.map { d in
            let speed = max(1, hypot(d.drift.dx, d.drift.dy)), len = speed * RainEngine.exposure
            let r = d.radius * (0.25 + 0.75 * d.progress)
            let head = d.head, tail = CGPoint(x: head.x - d.drift.dx / speed * len, y: head.y - d.drift.dy / speed * len)
            return Streak(a: point(tail, head, 0), b: point(tail, head, 1), radius: Float(r),
                          cover: Float(RainEngine.coverTime(radius: r, speed: speed)))
        }
    }
}
