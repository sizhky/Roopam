import AppKit
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit

/// docs/varsha/physics.md: Rendering. A live capture of one display without Varsha's own windows,
/// so the water can refract the pixels behind it. Needs Screen Recording permission.
final class Backdrop: NSObject, SCStreamOutput, SCStreamDelegate {
    private let screen: NSScreen
    private let cache: CVMetalTextureCache
    private let queue = DispatchQueue(label: "varsha.backdrop")
    private let lock = NSLock()
    private var stream: SCStream?
    private var frame: CVMetalTexture?
    private var previous: CVMetalTexture?
    private var stopped = false
    private(set) var fps = 0

    init?(screen: NSScreen, device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.screen = screen
        self.cache = cache
        super.init()
    }

    /// The newest complete frame, or nil before the first frame or without permission.
    var texture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return frame.flatMap(CVMetalTextureGetTexture)
    }

    /// The newest frame and the one before it, so water can tell where the screen is changing.
    var frames: (now: MTLTexture, before: MTLTexture)? {
        lock.lock(); defer { lock.unlock() }
        guard let now = frame.flatMap(CVMetalTextureGetTexture) else { return nil }
        return (now, previous.flatMap(CVMetalTextureGetTexture) ?? now)
    }

    /// `own` holds Varsha's overlay window numbers. They are excluded by ID as well as by app,
    /// because a captured overlay would refract its own water on the next frame.
    private static var asked = false
    /// Last capture state, shown in the menu so a missing refraction has a visible cause.
    static private(set) var status = "Not started"
    private var count = 0
    private static func report(_ s: String) { DispatchQueue.main.async { status = s } }

    func start(fps: Int, own: Set<Int>) {
        self.fps = fps
        guard CGPreflightScreenCaptureAccess() else {
            // A grant takes effect after relaunch, so ask once per launch and fall back to shading.
            if !Self.asked { Self.asked = true; CGRequestScreenCaptureAccess() }
            Self.report("Screen Recording is not granted. Grant it, then quit and reopen Varsha.")
            return
        }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let pixels = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                            height: screen.frame.height * screen.backingScaleFactor)
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let self else { return }
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    return Self.report("No capture display matches screen \(id.map(String.init) ?? "?").")
                }
                let pid = ProcessInfo.processInfo.processIdentifier
                let mine = content.windows.filter { own.contains(Int($0.windowID)) || $0.owningApplication?.processID == pid }
                NSLog("Varsha backdrop: excluding \(mine.count) of \(own.count) overlay windows on display \(display.displayID)")
                let filter = SCContentFilter(display: display, excludingWindows: mine)
                let config = SCStreamConfiguration()
                config.width = Int(pixels.width)
                config.height = Int(pixels.height)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                config.showsCursor = false
                config.queueDepth = 4
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                if !self.adopt(stream) { try? await stream.stopCapture() }
                Self.report("Capture started, waiting for frames.")
            } catch {
                Self.report("Capture failed: \(error.localizedDescription)")
            }
        }
    }

    /// Keeps a started stream unless stop() ran while it was starting.
    private func adopt(_ s: SCStream) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !stopped { stream = s }
        return !stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        let s = stream; stream = nil; frame = nil; previous = nil
        lock.unlock()
        s?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &texture)
        guard let texture else { return Self.report("Frame could not become a Metal texture.") }
        lock.lock(); previous = frame; frame = texture; count += 1; let n = count; lock.unlock()
        if n == 1 || n % 300 == 0 { Self.report("Refracting. \(n) frames received.") }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Self.report("Capture stopped: \(error.localizedDescription)")
        lock.lock(); self.stream = nil; frame = nil; previous = nil; lock.unlock()
    }
}
