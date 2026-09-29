import AppKit

// Implements docs/folder-icons/design.md "Image folder icons".
/// Zoom and pan of the art over the folder. `offset` is a fraction of the folder's width and height; y points up.
struct FolderArtPlacement: Equatable {
    static let zoomRange: ClosedRange<CGFloat> = 1...4
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
}

enum FolderArtComposer {
    private static let layers: [NSImage]? = {
        let coreTypes = Bundle(path: "/System/Library/CoreServices/CoreTypes.bundle")
        let images = ["BackFlap", "PaperSheet", "FrontFlap"].compactMap { coreTypes?.image(forResource: "FolderComponent_\($0)/image_512") }
        return images.count == 3 ? images : nil
    }()

    /// Back flap bounds as fractions of the icon, in AppKit (bottom-up) coordinates.
    private static let folderBox: NSRect? = {
        guard let back = layers?[0] else { return nil }
        let size = 256
        let rep = bitmap(size) { back.draw(in: NSRect(x: 0, y: 0, width: size, height: size)) }
        guard let box = opaqueBounds(rep, size: size) else { return nil }
        return NSRect(x: box.minX / CGFloat(size), y: box.minY / CGFloat(size), width: box.width / CGFloat(size), height: box.height / CGFloat(size))
    }()

    /// Clamps `placement` so the art still covers the whole folder.
    ///
    ///     max |offset.width| = (drawn width - folder width) / 2 / folder width
    static func clamped(_ placement: FolderArtPlacement, artSize: NSSize) -> FolderArtPlacement {
        guard let box = folderBox, artSize.width > 0, artSize.height > 0 else { return FolderArtPlacement() }
        let zoom = min(max(placement.zoom, FolderArtPlacement.zoomRange.lowerBound), FolderArtPlacement.zoomRange.upperBound)
        let scale = max(box.width / artSize.width, box.height / artSize.height) * zoom
        let limitX = (artSize.width * scale - box.width) / 2 / box.width
        let limitY = (artSize.height * scale - box.height) / 2 / box.height
        return FolderArtPlacement(zoom: zoom, offset: CGSize(width: min(max(placement.offset.width, -limitX), limitX),
                                                             height: min(max(placement.offset.height, -limitY), limitY)))
    }

    /// Returns a folder icon whose back and front flaps carry `art`, with the paper sheet between them.
    /// Returns `art` unchanged when macOS does not provide the folder layers.
    ///
    ///     back flap  <- art × back-flap shading
    ///     paper sheet (unchanged)
    ///     front flap <- art × front-flap shading
    static func icon(with art: NSImage, backgroundColor: NSColor? = nil, placement: FolderArtPlacement = FolderArtPlacement(), size: Int = 1024) -> NSImage {
        guard art.isValid, art.size.width > 0, art.size.height > 0,
              let layers, let unitBox = folderBox else { return art }
        let back = layers[0], paper = layers[1], front = layers[2]
        let backRep = bitmap(size) { back.draw(in: NSRect(x: 0, y: 0, width: size, height: size)) }
        let frontRep = bitmap(size) { front.draw(in: NSRect(x: 0, y: 0, width: size, height: size)) }
        guard let reference = meanBrightness(frontRep, size: size) else { return art }
        // Aspect-fill the art into the back flap's bounds so it runs continuously across both flaps.
        let side = CGFloat(size), placement = clamped(placement, artSize: art.size)
        let box = NSRect(x: unitBox.minX * side, y: unitBox.minY * side, width: unitBox.width * side, height: unitBox.height * side)
        let scale = max(box.width / art.size.width, box.height / art.size.height) * placement.zoom
        let width = art.size.width * scale, height = art.size.height * scale
        let center = NSPoint(x: box.midX + placement.offset.width * box.width, y: box.midY + placement.offset.height * box.height)
        let painted = bitmap(size) {
            if let backgroundColor {
                backgroundColor.withAlphaComponent(1).setFill()
                NSRect(x: 0, y: 0, width: size, height: size).fill()
            }
            art.draw(in: NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
        }
        shade(backRep, with: painted, reference: reference, size: size)
        shade(frontRep, with: painted, reference: reference, size: size)
        let output = bitmap(size) {
            let rect = NSRect(x: 0, y: 0, width: size, height: size)
            for layer in [NSImage(cgImage: backRep.cgImage!, size: rect.size), paper, NSImage(cgImage: frontRep.cgImage!, size: rect.size)] {
                layer.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(output)
        return image
    }

    private static func bitmap(_ size: Int, draw: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: size * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Brightness (max channel, un-premultiplied) of pixel `index`, or nil when transparent.
    private static func brightness(_ data: UnsafeMutablePointer<UInt8>, _ index: Int) -> Float? {
        let alpha = Float(data[index * 4 + 3])
        guard alpha > 0 else { return nil }
        return Float(max(data[index * 4], data[index * 4 + 1], data[index * 4 + 2])) / alpha
    }

    private static func meanBrightness(_ rep: NSBitmapImageRep, size: Int) -> Float? {
        guard let data = rep.bitmapData else { return nil }
        var sum: Float = 0, count: Float = 0
        for index in 0..<(size * size) where data[index * 4 + 3] > 127 {
            sum += brightness(data, index) ?? 0; count += 1
        }
        return count > 0 && sum > 0 ? sum / count : nil
    }

    /// Bounds of pixels with alpha above one half, in AppKit (bottom-up) coordinates.
    private static func opaqueBounds(_ rep: NSBitmapImageRep, size: Int) -> NSRect? {
        guard let data = rep.bitmapData else { return nil }
        var minX = size, minY = size, maxX = -1, maxY = -1
        for index in 0..<(size * size) where data[index * 4 + 3] > 127 {
            let x = index % size, y = index / size
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= minX else { return nil }
        return NSRect(x: minX, y: size - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Replaces each flap pixel's color with the art color scaled by the flap's relative brightness.
    /// The cube exaggerates the flap's gradient so the back flap reads darker than the front.
    /// Transparent art keeps the flap's own color.
    private static func shade(_ flap: NSBitmapImageRep, with art: NSBitmapImageRep, reference: Float, size: Int) {
        guard let flapData = flap.bitmapData, let artData = art.bitmapData else { return }
        for index in 0..<(size * size) {
            guard let value = brightness(flapData, index) else { continue }
            let shade = pow(value / reference, 3), alpha = Float(flapData[index * 4 + 3]) / 255
            let artAlpha = Float(artData[index * 4 + 3]) / 255
            for channel in 0..<3 {
                let painted = min(Float(artData[index * 4 + channel]) * shade, 255) * alpha
                flapData[index * 4 + channel] = UInt8(min(painted + Float(flapData[index * 4 + channel]) * (1 - artAlpha), 255))
            }
        }
    }
}
