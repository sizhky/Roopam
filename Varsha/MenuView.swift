import SwiftUI

struct MenuView: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("varsha").font(.system(.title3, design: .serif)).italic()
                Spacer()
                Toggle(s.raining ? "Raining" : "Paused", isOn: $s.raining).toggleStyle(.switch)
            }
            Picker("Quality", selection: $s.quality) {
                ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            slider("Rain intensity", $s.intensity, "Drizzle", "Downpour")
            slider("Depth", $s.depth, "Flat", "Deep")
            slider("Wind", $s.wind, "Left", "Right", range: -1...1)
            Divider()
            toggle("Near-camera particles", "A sparse, faint layer that passes in front of windows.", $s.frontParticles)
            toggle("Water on windows", "Drops gather on title bars and run down the sides.", $s.windowWater)
            toggle("Refraction", s.refraction ? Backdrop.status : "Water bends the screen behind it.", $s.refraction)
                .disabled(!s.windowWater)
            toggle("Launch at login", "Registers Varsha with the system login items.", $s.launchAtLogin)
            HStack { Spacer(); Button("Quit") { NSApp.terminate(nil) } }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ lo: String, _ hi: String,
                        range: ClosedRange<Double> = 0...1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Slider(value: value, in: range)
            HStack { Text(lo); Spacer(); Text(hi) }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.toggleStyle(.switch)
    }
}
