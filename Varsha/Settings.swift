import Combine
import Foundation
import ServiceManagement

enum Quality: String, CaseIterable, Identifiable {
    case automatic = "Automatic", energySaver = "Energy Saver", smooth = "Smooth"
    var id: String { rawValue }
}

/// Persisted user controls. Each change is written to UserDefaults immediately.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let store = UserDefaults.standard

    @Published var raining: Bool { didSet { store.set(raining, forKey: "raining") } }
    @Published var intensity: Double { didSet { store.set(intensity, forKey: "intensity") } }
    @Published var wind: Double { didSet { store.set(wind, forKey: "wind") } }
    @Published var depth: Double { didSet { store.set(depth, forKey: "depth") } }
    @Published var quality: Quality { didSet { store.set(quality.rawValue, forKey: "quality") } }
    @Published var frontParticles: Bool { didSet { store.set(frontParticles, forKey: "frontParticles") } }
    @Published var windowWater: Bool { didSet { store.set(windowWater, forKey: "windowWater") } }
    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
        }
    }

    private init() {
        let d = UserDefaults.standard
        raining = d.object(forKey: "raining") as? Bool ?? true
        intensity = d.object(forKey: "intensity") as? Double ?? 0.5
        wind = d.object(forKey: "wind") as? Double ?? 0.1
        depth = d.object(forKey: "depth") as? Double ?? 0.5
        quality = Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .automatic
        frontParticles = d.object(forKey: "frontParticles") as? Bool ?? true
        windowWater = d.object(forKey: "windowWater") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
