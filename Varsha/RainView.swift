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
    var backdrop: Backdrop?
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
        if layer_ == .front { water.render(into: waterLayer, origin: screenOrigin, size: bounds.size, backdrop: backdrop?.texture) }
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

    /// Streaks fade from tail to head in butt-capped segments, so joins do not double the alpha.
    /// Rain aimed at a window's edge is hidden behind that window and every window in front of it.
    private func drawRain(_ ctx: CGContext) {
        let foreground = layer_ == .front
        let sway = RainEngine.windSpeed(params)
        var occluders: [Int: [CGRect]] = [:], above: [CGRect] = []
        for w in water.windows {
            above.append(w.rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y))
            occluders[w.id] = above
        }
        let fades: [CGFloat] = [0.15, 0.35, 0.6, 0.85, 1], n = fades.count
        let paths = (0..<(4 * n)).map { _ in CGMutablePath() }
        for d in engine.drops where foreground ? (d.window != nil || (d.front && drawFront)) : (!d.front && d.window == nil) {
            let len = RainEngine.length(of: d, params: params)
            let dx = sway * (0.4 + d.near) / (520 + 900 * d.near) * len
            let a = CGPoint(x: d.x - dx, y: d.y - len), b = CGPoint(x: d.x, y: d.y)
            let hidden = d.window.map { occluders[$0] ?? [] } ?? []
            let spans = Occlusion.spans(from: a, to: b, outside: hidden)
            let bucket = Int(min(0.999, d.near) * 4)
            for segment in 0..<n {
                let lo = CGFloat(segment) / CGFloat(n), hi = CGFloat(segment + 1) / CGFloat(n)
                for s in spans where s.upperBound > lo && s.lowerBound < hi {
                    let t0 = max(lo, s.lowerBound), t1 = min(hi, s.upperBound)
                    paths[bucket * n + segment].move(to: CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0))
                    paths[bucket * n + segment].addLine(to: CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1))
                }
            }
        }
        // Far to near. The nearest streaks are wide and faint, as rain out of focus close to the camera is.
        for (bucket, (base, width)) in [(0.1, 0.45), (0.18, 0.8), (0.24, 1.4), (0.14, 3.0)].enumerated() {
            let alpha = base + (foreground ? 0.04 : 0)
            for (segment, fade) in fades.enumerated() {
                let path = paths[bucket * n + segment]
                rim(ctx, path, width: width, alpha: alpha * fade)
                ctx.setLineWidth(width)
                ctx.setStrokeColor(CGColor(red: 0.88, green: 0.94, blue: 1, alpha: alpha * fade))
                ctx.addPath(path); ctx.strokePath()
            }
        }
        if foreground { drawInward(ctx) }
    }

    /// docs/varsha/physics.md: Rendering. A centred dark rim, as the drop composite darkens a bead's steep edge.
    private func rim(_ ctx: CGContext, _ path: CGPath, width: CGFloat, alpha: CGFloat) {
        ctx.setLineWidth(width + 0.8)
        ctx.setStrokeColor(CGColor(red: 0.05, green: 0.08, blue: 0.12, alpha: alpha * 0.45))
        ctx.addPath(path); ctx.strokePath()
    }

    /// Rain approaching the glass: a short streak shaded as the bead it becomes, with a dark rim, a clear body,
    /// and a glint on the side facing the composite light (upper left).
    private func drawInward(_ ctx: CGContext) {
        for d in engine.inward {
            let t = d.progress, speed = max(1, hypot(d.drift.dx, d.drift.dy))
            let head = d.head, len = (6 + 10 * t) * min(1, speed / 600)
            let tail = CGPoint(x: head.x - d.drift.dx / speed * len, y: head.y - d.drift.dy / speed * len)
            let path = CGMutablePath()
            path.move(to: tail); path.addLine(to: head)
            let width = d.radius * (0.25 + 0.45 * t), alpha = 0.1 + 0.4 * t
            ctx.setLineCap(.round)
            rim(ctx, path, width: width, alpha: alpha)
            ctx.setLineWidth(width)
            ctx.setStrokeColor(CGColor(red: 0.85, green: 0.93, blue: 1, alpha: alpha * 0.35))
            ctx.addPath(path); ctx.strokePath()
            ctx.setLineCap(.butt)
            let g = width * 0.22, glint = CGPoint(x: head.x - width * 0.15, y: head.y - width * 0.26)
            ctx.setFillColor(CGColor(gray: 1, alpha: min(1, alpha * 1.6)))
            ctx.fillEllipse(in: CGRect(x: glint.x - g, y: glint.y - g, width: 2 * g, height: 2 * g))
        }
    }
}
