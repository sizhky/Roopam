import CoreGraphics
import Foundation
import Metal
import QuartzCore

struct WindowFrame: Equatable {
    var id: Int
    var rect: CGRect   // global, origin top-left

    /// First point where segment a→b enters the rounded outline, with the outward normal there.
    /// Rain moving down meets the top; wind-driven rain can also meet a side.
    func edgeHit(from a: CGPoint, to b: CGPoint) -> (point: CGPoint, normal: CGVector)? {
        let dx = b.x - a.x, dy = b.y - a.y
        let R = min(Glass.cornerRadius, rect.width / 2, rect.height / 2)
        var best: (t: CGFloat, point: CGPoint, normal: CGVector)?
        func consider(_ t: CGFloat, _ n: CGVector) {
            guard t >= 0, t <= 1, t < (best?.t ?? .infinity) else { return }
            best = (t, CGPoint(x: a.x + dx * t, y: a.y + dy * t), n)
        }
        let walls: [(CGVector, CGFloat)] = [(CGVector(dx: 0, dy: -1), rect.minY), (CGVector(dx: 0, dy: 1), rect.maxY),
                                            (CGVector(dx: -1, dy: 0), rect.minX), (CGVector(dx: 1, dy: 0), rect.maxX)]
        for (n, wall) in walls {
            let vertical = n.dx != 0
            let along = vertical ? dx : dy, start = vertical ? a.x : a.y
            guard along * (vertical ? n.dx : n.dy) < 0 else { continue }
            let t = (wall - start) / along
            let cross = vertical ? a.y + dy * t : a.x + dx * t
            let lo = (vertical ? rect.minY : rect.minX) + R, hi = (vertical ? rect.maxY : rect.maxX) - R
            if cross >= lo, cross <= hi { consider(t, n) }
        }
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] as [(CGFloat, CGFloat)] {
            let c = CGPoint(x: sx < 0 ? rect.minX + R : rect.maxX - R, y: sy < 0 ? rect.minY + R : rect.maxY - R)
            let ox = a.x - c.x, oy = a.y - c.y
            let aa = dx * dx + dy * dy, bb = 2 * (ox * dx + oy * dy), cc = ox * ox + oy * oy - R * R
            let disc = bb * bb - 4 * aa * cc
            guard aa > 0, disc >= 0 else { continue }
            let t = (-bb - sqrt(disc)) / (2 * aa)
            let px = a.x + dx * t - c.x, py = a.y + dy * t - c.y
            if px * sx >= 0, py * sy >= 0 { consider(t, CGVector(dx: px / R, dy: py / R)) }
        }
        return best.map { ($0.point, $0.normal) }
    }
}

enum Glass {
    static let cornerRadius: CGFloat = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 10

    /// How far a rounded window edge sits inside its bounding rect at local x.
    static func inset(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let R = min(cornerRadius, width / 2)
        let dx = x < R ? R - x : (x > width - R ? x - (width - R) : 0)
        return R - sqrt(max(0, R * R - dx * dx))
    }
}

/// Mirrors `Particle` in Fluid.metal.
struct Particle {
    static let dead: Int32 = 0, side: Int32 = 1, face: Int32 = 2, detached: Int32 = 3
    var x: SIMD2<Float>
    var v: SIMD2<Float>
    var p: SIMD2<Float>
    var window: Int32
    var mode: Int32
}

/// Mirrors `Params` in Fluid.metal.
struct FluidParams {
    var gravity: SIMD2<Float>
    var wind: SIMD2<Float>
    var dt: Float
    var h: Float
    var rho0: Float
    var radius: Float
    var adhesion: Float
    var viscosity: Float
    var airDrag: Float
    var contactRange: Float
    var pin: Float
    var edgePin: Float
    var edgeDrag: Float
    var substrateDrag: Float
    var evaporation: Float
    var corner: Float
    var scorrK: Float
    var scorrW: Float
    var bond: Float
    var bondRest: Float
    var sleepSpeed: Float
    var sleepTime: Float
    var frameDt: Float
    var restEvaporation: Float
    var maxSpeed: Float
    var killY: Float
    var count: UInt32
    var windowCount: UInt32
    var tableMask: UInt32
    var seed: UInt32
}

