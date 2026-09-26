import Foundation
import Combine

/// Manages configuration persistence and provides reactive updates
final class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    @Published private(set) var config: Config

    /// Human-readable description of a problem encountered while loading config.json, if any.
    @Published private(set) var loadDiagnostic: String?

    /// Location the corrupt config was backed up to, if a corrupt-config recovery occurred.
    private(set) var corruptBackupURL: URL?

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Application Support folder names: the current one, and the one used before the Roopam rename.
    static let dataFolderName = "Roopam"
    static let legacyDataFolderName = "FolderIcons"
    static let helperAppName = "SidebarFavoritesIcons.app"

    /// The data folder name the launch-time migration settled on.
    private var dataFolder = ConfigManager.dataFolderName

    /// Base directory for all app data
    var appSupportURL: URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(dataFolder)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The single code-free helper bundle that declares one UTI per favorite.
    /// Not created here - `IconHelperBundle` owns its lifecycle.
    var helperAppURL: URL {
        appSupportURL.appendingPathComponent(Self.helperAppName)
    }

    /// Directory the 0.6.0 build generated one FinderSync-hosting app per favorite into.
    /// Deliberately does NOT create the directory: migration relies on its absence
    /// to know there is nothing to tear down.
    var legacyAppsDirectoryURL: URL {
        appSupportURL.appendingPathComponent("Apps")
    }

    /// Directory the advanced ("both icons") mode generates one Finder Sync
    /// host+appex per favorite into. Not auto-created: its absence means no
    /// advanced favorites exist, and `FinderSyncAppGenerator` creates it on the
    /// first install.
    var advancedAppsDirectoryURL: URL {
        appSupportURL.appendingPathComponent("AdvancedApps")
    }

    /// Directory for custom icon SVGs
    var iconsDirectoryURL: URL {
        let url = appSupportURL.appendingPathComponent("Icons")
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Path to config.json
    var configFileURL: URL {
        appSupportURL.appendingPathComponent("config.json")
    }

    /// Where `config.json` is copied before the 1.0 migration makes its first
    /// change. Named in the consent sheet, so the user knows the file exists
    /// before authorising anything.
    var migrationBackupURL: URL {
        appSupportURL.appendingPathComponent("config.pre-1.0.json")
    }

    /// Copy `config.json` aside before the 1.0 migration mutates anything.
    ///
    /// Returns the backup's location, or `nil` when there is no config.json yet.
    ///
    /// An existing backup is never overwritten: the first one holds the true
    /// pre-1.0 state, and a second run - after a partial migration, or after the
    /// user declined and came back - must not clobber it with an already-migrated
    /// copy. The original is copied, not moved, so the live config keeps working
    /// even if the upgrade is interrupted.
    @discardableResult
    func backupConfigForMigration() throws -> URL? {
        guard fileManager.fileExists(atPath: configFileURL.path) else { return nil }

        let backupURL = migrationBackupURL
        guard !fileManager.fileExists(atPath: backupURL.path) else { return backupURL }

        try fileManager.copyItem(at: configFileURL, to: backupURL)
        return backupURL
    }

    private init() {
        // Initialize with default first
        self.config = Config()
        dataFolder = Self.migrateLegacyDataFolder(fileManager)

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // Load existing config if available; distinguish "no config yet" from "corrupt config"
        // so a decode failure never silently wipes the user's favorites.
        if fileManager.fileExists(atPath: configFileURL.path) {
            do {
                let data = try Data(contentsOf: configFileURL)
                var loaded = try decoder.decode(Config.self, from: data)
                // A favorite's name is always its folder's actual name (see
                // `Favorite.canonicalName`). Configs written by builds that let
                // the name be edited are normalized here; not saved back until
                // something else saves, since the derivation is deterministic.
                for index in loaded.favorites.indices {
                    loaded.favorites[index].name =
                        Favorite.canonicalName(forFolderPath: loaded.favorites[index].folderPath)
                }
                self.config = loaded
            } catch {
                NSLog("ConfigManager: failed to load config.json (\(error.localizedDescription)); backing up and starting fresh")
                let backupURL = configFileURL.deletingLastPathComponent()
                    .appendingPathComponent("config.corrupt-\(Self.backupTimestamp()).json")
                do {
                    try fileManager.moveItem(at: configFileURL, to: backupURL)
                    self.corruptBackupURL = backupURL
                    self.loadDiagnostic = "Your configuration file could not be read and was moved aside. A fresh, empty configuration was created. (\(error.localizedDescription))"
                } catch let moveError {
                    // Couldn't even move the corrupt file aside (e.g. permissions) — leave it in
                    // place and just report the diagnostic so nothing is silently destroyed.
                    NSLog("ConfigManager: failed to back up corrupt config.json: \(moveError.localizedDescription)")
                    self.loadDiagnostic = "Your configuration file could not be read. (\(error.localizedDescription))"
                }
            }
        }
    }

    private static func backupTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    /// Save current configuration to disk
    func save() throws {
        let data = try encoder.encode(config)
        try data.write(to: configFileURL, options: [.atomic])
    }

    /// Add a new favorite
    func addFavorite(_ favorite: Favorite) throws {
        var added = favorite
        added.name = Favorite.canonicalName(forFolderPath: added.folderPath)
        config.favorites.append(added)
        try save()
    }

    /// Update an existing favorite
    func updateFavorite(_ favorite: Favorite) throws {
        guard let index = config.favorites.firstIndex(where: { $0.id == favorite.id }) else {
            throw ConfigError.favoriteNotFound
        }
        var updated = favorite
        updated.name = Favorite.canonicalName(forFolderPath: updated.folderPath)
        updated.markUpdated()
        config.favorites[index] = updated
        try save()
    }

    /// Remove a favorite by ID
    func removeFavorite(id: UUID) throws {
        config.favorites.removeAll { $0.id == id }
        try save()
    }

    /// Get a favorite by ID
    func getFavorite(id: UUID) -> Favorite? {
        config.favorites.first { $0.id == id }
    }

    /// Update settings
    func updateSettings(_ settings: Config.Settings) throws {
        config.settings = settings
        try save()
    }

    /// Returns the full path for a custom icon SVG
    func customIconURL(relativePath: String) -> URL {
        iconsDirectoryURL.appendingPathComponent(relativePath)
    }

    // MARK: - Reconcile bookkeeping
    //
    // These mutators are called by FavoriteSyncCoordinator from background work,
    // so they hop to the main thread for the `@Published` write and persist
    // immediately. None of them call `markUpdated()`: they record what the
    // reconcile already did, and bumping `updatedAt` would retrigger a reconcile.

    /// Record the OSType code allocated for a favorite
    func setOSType(_ code: String, for id: UUID) throws {
        try mutateFavorite(id: id) { $0.osType = code }
    }

    /// Record (or clear) the sidebar row a favorite is bound to
    func bindSidebarItem(id: UUID, itemID: UInt32?, provenance: Favorite.SidebarProvenance) throws {
        try mutateFavorite(id: id) {
            $0.sidebarItemID = itemID
            $0.sidebarProvenance = provenance
        }
    }

    /// Record the helper bundle state produced by the last rebuild
    func setHelperState(digest: String, generation: Int) throws {
        try onMain {
            config.helperDigest = digest
            config.helperGeneration = generation
            try save()
        }
    }

    /// Record the schema version after a migration
    func setConfigVersion(_ version: Int) throws {
        try onMain {
            config.version = version
            try save()
        }
    }

    /// Replace the whole favorites array in one write
    func replaceFavorites(_ favorites: [Favorite]) throws {
        try onMain {
            config.favorites = favorites
            try save()
        }
    }

    private func mutateFavorite(id: UUID, _ body: (inout Favorite) -> Void) throws {
        try onMain {
            guard let index = config.favorites.firstIndex(where: { $0.id == id }) else {
                throw ConfigError.favoriteNotFound
            }
            body(&config.favorites[index])
            try save()
        }
    }

    /// Runs `body` on the main thread. `@Published` writes must happen there, and
    /// callers arrive from detached reconcile work as well as from the UI.
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try body()
        }
        return try DispatchQueue.main.sync(execute: body)
    }

    enum ConfigError: LocalizedError {
        case favoriteNotFound

        var errorDescription: String? {
            switch self {
            case .favoriteNotFound:
                return "Favorite not found in configuration"
            }
        }
    }
}

