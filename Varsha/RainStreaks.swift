import Metal
import QuartzCore

/// Mirrors `Streak` in Rain.metal. Points are screen-local, top-left.
struct Streak {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var radius: Float
    var cover: Float
}

/// Mirrors `StreakView` in Rain.metal.
struct StreakView {
    var size: SIMD2<Float>
    var scale: Float
    var reach: Float
    var sky: Float
    var backdrop: UInt32
}

/// docs/varsha/physics.md: Rain streaks. Draws motion-blurred drops on the GPU at the layer's backing scale.
final class RainStreaks {
    /// Radius of the backdrop ring a drop refracts, in points.
    static let reach: Float = 90
    /// Share of a drop's view that falls outside the screen, on the sky.
    static let sky: Float = 0.45

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var rings: [ObjectIdentifier: (buffers: [MTLBuffer?], next: Int)] = [:]

    init(device: MTLDevice, source: String) {
        guard let queue = device.makeCommandQueue() else { preconditionFailure("Varsha needs a Metal queue") }
        self.device = device
        self.queue = queue
        let d = MTLRenderPipelineDescriptor()
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            d.vertexFunction = library.makeFunction(name: "streakVertex")
            d.fragmentFunction = library.makeFunction(name: "streakFragment")
        } catch { preconditionFailure("Rain.metal: \(error)") }
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { pipeline = try device.makeRenderPipelineState(descriptor: d) } catch { preconditionFailure("Rain.metal: \(error)") }
    }

    static func bundledSource() -> String {
        guard let url = Bundle.main.url(forResource: "Rain", withExtension: "metal"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { preconditionFailure("Rain.metal is missing") }
        return text
    }

    private lazy var blank: MTLTexture = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        return device.makeTexture(descriptor: d)!
    }()

    /// Three buffers per layer, used in turn, so the CPU never writes one the GPU is still reading.
    private func buffer(for layer: CAMetalLayer, count: Int) -> MTLBuffer? {
        let key = ObjectIdentifier(layer), length = count * MemoryLayout<Streak>.stride
        var ring = rings[key] ?? (buffers: [nil, nil, nil], next: 0)
        let i = ring.next
        ring.next = (i + 1) % 3
        if (ring.buffers[i]?.length ?? 0) < length {
            ring.buffers[i] = device.makeBuffer(length: length * 2, options: .storageModeShared)
        }
        rings[key] = ring
        return ring.buffers[i]
    }

    func render(_ streaks: [Streak], into layer: CAMetalLayer, size: CGSize, backdrop: MTLTexture?) {
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: pass) {
            if !streaks.isEmpty, let buffer = buffer(for: layer, count: streaks.count) {
                streaks.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                var view = StreakView(size: SIMD2(Float(size.width), Float(size.height)),
                                      scale: Float(drawable.texture.width) / Float(max(1, size.width)),
                                      reach: Self.reach, sky: Self.sky, backdrop: backdrop == nil ? 0 : 1)
                e.setRenderPipelineState(pipeline)
                e.setVertexBuffer(buffer, offset: 0, index: 0)
                e.setVertexBytes(&view, length: MemoryLayout<StreakView>.stride, index: 1)
                e.setFragmentBytes(&view, length: MemoryLayout<StreakView>.stride, index: 0)
                e.setFragmentTexture(backdrop ?? blank, index: 0)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: streaks.count)
            }
            e.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }
}