/// Mirrors `Window` in Fluid.metal.
struct FluidWindow {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var velocity: SIMD2<Float>
    var id: Int32
    var rank: Int32
}

/// Mirrors `View` in Fluid.metal.
struct FluidView {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var radius: Float
    var corner: Float
    var windowCount: UInt32
    var threshold: Float
}

/// Mirrors `Lens` in Fluid.metal. Depth and shift are in drawable pixels; a zero depth turns refraction off.
struct FluidLens {
    var depth: Float
    var eta: Float
    var shift: Float
    var change: Float
}

/// docs/varsha/physics.md: Constants. Units are points, seconds, and particles of unit mass.
enum Fluid {
    static let spacing: Float = 0.8
    static let h: Float = 1.6
    static let radius: Float = 0.4
    static let capacity = 98_304
    static let tableSize = 1 << 18
    static let bucket = 16
    static var substeps = 8
    static let iterations = 3
    static let maxWindows = 56
    static var gravity: Float = 1800
    static var adhesion: Float = 6000
    static var viscosity: Float = 0.08
    static var airDrag: Float = 1.8
    static let contactRange: Float = 1.5 * radius
    static var pin: Float = 2500      // glass pane face
    static var edgePin: Float = 4000  // window frame edge
    static var edgeDrag: Float = 15
    static var substrateDrag: Float = 18
    static let evaporation: Float = 0.03
    static let impactRetention: CGFloat = 0.1
    static var scorrK: Float = 0.02
    static var bond: Float = 0.6
    static var bondRest: Float = 1.8 * spacing
    static let sleepSpeed: Float = 2
    static let sleepTime: Float = 0.5
    static let maxSpeed: Float = 3000
    static let splatRadius: Float = 2.6 * spacing
    static let threshold: Float = 0.8
    static let lensDepth: Float = 6       // points of water above the glass at a bead's crown
    static let waterIndex: Float = 1.33
    static let liveShift: Float = 2       // points of refraction offset at which the captured image fully replaces the live one
    static let staleChange: Float = 0.12  // colour change between captures at which the captured image fully gives way

    static func poly6(_ r2: Float) -> Float {
        let d = h * h - r2
        return d > 0 ? 4 / (Float.pi * pow(h, 8)) * d * d * d : 0
    }

    /// Density of a hexagonal lattice at rest spacing, the state a drop is spawned in.
    static let rho0: Float = {
        var sum: Float = 0
        let rowHeight = spacing * sqrt(3) / 2
        for row in -4...4 {
            for col in -4...4 {
                let x = Float(col) * spacing + (row & 1 == 0 ? 0 : spacing / 2), y = Float(row) * rowHeight
                sum += poly6(x * x + y * y)
            }
        }
        return sum
    }()

    /// Hexagonal lattice offsets filling a disc of the given radius.
    static func disc(radius: CGFloat) -> [CGPoint] {
        let d = CGFloat(spacing), rowHeight = d * sqrt(3) / 2
        let rows = Int(ceil(radius / rowHeight)), cols = Int(ceil(radius / d)) + 1
        var out: [CGPoint] = []
        for row in -rows...rows {
            for col in -cols...cols {
                let p = CGPoint(x: CGFloat(col) * d + (row & 1 == 0 ? 0 : d / 2), y: CGFloat(row) * rowHeight)
                if hypot(p.x, p.y) <= max(radius, d * 0.3) { out.append(p) }
            }
        }
        return out
    }
}

