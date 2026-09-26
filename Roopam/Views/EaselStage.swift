import SwiftUI

// Implements docs/folder-icons/design.md "Editor layout".

/// Warm painted canvas behind the preview. Only the stage is painted; the rest of the window stays native.
struct EaselStage<Content: View>: View {
    /// Incrementing this plays one paint splash.
    var splash: Int
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 250)
            .background(EaselBackground().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
            .overlay(PaintSplash(trigger: splash))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

enum Easel {
    static let ink = Color(red: 0.17, green: 0.13, blue: 0.09)
    static let paint: [Color] = [
        Color(red: 1, green: 0.67, blue: 0.18), Color(red: 0.94, green: 0.31, blue: 0.24),
        Color(red: 0.65, green: 0.48, blue: 1), Color(red: 0.15, green: 0.64, blue: 0.95),
        Color(red: 0.3, green: 0.69, blue: 0.42), Color(red: 1, green: 0.89, blue: 0.42),
    ]

    /// Lowercase rounded caption used on the stage, e.g. "now" and "after apply".
    static func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(ink.opacity(0.65))
    }
}

private struct EaselBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.98, green: 0.84, blue: 0.72)
            RadialGradient(colors: [Color(red: 1, green: 0.95, blue: 0.89), .clear],
                           center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.95, green: 0.76, blue: 0.81), .clear],
                           center: UnitPoint(x: 0.9, y: 0.95), startRadius: 0, endRadius: 380)
            // Canvas grain: fixed-seed specks so the texture does not shimmer between redraws.
            Canvas { context, size in
                var seed: UInt64 = 0x5EED
                for _ in 0..<Int(size.width * size.height / 90) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let x = CGFloat(seed >> 40 & 0xFFFF) / 65535 * size.width
                    let y = CGFloat(seed >> 20 & 0xFFFF) / 65535 * size.height
                    context.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(Easel.ink.opacity(0.07)))
                }
            }
        }
    }
}

/// A burst of paint drops from the middle of the stage. Skipped when Reduce Motion is on.
private struct PaintSplash: View {
    var trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drops: [CGSize] = []
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            ForEach(drops.indices, id: \.self) { index in
                Circle()
                    .fill(Easel.paint[index % Easel.paint.count])
                    .frame(width: 12, height: 12)
                    .scaleEffect(1 - progress * 0.7)
                    .offset(x: drops[index].width * progress, y: drops[index].height * progress)
                    .opacity(Double(1 - progress))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            drops = (0..<14).map { _ in CGSize(width: .random(in: -140...140), height: .random(in: -170 ... -20)) }
            progress = 0
            withAnimation(.easeOut(duration: 0.8)) { progress = 1 }
        }
    }
}

/// Capsule tabs in bold rounded type, e.g. image / color / symbol.
struct PillPicker: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(option)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(selection == option ? Color(nsColor: .windowBackgroundColor) : .primary.opacity(0.75))
                        .background(selection == option ? Color.primary : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// Rounded "sticker" for a symbol choice; tilts slightly on hover.
struct StickerButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StickerBody(label: configuration.label, pressed: configuration.isPressed, selected: selected)
    }
}

private struct StickerBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let selected: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .font(.system(size: 19, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : .primary)
            .background(selected ? Color.primary : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .rotationEffect(.degrees(hovering && !reduceMotion ? -5 : 0))
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: hovering)
            .onHover { hovering = $0 }
    }
}