// Implements docs/folder-icons/design.md "Data folder".
extension ConfigManager {
    /// Moves `FolderIcons` to `Roopam` in Application Support once, when only the legacy folder exists.
    ///
    ///     unregister helper bundles at old paths -> move folder -> register them at new paths
    ///
    /// Launch Services knows the sidebar icon helper and the both-icons hosts by path, so a bare
    /// move would leave stale records and unregistered bundles. A failed move re-registers the old paths
    /// and returns the legacy name, so the app keeps using the existing data.
    static func migrateLegacyDataFolder(_ fileManager: FileManager) -> String {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacy = base.appendingPathComponent(legacyDataFolderName)
        let current = base.appendingPathComponent(dataFolderName)
        let values = try? legacy.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard !fileManager.fileExists(atPath: current.path),
              values?.isDirectory == true, values?.isSymbolicLink != true else { return dataFolderName }

        let bundles = registeredBundlePaths(in: legacy, fileManager)
        let register = { (root: URL) in
            for path in bundles {
                _ = ProcessRunner.run(ProcessRunner.lsregisterPath, ["-f", "-R", "-trusted", root.appendingPathComponent(path).path])
            }
        }
        for path in bundles {
            _ = ProcessRunner.run(ProcessRunner.lsregisterPath, ["-u", legacy.appendingPathComponent(path).path])
        }
        do {
            try fileManager.moveItem(at: legacy, to: current)
            register(current)
            return dataFolderName
        } catch {
            NSLog("Roopam: could not move \(legacy.path) to \(current.path): \(error.localizedDescription)")
            register(legacy)
            return legacyDataFolderName
        }
    }

    /// Paths, relative to the data folder, of bundles this app registers with Launch Services.
    ///
    ///     [helperAppName, "AdvancedApps/SBF-<name>-<id>.app", ...]
    private static func registeredBundlePaths(in root: URL, _ fileManager: FileManager) -> [String] {
        var paths = [helperAppName]
        let hosts = (try? fileManager.contentsOfDirectory(atPath: root.appendingPathComponent("AdvancedApps").path)) ?? []
        paths += hosts.filter { $0.hasSuffix(".app") }.map { "AdvancedApps/\($0)" }
        return paths.filter { fileManager.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
}