/// Water on and around app windows, simulated as one particle fluid on the GPU.
/// Each particle belongs to one window: it lives either in that window's edge plane, where the window is a solid,
/// or on its glass face, where the glass pins the contact line.
final class WindowWater {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]
    private let splat: MTLRenderPipelineState
    private let compositing: MTLRenderPipelineState
    private let particles, accel, lambda, surface, idle, dp, cellCoord, counts, cells: MTLBuffer
    private var free: [Int32] = []
    private var highWater = 0
    private var spawns: [Particle] = []
    private var pending: MTLCommandBuffer?
    private var last: MTLCommandBuffer?
    private var fields: [ObjectIdentifier: MTLTexture] = [:]
    private var frames: [Int: CGRect] = [:]
    private var velocities: [Int: CGVector] = [:]
    private var gpuWindows: [FluidWindow] = []
    private var seed: UInt32 = 1
    private(set) var windows: [WindowFrame] = []
    /// Screen frames, global top-left. Each is a pane of glass in front of every window.
    var screens: [CGRect] = []

    static func screenGlass(_ index: Int) -> Int { -1000 - index }
    private(set) var time: CGFloat = 0
    let evaporation: Float
    var killY: Float = 100_000

    init(source: String, evaporation: Float = Fluid.evaporation) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            preconditionFailure("Varsha needs a Metal device")
        }
        self.device = device
        self.queue = queue
        self.evaporation = evaporation
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: source, options: nil) } catch { preconditionFailure("Fluid.metal: \(error)") }
        func compute(_ name: String) -> MTLComputePipelineState {
            do { return try device.makeComputePipelineState(function: library.makeFunction(name: name)!) }
            catch { preconditionFailure("\(name): \(error)") }
        }
        pipelines = Dictionary(uniqueKeysWithValues: ["predict", "clearGrid", "insert", "solveLambda", "solveDelta",
                                                       "applyDelta", "finish", "forces", "wake"].map { ($0, compute($0)) })
        let s = MTLRenderPipelineDescriptor()
        s.vertexFunction = library.makeFunction(name: "splatVertex")
        s.fragmentFunction = library.makeFunction(name: "splatFragment")
        s.colorAttachments[0].pixelFormat = .r16Float
        s.colorAttachments[0].isBlendingEnabled = true
        s.colorAttachments[0].rgbBlendOperation = .add
        s.colorAttachments[0].sourceRGBBlendFactor = .one
        s.colorAttachments[0].destinationRGBBlendFactor = .one
        let c = MTLRenderPipelineDescriptor()
        c.vertexFunction = library.makeFunction(name: "fullscreen")
        c.fragmentFunction = library.makeFunction(name: "composite")
        c.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            splat = try device.makeRenderPipelineState(descriptor: s)
            compositing = try device.makeRenderPipelineState(descriptor: c)
        } catch { preconditionFailure("Fluid.metal render: \(error)") }
        let n = Fluid.capacity
        func buffer(_ length: Int, _ options: MTLResourceOptions = .storageModePrivate) -> MTLBuffer {
            device.makeBuffer(length: length, options: options)!
        }
        particles = buffer(n * MemoryLayout<Particle>.stride, .storageModeShared)
        memset(particles.contents(), 0, particles.length)
        accel = buffer(n * 8, .storageModeShared)
        memset(accel.contents(), 0, accel.length)
        lambda = buffer(n * 4)
        surface = buffer(n * 4, .storageModeShared)
        memset(surface.contents(), 0, surface.length)
        idle = buffer(n * 4, .storageModeShared)
        memset(idle.contents(), 0, idle.length)
        dp = buffer(n * 8)
        cellCoord = buffer(n * 8)
        counts = buffer(Fluid.tableSize * 4)
        cells = buffer(Fluid.tableSize * Fluid.bucket * 4)
        free = (0..<Int32(n)).reversed().map { $0 }
    }

    static func bundledSource() -> String {
        guard let url = Bundle.main.url(forResource: "Fluid", withExtension: "metal"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { preconditionFailure("Fluid.metal is missing") }
        return text
    }

    func rect(of id: Int) -> CGRect? { frames[id] }

    func visible(_ p: CGPoint, on id: Int) -> Bool {
        for w in windows {
            if w.id == id { return true }
            guard w.rect.contains(p) else { continue }
            let x = p.x - w.rect.minX
            let inset = Glass.inset(x, width: w.rect.width)
            if p.y >= w.rect.minY + inset, p.y <= w.rect.maxY - inset { return false }
        }
        return true
    }

    /// Falling rain strikes the first window edge it meets, top or side, and enters the fluid just outside it.
    @discardableResult
    func catchRain(from a: CGPoint, to b: CGPoint, on id: Int? = nil, volume: CGFloat = 2,
                   velocity: CGVector = CGVector(dx: 0, dy: 700)) -> CGPoint? {
        let hits = windows.compactMap { w -> (WindowFrame, CGPoint, CGFloat)? in
            guard id == nil || w.id == id, let hit = w.edgeHit(from: a, to: b),
                  visible(CGPoint(x: hit.point.x - hit.normal.dx * 0.1, y: hit.point.y - hit.normal.dy * 0.1), on: w.id) else { return nil }
            return (w, hit.point, hypot(hit.point.x - a.x, hit.point.y - a.y))
        }
        guard let hit = hits.min(by: { $0.2 < $1.2 }) else { return nil }
        let speed = max(1, hypot(velocity.dx, velocity.dy)), r = cbrt(volume)
        let center = CGPoint(x: hit.1.x - velocity.dx / speed * (r + CGFloat(Fluid.radius)),
                             y: hit.1.y - velocity.dy / speed * (r + CGFloat(Fluid.radius)))
        spawn(at: center, radius: r, velocity: velocity, window: hit.0.id, mode: Particle.side)
        return hit.1
    }

    /// Rain moving toward the viewer lands on the frontmost glass under its impact point:
    /// an app window's face where one covers the point, otherwise the screen's own glass.
    func catchInward(at p: CGPoint, radius: CGFloat, velocity: CGVector) {
        let k = Fluid.impactRetention
        let v = CGVector(dx: velocity.dx * k, dy: velocity.dy * k)
        if let w = windows.first(where: { covers($0, p) }) {
            let wall = velocities[w.id] ?? .zero
            spawn(at: p, radius: radius, velocity: CGVector(dx: wall.dx + v.dx, dy: wall.dy + v.dy), window: w.id, mode: Particle.face)
        } else if let s = screens.firstIndex(where: { $0.contains(p) }) {
            spawn(at: p, radius: radius, velocity: v, window: Self.screenGlass(s), mode: Particle.face)
        }
    }

    private func covers(_ w: WindowFrame, _ p: CGPoint) -> Bool {
        guard w.rect.contains(p) else { return false }
        let inset = Glass.inset(p.x - w.rect.minX, width: w.rect.width)
        return p.y >= w.rect.minY + inset && p.y <= w.rect.maxY - inset
    }

    /// Queues a drop as a disc of particles at rest spacing; it enters the simulation on the next step.
    func spawn(at c: CGPoint, radius: CGFloat, velocity: CGVector, window: Int, mode: Int32) {
        let v = SIMD2<Float>(Float(velocity.dx), Float(velocity.dy))
        for o in Fluid.disc(radius: radius) {
            let x = SIMD2<Float>(Float(c.x + o.x), Float(c.y + o.y))
            spawns.append(Particle(x: x, v: v, p: x, window: Int32(window), mode: mode))
        }
    }

    /// GPU seconds spent by the last completed command buffer.
    var gpuTime: Double { last.map { $0.gpuEndTime - $0.gpuStartTime } ?? 0 }

    /// Share of live particles that are asleep, after the last committed step.
    func sleepingShare() -> Double {
        _ = snapshot()
        let ps = particles.contents().bindMemory(to: Particle.self, capacity: Fluid.capacity)
        let still = idle.contents().bindMemory(to: Float.self, capacity: Fluid.capacity)
        let live = (0..<highWater).filter { ps[$0].mode != Particle.dead }
        return live.isEmpty ? 0 : Double(live.filter { still[$0] >= Fluid.sleepTime }.count) / Double(live.count)
    }

    /// Live particles after the last committed step finished on the GPU.
    func snapshot() -> [Particle] {
        wait()
        let ps = particles.contents().bindMemory(to: Particle.self, capacity: Fluid.capacity)
        return (0..<highWater).map { ps[$0] }.filter { $0.mode != Particle.dead }
    }

    /// Encodes one frame of simulation. If the GPU is still busy with the previous frame, the frame is skipped
    /// rather than blocking the caller; queued drops enter on the next frame that runs.
    func step(dt: CGFloat, windows new: [WindowFrame], params p: RainParams) {
        guard dt > 0 else { return }
        commit()
        if let last, last.status != .completed, last.status != .error { return }
        time += dt
        let old = frames
        windows = new
        frames = Dictionary(new.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        velocities = Dictionary(new.map { w -> (Int, CGVector) in
            let previous = old[w.id] ?? w.rect
            return (w.id, CGVector(dx: (w.rect.minX - previous.minX) / dt, dy: (w.rect.minY - previous.minY) / dt))
        }, uniquingKeysWith: { a, _ in a })
        admitSpawns()
        guard let cb = queue.makeCommandBuffer() else { return }
        let sub = Float(dt) / Float(Fluid.substeps)
        for k in 0..<Fluid.substeps {
            let t = CGFloat(k + 1) / CGFloat(Fluid.substeps)
            let ws = new.prefix(Fluid.maxWindows).enumerated().map { rank, w -> FluidWindow in
                let previous = old[w.id] ?? w.rect
                let v = velocities[w.id] ?? .zero
                return FluidWindow(origin: SIMD2(Float(previous.minX + (w.rect.minX - previous.minX) * t),
                                                 Float(previous.minY + (w.rect.minY - previous.minY) * t)),
                                   size: SIMD2(Float(w.rect.width), Float(w.rect.height)),
                                   velocity: SIMD2(Float(v.dx), Float(v.dy)), id: Int32(w.id), rank: Int32(rank))
            }
            let glass = screens.enumerated().map { i, r in
                FluidWindow(origin: SIMD2(Float(r.minX), Float(r.minY)), size: SIMD2(Float(r.width), Float(r.height)),
                            velocity: .zero, id: Int32(Self.screenGlass(i)), rank: -1)
            }
            gpuWindows = ws + glass
            encodeSubstep(cb, windows: gpuWindows, params: parameters(dt: sub, wind: p), first: k == 0)
        }
        pending = cb
    }

    /// Commits pending work and blocks until the GPU finishes it. For checks; the app never waits.
    func wait() {
        commit()
        last?.waitUntilCompleted()
    }

    func commit() {
        guard let cb = pending else { return }
        cb.commit()
        last = cb
        pending = nil
    }

    private var framesSinceSort = 0

    /// Reorders live particles by grid row, then column, and drops dead slots, so neighbour reads on the GPU
    /// touch nearby memory. LSD radix sort, two passes of 11 bits. Runs while the GPU is idle.
    private func sortByCell() {
        let ps = particles.contents().bindMemory(to: Particle.self, capacity: Fluid.capacity)
        let forces = accel.contents().bindMemory(to: SIMD2<Float>.self, capacity: Fluid.capacity)
        let exposed = surface.contents().bindMemory(to: Float.self, capacity: Fluid.capacity)
        let still = idle.contents().bindMemory(to: Float.self, capacity: Fluid.capacity)
        var order: [Int32] = [], keys: [UInt32] = []
        order.reserveCapacity(highWater); keys.reserveCapacity(highWater)
        for i in 0..<highWater where ps[i].mode != Particle.dead {
            let cx = UInt32(clamping: Int(floor(ps[i].x.x / Fluid.h)) + 1024), cy = UInt32(clamping: Int(floor(ps[i].x.y / Fluid.h)) + 1024)
            order.append(Int32(i)); keys.append((min(cy, 2047) << 11) | min(cx, 2047))
        }
        for shift in [0, 11] as [UInt32] {
            var count = [Int](repeating: 0, count: 2049)
            for k in keys { count[Int((k >> shift) & 2047) + 1] += 1 }
            for b in 1..<2049 { count[b] += count[b - 1] }
            var nextOrder = order, nextKeys = keys
            for (k, o) in zip(keys, order) {
                let b = Int((k >> shift) & 2047)
                nextOrder[count[b]] = o; nextKeys[count[b]] = k; count[b] += 1
            }
            order = nextOrder; keys = nextKeys
        }
        let p0 = order.map { ps[Int($0)] }, a0 = order.map { forces[Int($0)] }
        let s0 = order.map { exposed[Int($0)] }, i0 = order.map { still[Int($0)] }
        for (n, _) in order.enumerated() { ps[n] = p0[n]; forces[n] = a0[n]; exposed[n] = s0[n]; still[n] = i0[n] }
        for n in order.count..<highWater { ps[n].mode = Particle.dead }
        highWater = order.count
    }

    private func admitSpawns() {
        framesSinceSort += 1
        if framesSinceSort >= 30 { sortByCell(); framesSinceSort = 0 }
        let ps = particles.contents().bindMemory(to: Particle.self, capacity: Fluid.capacity)
        var top = 0
        free.removeAll(keepingCapacity: true)
        for i in stride(from: highWater - 1, through: 0, by: -1) where ps[i].mode == Particle.dead { free.append(Int32(i)) }
        for i in (0..<highWater).reversed() where ps[i].mode != Particle.dead { top = i + 1; break }
        free = free.filter { Int($0) < top }
        let forces = accel.contents().bindMemory(to: SIMD2<Float>.self, capacity: Fluid.capacity)
        let exposed = surface.contents().bindMemory(to: Float.self, capacity: Fluid.capacity)
        let still = idle.contents().bindMemory(to: Float.self, capacity: Fluid.capacity)
        var next = top
        for s in spawns {
            let slot: Int
            if let reused = free.popLast() { slot = Int(reused) }
            else if next < Fluid.capacity { slot = next; next += 1 }
            else { break }
            ps[slot] = s
            forces[slot] = .zero
            exposed[slot] = 1
            still[slot] = 0
        }
        highWater = max(top, next)
        spawns.removeAll(keepingCapacity: true)
    }

    /// docs/varsha/physics.md: Particle budget. Above 60% occupancy still (sleeping) water dries faster, up to 31x
    /// when full, so arriving rain keeps entering the fluid and old still droplets give way to moving water.
    private var budgetedEvaporation: Float {
        let occupancy = Float(highWater) / Float(Fluid.capacity)
        return evaporation * (1 + 30 * max(0, occupancy - 0.6) / 0.4)
    }

    private func parameters(dt: Float, wind p: RainParams) -> FluidParams {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return FluidParams(gravity: SIMD2(0, Fluid.gravity), wind: SIMD2(Float(RainEngine.windSpeed(p)), 0), dt: dt,
                           h: Fluid.h, rho0: Fluid.rho0, radius: Fluid.radius,
                           adhesion: Fluid.adhesion, viscosity: Fluid.viscosity, airDrag: Fluid.airDrag,
                           contactRange: Fluid.contactRange,
                           pin: Fluid.pin, edgePin: Fluid.edgePin, edgeDrag: Fluid.edgeDrag, substrateDrag: Fluid.substrateDrag, evaporation: evaporation,
                           corner: Float(Glass.cornerRadius), scorrK: Fluid.scorrK,
                           scorrW: Fluid.poly6(pow(0.2 * Fluid.h, 2)), bond: Fluid.bond, bondRest: Fluid.bondRest,
                           sleepSpeed: Fluid.sleepSpeed, sleepTime: Fluid.sleepTime,
                           frameDt: dt * Float(Fluid.substeps), restEvaporation: budgetedEvaporation, maxSpeed: Fluid.maxSpeed, killY: killY,
                           count: UInt32(highWater), windowCount: UInt32(min(windows.count, Fluid.maxWindows)),
                           tableMask: UInt32(Fluid.tableSize - 1), seed: seed)
    }

    private func encodeSubstep(_ cb: MTLCommandBuffer, windows ws: [FluidWindow], params P: FluidParams, first: Bool) {
        guard highWater > 0, let e = cb.makeComputeCommandEncoder() else { return }
        var P = P
        P.windowCount = UInt32(ws.count)
        let windowBytes = max(1, ws.count) * MemoryLayout<FluidWindow>.stride
        var ws = ws.isEmpty ? [FluidWindow(origin: .zero, size: .zero, velocity: .zero, id: -1, rank: 0)] : ws
        func run(_ name: String, _ buffers: [MTLBuffer], windows: Bool = false, threads: Int? = nil) {
            e.setComputePipelineState(pipelines[name]!)
            for (index, b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: index) }
            var index = buffers.count
            if windows { e.setBytes(&ws, length: windowBytes, index: index); index += 1 }
            if threads == nil { e.setBytes(&P, length: MemoryLayout<FluidParams>.stride, index: index) }
            let n = threads ?? highWater
            e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: min(256, pipelines[name]!.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        func grid() {
            run("clearGrid", [counts], threads: Fluid.tableSize)
            run("insert", [particles, counts, cells, cellCoord])
        }
        if first { run("wake", [particles, counts, cells, cellCoord, idle, surface], windows: true) }
        run("predict", [particles, accel, idle])
        grid()
        for _ in 0..<Fluid.iterations {
            run("solveLambda", [particles, counts, cells, cellCoord, lambda, surface, idle], windows: true)
            run("solveDelta", [particles, counts, cells, cellCoord, lambda, dp, idle])
            run("applyDelta", [particles, dp, idle], windows: true)
        }
        run("finish", [particles, surface, idle], windows: true)
        grid()
        run("forces", [particles, counts, cells, cellCoord, surface, accel, idle], windows: true)
        e.endEncoding()
    }

    /// Draws the water visible on one screen into its layer, inside the pending step's command buffer.
    /// With a backdrop, the water refracts it; without one, the water is shaded only.
    /// `previous` is the capture before `backdrop`; where they differ, the capture is stale and the live screen shows.
    func render(into layer: CAMetalLayer, origin: CGPoint, size: CGSize, backdrop: MTLTexture? = nil, previous: MTLTexture? = nil) {
        guard let drawable = layer.nextDrawable() else { return }
        let cb = encode(into: drawable.texture, key: ObjectIdentifier(layer), origin: origin, size: size,
                        backdrop: backdrop, previous: previous)
        cb?.present(drawable)
    }

    /// Offscreen render of the current state, for checks. The texture must be .bgra8Unorm and render-target capable.
    func render(into texture: MTLTexture, origin: CGPoint, size: CGSize, backdrop: MTLTexture? = nil, previous: MTLTexture? = nil) {
        _ = encode(into: texture, key: ObjectIdentifier(texture), origin: origin, size: size, backdrop: backdrop, previous: previous)
        wait()
    }

    private lazy var blank: MTLTexture = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        return device.makeTexture(descriptor: d)!
    }()

    private func encode(into target: MTLTexture, key: ObjectIdentifier, origin: CGPoint, size: CGSize,
                        backdrop: MTLTexture?, previous: MTLTexture?) -> MTLCommandBuffer? {
        guard let cb = pending ?? queue.makeCommandBuffer() else { return nil }
        if pending == nil { pending = cb }
        if fields[key]?.width != target.width || fields[key]?.height != target.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: target.width,
                                                             height: target.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            fields[key] = device.makeTexture(descriptor: d)
        }
        guard let field = fields[key] else { return cb }
        var view = FluidView(origin: SIMD2(Float(origin.x), Float(origin.y)), size: SIMD2(Float(size.width), Float(size.height)),
                             radius: Fluid.splatRadius, corner: Float(Glass.cornerRadius),
                             windowCount: UInt32(gpuWindows.count), threshold: Fluid.threshold)
        var ws = gpuWindows.isEmpty ? [FluidWindow(origin: .zero, size: .zero, velocity: .zero, id: -1, rank: 0)] : gpuWindows
        let windowBytes = ws.count * MemoryLayout<FluidWindow>.stride
        let first = MTLRenderPassDescriptor()
        first.colorAttachments[0].texture = field
        first.colorAttachments[0].loadAction = .clear
        first.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        first.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: first) {
            if highWater > 0 {
                e.setRenderPipelineState(splat)
                e.setVertexBuffer(particles, offset: 0, index: 0)
                e.setVertexBytes(&view, length: MemoryLayout<FluidView>.stride, index: 1)
                e.setVertexBytes(&ws, length: windowBytes, index: 2)
                e.setFragmentBytes(&view, length: MemoryLayout<FluidView>.stride, index: 0)
                e.setFragmentBytes(&ws, length: windowBytes, index: 1)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: highWater)
            }
            e.endEncoding()
        }
        let second = MTLRenderPassDescriptor()
        second.colorAttachments[0].texture = target
        second.colorAttachments[0].loadAction = .clear
        second.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        second.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: second) {
            e.setRenderPipelineState(compositing)
            let scale = Float(target.width) / Float(max(1, size.width))
            var lens = FluidLens(depth: backdrop == nil ? 0 : Fluid.lensDepth * scale, eta: 1 / Fluid.waterIndex,
                                 shift: Fluid.liveShift * scale, change: Fluid.staleChange)
            e.setFragmentTexture(field, index: 0)
            e.setFragmentTexture(backdrop ?? blank, index: 1)
            e.setFragmentTexture(previous ?? backdrop ?? blank, index: 2)
            e.setFragmentBytes(&view, length: MemoryLayout<FluidView>.stride, index: 0)
            e.setFragmentBytes(&lens, length: MemoryLayout<FluidLens>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        return cb
    }
}
