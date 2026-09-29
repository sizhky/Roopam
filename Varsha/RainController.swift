import AppKit
import Combine

/// Owns the overlay windows (one behind and one in front of app windows, per screen),
/// the simulation state, and the frame timer.
final class RainController {
    static let shared = RainController()

    private struct ScreenOverlay {
        let engine: RainEngine
        let back: NSWindow, front: NSWindow
        let backView: RainView, frontView: RainView
    }

    private let settings = Settings.shared
    private let water = WindowWater(source: WindowWater.bundledSource())
    private var overlays: [ScreenOverlay] = []
    private var timer: Timer?
    private var windows: [WindowFrame] = []
    private var last = CACurrentMediaTime()
    private var bag = Set<AnyCancellable>()

    func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            DispatchQueue.main.async { self?.applySettings() }
        }.store(in: &bag)
        rebuild()
        applySettings()
    }

    private func applySettings() {
        if settings.raining, timer == nil { startTimer() }
        if !settings.raining { timer?.invalidate(); timer = nil; hideAll() } else { showAll() }
        if timer != nil, abs((timer?.timeInterval ?? 0) - frameInterval) > 0.001 { timer?.invalidate(); startTimer() }
    }

    private var frameInterval: TimeInterval {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        switch settings.quality {
        case .smooth: return 1.0 / 60
        case .energySaver: return 1.0 / 30
        case .automatic: return lowPower ? 1.0 / 30 : 1.0 / 60
        }
    }

    private var densityScale: CGFloat {
        switch settings.quality {
        case .smooth: return 1
        case .energySaver: return 0.5
        case .automatic: return ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.5 : 1
        }
    }

    private func startTimer() {
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func frame() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - last)); last = now
        let params = RainParams(intensity: settings.intensity, wind: settings.wind,
                                depth: settings.depth, densityScale: densityScale)
        if settings.windowWater { windows = WindowTracker.frames() }
        water.step(dt: dt, windows: settings.windowWater ? windows : [], params: params)
        for o in overlays {
            let origin = o.backView.screenOrigin
            let water = self.water
            let ids = settings.windowWater ? windows.filter { $0.rect.intersects(CGRect(origin: origin, size: o.engine.size)) }.map(\.id) : []
            o.engine.step(dt: dt, params: params, windowIDs: ids, lands: { a, b, drop in
                guard let id = drop.window,
                      let hit = water.catchRain(from: CGPoint(x: a.x + origin.x, y: a.y + origin.y),
                                                to: CGPoint(x: b.x + origin.x, y: b.y + origin.y), on: id,
                                                volume: 2 + 6 * drop.near,
                                                velocity: CGVector(dx: RainEngine.windSpeed(params) * (0.4 + drop.near),
                                                                   dy: 520 + 900 * drop.near), pane: drop.pane) else { return nil }
                return CGPoint(x: hit.x - origin.x, y: hit.y - origin.y)
            })
            for v in [o.backView, o.frontView] {
                v.params = params
                v.drawFront = settings.frontParticles
                v.refresh()
            }
        }
        water.commit()
    }

    private func showAll() { overlays.forEach { $0.back.orderFrontRegardless(); $0.front.orderFrontRegardless() } }
    private func hideAll() { overlays.forEach { $0.back.orderOut(nil); $0.front.orderOut(nil) } }

    private func rebuild() {
        overlays.forEach { $0.back.orderOut(nil); $0.front.orderOut(nil) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        water.killY = Float(NSScreen.screens.map { primaryHeight - $0.frame.minY }.max() ?? primaryHeight) + 50
        overlays = NSScreen.screens.map { screen in
            let f = screen.frame
            let origin = CGPoint(x: f.minX, y: primaryHeight - f.maxY)
            let engine = RainEngine(size: f.size)
            let bounds = NSRect(origin: .zero, size: f.size)
            let bv = RainView(frame: bounds, layer: .back, screenOrigin: origin, engine: engine, water: water)
            let fv = RainView(frame: bounds, layer: .front, screenOrigin: origin, engine: engine, water: water)
            let back = Self.overlay(screen: screen, view: bv,
                                    level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1))
            let front = Self.overlay(screen: screen, view: fv, level: .floating)
            return ScreenOverlay(engine: engine, back: back, front: front, backView: bv, frontView: fv)
        }
        if settings.raining { showAll() }
    }

    private static func overlay(screen: NSScreen, view: NSView, level: NSWindow.Level) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = view
        w.setFrame(screen.frame, display: false)
        w.level = level
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return w
    }
}

enum WindowTracker {
    /// On-screen app windows of other processes. Uses window bounds only, so no Screen Recording permission.
    static func frames() -> [WindowFrame] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width >= 120, rect.height >= 80 else { return nil }
            return WindowFrame(id: id, rect: rect)
        }
    }
}
