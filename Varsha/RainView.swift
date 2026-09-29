import AppKit
import QuartzCore

enum RainLayer { case back, front }

/// Draws one layer of one screen. Coordinates are top-left, in points.
final class RainView: NSView {
    let layer_: RainLayer
    let screenOrigin: CGPoint   // screen origin in global top-left coordinates
    unowned let engine: RainEngine
    unowned let water: WindowWater
    var params = RainParams()
    var drawFront = true
    private let rain = CALayer()
    private let waterLayer = CAMetalLayer()
    private var rainContext: CGContext?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(frame: NSRect, layer: RainLayer, screenOrigin: CGPoint, engine: RainEngine, water: WindowWater) {
        self.layer_ = layer
        self.screenOrigin = screenOrigin
        self.engine = engine
        self.water = water
        super.init(frame: frame)
        wantsLayer = true
        rain.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        rain.contentsGravity = .resize
        self.layer?.addSublayer(rain)
        guard layer == .front else { return }
        waterLayer.device = water.device
        waterLayer.pixelFormat = .bgra8Unorm
        waterLayer.isOpaque = false
        waterLayer.framebufferOnly = true
        waterLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        self.layer?.addSublayer(waterLayer)
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
        waterLayer.contentsScale = scale
        waterLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// Rain renders at 1x into a sublayer the GPU scales; window water renders on the GPU at Retina scale.
    func refresh() {
        renderRain()
        if layer_ == .front { water.render(into: waterLayer, origin: screenOrigin, size: bounds.size) }
    }

    func renderRain() {
        let w = Int(bounds.width), h = Int(bounds.height)
        if rainContext?.width != w || rainContext?.height != h {
            rainContext = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            rainContext?.translateBy(x: 0, y: CGFloat(h)); rainContext?.scaleBy(x: 1, y: -1)
        }
        guard let ctx = rainContext else { return }
        ctx.clear(bounds)
        ctx.setLineCap(.butt)
        drawRain(ctx)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rain.contents = ctx.makeImage()
        CATransaction.commit()
    }

    /// Streaks fade from tail to head in three butt-capped segments, so joins do not double the alpha.
    /// Rain aimed at a window's edge is hidden behind that window and every window in front of it;
    /// rain striking its glass passes in front of it.
    private func drawRain(_ ctx: CGContext) {
        let foreground = layer_ == .front
        let sway = RainEngine.windSpeed(params)
        var ahead: [Int: [CGRect]] = [:], occluders: [Int: [CGRect]] = [:], above: [CGRect] = []
        for w in water.windows {
            ahead[w.id] = above
            above.append(w.rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y))
            occluders[w.id] = above
        }
        let paths = (0..<9).map { _ in CGMutablePath() }
        for d in engine.drops where foreground ? (d.window != nil || (d.front && drawFront)) : (!d.front && d.window == nil) {
            let len = RainEngine.length(of: d, params: params)
            let dx = sway * (0.4 + d.near) / (520 + 900 * d.near) * len
            let a = CGPoint(x: d.x - dx, y: d.y - len), b = CGPoint(x: d.x, y: d.y)
            let hidden = d.window.map { (d.pane == nil ? occluders : ahead)[$0] ?? [] } ?? []
            let spans = Occlusion.spans(from: a, to: b, outside: hidden)
            let bucket = Int(min(0.999, d.near) * 3)
            for segment in 0..<3 {
                let lo = CGFloat(segment) / 3, hi = CGFloat(segment + 1) / 3
                for s in spans where s.upperBound > lo && s.lowerBound < hi {
                    let t0 = max(lo, s.lowerBound), t1 = min(hi, s.upperBound)
                    paths[bucket * 3 + segment].move(to: CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0))
                    paths[bucket * 3 + segment].addLine(to: CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1))
                }
            }
        }
        for bucket in 0..<3 {
            let alpha = 0.1 + 0.1 * CGFloat(bucket) + (foreground ? 0.04 : 0)
            ctx.setLineWidth(0.45 + 0.35 * CGFloat(bucket))
            for (segment, fade) in [0.2, 0.55, 1].enumerated() {
                ctx.setStrokeColor(CGColor(red: 0.88, green: 0.94, blue: 1, alpha: alpha * fade))
                ctx.addPath(paths[bucket * 3 + segment]); ctx.strokePath()
            }
        }
    }
}
