import AppKit

@main
struct FolderColorChecks {
    static func main() {
        let start = ContinuousClock.now
        func artwork(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                color.setFill()
                rect.fill(using: .copy)
                return true
            }
        }
        func render(_ art: NSImage, _ color: NSColor) -> NSBitmapImageRep {
            FolderArtComposer.icon(with: art, backgroundColor: color, size: 32)
                .representations.first as! NSBitmapImageRep
        }
        let red = render(artwork(.clear), .red)
        let green = render(artwork(.clear), .green)
        let opaqueRed = render(artwork(.blue), .red)
        let opaqueGreen = render(artwork(.blue), .green)
        let mixed = render(artwork(NSColor.blue.withAlphaComponent(0.5)), .red)
        var changed = 0, blended = 0, clear = 0
        for y in 0..<32 {
            for x in 0..<32 {
                let r = red.colorAt(x: x, y: y)!
                let g = green.colorAt(x: x, y: y)!
                precondition(r.alphaComponent == g.alphaComponent, "Color must preserve the folder outline")
                if (8..<24).contains(x) && (12..<24).contains(y) {
                    precondition(opaqueRed.colorAt(x: x, y: y) == opaqueGreen.colorAt(x: x, y: y),
                                 "Opaque artwork inside the folder must not depend on the folder color")
                }
                if r.alphaComponent == 0 { clear += 1 }
                if r.redComponent > g.redComponent && g.greenComponent > r.greenComponent { changed += 1 }
                let m = mixed.colorAt(x: x, y: y)!
                if m.redComponent > 0.1 && m.blueComponent > 0.1 && m.greenComponent < 0.05 { blended += 1 }
            }
        }
        precondition(changed > 100, "Transparent artwork must reveal the selected folder color")
        precondition(blended > 100, "Partial transparency must blend artwork over the selected color")
        precondition(clear > 0, "Pixels outside the folder must stay transparent")
        print("Folder color checks passed in \(start.duration(to: .now)).")
    }
}
