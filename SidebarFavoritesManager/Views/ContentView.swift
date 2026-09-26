import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct ContentView: View {
    @EnvironmentObject var configManager: ConfigManager
    @EnvironmentObject var coordinator: FavoriteSyncCoordinator
    @Binding var showingAddSheet: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var location = 0
    @State private var rows: [SidebarItem] = []
    @State private var selectedRow: UInt32?
    @State private var folder: URL?
    @State private var mainSymbol = "hammer.fill"
    @State private var sidebarSymbol = "star.fill"
    @State private var folderColor: Color = .blue
    @State private var importedImage: NSImage?
    @State private var sidebarSVG: String?
    @State private var iconScale = 1.0
    @State private var symbolBrowser = false
    @State private var busy = false
    @State private var message = "Choose a location, then select a folder."
    @State private var errorMessage: String?
    @State private var importWarnings: [String] = []
    @State private var confirmRestore = false
    @State private var confirmRestart = false
    @State private var revision = 0
    @State private var helperMessage: String?

    private var row: SidebarItem? { rows.first { $0.itemID == selectedRow } }
    private var target: URL? {
        location == 0 ? folder : row?.path.map { URL(fileURLWithPath: $0) }
    }
    private var selectedFavorite: Favorite? {
        guard let path = row?.path else { return nil }
        return configManager.config.favorites.first { $0.pathMatchCandidates.contains(path) }
    }
    private var canApply: Bool {
        guard let target, !busy else { return false }
        guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        return location == 0
            ? importedImage != nil || NSImage(systemSymbolName: mainSymbol, accessibilityDescription: nil) != nil
            : sidebarSVG != nil || NSImage(systemSymbolName: sidebarSymbol, accessibilityDescription: nil) != nil
    }
    private var history: IconHistory? {
        _ = revision
        guard let target else { return nil }
        return try? IconHistory.load(for: target, sidebar: location == 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                selectionPane.frame(width: 265)
                Divider()
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await refreshFavorites()
            if let diagnostic = configManager.loadDiagnostic { errorMessage = diagnostic }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !busy { Task { await refreshFavorites() } }
        }
        .onChange(of: selectedRow) { _, _ in loadSidebarDraft() }
        .sheet(isPresented: $symbolBrowser) {
            SymbolBrowserSheet(currentSymbol: location == 0 ? mainSymbol : sidebarSymbol) { symbol in
                if location == 0 { mainSymbol = symbol; importedImage = nil }
                else { sidebarSymbol = symbol; sidebarSVG = nil; importWarnings = [] }
            }
        }
        .alert("Could not complete the change", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Restore the original icon for this location?", isPresented: $confirmRestore) {
            Button("Restore Original") { run { try await restore(original: true) } }
        } message: { Text("The other location keeps its icon. You can undo this change.") }
        .confirmationDialog("Restart Finder to display the updated icons?", isPresented: $confirmRestart) {
            Button("Restart Finder") { run { await coordinator.restartFinderAndWait() } }
        } message: { Text("Finder windows may close and reopen. Finish any Finder operations first.") }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Folder Icons").font(.title2.weight(.semibold))
                Text("Customize each Finder location independently.").foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Edit location", selection: $location) {
                Text("Finder main area").tag(0)
                Text("Finder Favorites sidebar").tag(1)
            }
            .pickerStyle(.radioGroup)
            .fixedSize()
            .disabled(busy)
        }.padding(24)
    }

    private var selectionPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(location == 0 ? "FOLDER" : "EXISTING FAVORITES")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if location == 0 {
                Button(action: chooseFolder) { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                    .controlSize(.large)
                VStack(spacing: 14) {
                    Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(folder?.lastPathComponent ?? "Drop a folder here")
                        .font(.headline).lineLimit(2)
                    Text(folder?.path ?? "Or choose any accessible folder on your Mac.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                .dropDestination(for: URL.self) { urls, _ in
                    guard !busy, let url = urls.first, urls.count == 1 else { return false }
                    selectFolder(url)
                    return true
                }
                Spacer()
            } else {
                Button { Task { await refreshFavorites() } } label: {
                    Label("Refresh Favorites", systemImage: "arrow.clockwise")
                }
                if rows.isEmpty {
                    Text("No Favorites found. Add folders in Finder, then refresh this list.")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(selection: $selectedRow) {
                        ForEach(rows, id: \.itemID) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.path == nil ? "questionmark.folder" : "folder")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.displayName.isEmpty ? "Unavailable Favorite" : item.displayName)
                                        .lineLimit(1)
                                    if item.path == nil {
                                        Text("Location unavailable").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                            .tag(item.itemID)
                            .help(item.path ?? "Finder could not resolve this Favorite.")
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
        }
        .padding(20)
        .disabled(busy)
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let target {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(target.lastPathComponent).font(.title2.weight(.semibold))
                        Text(target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    preview
                    Divider()
                    HStack {
                        Text(location == 0 ? "Folder artwork" : "Sidebar glyph").font(.headline)
                        Spacer()
                        Button("Browse Symbols…") { symbolBrowser = true }
                    }
                    symbolChoices
                    HStack {
                        TextField("SF Symbol name", text: Binding(
                            get: { location == 0 ? mainSymbol : sidebarSymbol },
                            set: { value in
                                if location == 0 { mainSymbol = value; importedImage = nil }
                                else { sidebarSymbol = value; sidebarSVG = nil; importWarnings = [] }
                            }
                        )).textFieldStyle(.roundedBorder)
                        Button(location == 0 ? "Import Image…" : "Import SVG…", action: importArtwork)
                    }
                    if location == 0 {
                        ColorPicker("Folder color", selection: $folderColor, supportsOpacity: false)
                            .disabled(importedImage != nil)
                        if importedImage != nil {
                            Button("Use folder and symbol") { importedImage = nil }
                        }
                        if configManager.config.favorites.contains(where: { $0.enabled && $0.pathMatchCandidates.contains(target.path) }) {
                            Text("Apply also sets up this folder’s Finder extension to preserve its existing sidebar glyph.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Extension Settings") { FinderSyncAppGenerator.openExtensionsSettings() }
                        }
                    } else {
                        Text("Finder draws sidebar glyphs as monochrome silhouettes.")
                            .font(.caption).foregroundStyle(.secondary)
                        if sidebarSVG != nil {
                            HStack {
                                Text("Symbol size")
                                Slider(value: $iconScale, in: Favorite.iconScaleRange)
                                Text(iconScale, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                            }
                        }
                        if IconAuthority.detect(atPath: target.path) != nil || selectedFavorite?.mode == .advanced {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Keep both icons", systemImage: "square.on.square")
                                Text("Apply sets up a Finder extension for this folder to preserve both icons.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Open Extension Settings") { FinderSyncAppGenerator.openExtensionsSettings() }
                            }
                        }
                    }
                    ForEach(importWarnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: location == 0 ? "folder.badge.gearshape" : "sidebar.left")
                            .font(.system(size: 56)).foregroundStyle(.secondary)
                        Text(location == 0 ? "Choose a folder to begin" : "Select an existing Favorite")
                            .font(.title3.weight(.medium))
                        Text("Preview your changes before applying them.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 380)
                }
            }.padding(28)
        }.disabled(busy)
    }

    private var symbolChoices: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
            ForEach(["folder.fill", "hammer.fill", "star.fill", "briefcase.fill", "house.fill", "heart.fill", "book.fill", "camera.fill",
                     "music.note", "photo.fill", "doc.fill", "archivebox.fill", "cloud.fill", "terminal.fill", "leaf.fill", "shippingbox.fill"], id: \.self) { symbol in
                Button {
                    if location == 0 { mainSymbol = symbol; importedImage = nil }
                    else { sidebarSymbol = symbol; sidebarSVG = nil; importWarnings = [] }
                } label: {
                    Image(systemName: symbol).font(.system(size: 19)).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint((location == 0 ? mainSymbol : sidebarSymbol) == symbol ? .accentColor : .secondary)
                .help(symbol)
                .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
            }
        }
    }

    private var preview: some View {
        HStack(spacing: 32) {
            VStack(spacing: 10) {
                Text("Current").font(.caption).foregroundStyle(.secondary)
                if location == 0, let target {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: target.path))
                        .resizable().scaledToFit().frame(width: 82, height: 82).id(revision)
                } else if let favorite = selectedFavorite {
                    if let svg = favorite.customSVGPath, favorite.iconType == .custom {
                        SVGThumbnailView(url: configManager.customIconURL(relativePath: svg), size: 46,
                                         iconScale: CGFloat(favorite.effectiveIconScale))
                    } else {
                        Image(systemName: favorite.iconValue).font(.system(size: 46)).frame(height: 82)
                    }
                } else {
                    Image(systemName: "sidebar.left").font(.system(size: 34)).frame(height: 64)
                    Button("View in Finder") {
                        if let target { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                    }.font(.caption)
                }
            }
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            VStack(spacing: 10) {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                if location == 0 {
                    Image(nsImage: renderedMainIcon()).resizable().scaledToFit().frame(width: 100, height: 100)
                    Text(target?.lastPathComponent ?? "Folder").font(.caption)
                } else {
                    sidebarGlyph(size: 46).frame(height: 64)
                    HStack(spacing: 8) {
                        sidebarGlyph(size: 16)
                        Text(row?.displayName ?? "Favorite").font(.system(size: 13)).lineLimit(1)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func sidebarGlyph(size: CGFloat) -> some View {
        if let sidebarSVG {
            SVGThumbnailView(url: configManager.customIconURL(relativePath: sidebarSVG), size: size, iconScale: CGFloat(iconScale))
        } else {
            Image(systemName: sidebarSymbol).font(.system(size: size))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let helperMessage {
                Text(helperMessage).font(.caption).foregroundStyle(.orange)
            }
            if !coordinator.warnings.isEmpty {
                Text(coordinator.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                if busy { ProgressView().controlSize(.small) }
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                if coordinator.needsFinderRestart {
                    Button("Restart Finder…") { confirmRestart = true }.disabled(busy)
                }
                Button("Undo") { run { try await restore(original: false) } }
                    .disabled(busy || history?.previous == nil)
                Button("Restore Original…") { confirmRestore = true }
                    .disabled(busy || history == nil)
                Button("Apply") { run { try await apply() } }
                    .buttonStyle(.borderedProminent).disabled(!canApply)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(20)
    }

    private func selectFolder(_ url: URL) {
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            errorMessage = "Choose an accessible folder."; return
        }
        folder = url.standardizedFileURL
        message = "Changes apply only to Finder’s main area."
        revision += 1
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { selectFolder(url) }
    }

    private func loadSidebarDraft() {
        let favorite = selectedFavorite
        sidebarSymbol = favorite?.iconValue ?? "folder.fill"
        sidebarSVG = favorite?.customSVGPath
        iconScale = favorite?.effectiveIconScale ?? 1
        importWarnings = []
        helperMessage = nil
        message = "Changes apply only to the selected existing Favorite."
        revision += 1
    }

    @MainActor private func refreshFavorites() async {
        do {
            let snapshot = try await Task.detached { try SidebarItemManager.shared.snapshot() }.value
            rows = snapshot
            if let selectedRow, !snapshot.contains(where: { $0.itemID == selectedRow }) {
                self.selectedRow = nil
                message = "That Favorite was removed from Finder."
            }
        } catch {
            rows = []
            errorMessage = error.localizedDescription
        }
    }

    private func importArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = location == 0 ? [.png, .jpeg, .tiff, .icns] : [.svg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if location == 0 {
            guard let image = NSImage(contentsOf: url), image.isValid else {
                errorMessage = "This image could not be read."; return
            }
            importedImage = image
        } else {
            let validation = SymbolValidator.validate(at: url)
            guard validation.isValid else {
                errorMessage = validation.errors.map(\.localizedDescription).joined(separator: "\n"); return
            }
            do {
                sidebarSVG = try SymbolValidator.importSymbol(from: url, named: "icon-\(UUID().uuidString.lowercased())")
                importWarnings = validation.warnings
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func renderedMainIcon() -> NSImage {
        if let importedImage { return importedImage }
        let color = NSColor(folderColor)
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { _ in
            let rect = NSRect(x: 20, y: 64, width: 472, height: 366)
            color.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: NSRect(x: 20, y: 340, width: 205, height: 112), xRadius: 24, yRadius: 24).fill()
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 170, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            NSImage(systemSymbolName: mainSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)?
                .draw(in: NSRect(x: 161, y: 152, width: 190, height: 190))
            return true
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; revision += 1 }
            do { try await action() }
            catch { errorMessage = error.localizedDescription; message = "Change incomplete. Review the error before retrying." }
        }
    }

    @MainActor private func apply() async throws {
        guard let target else { throw IconHistory.failure("Select a folder first.") }
        let sidebar = location == 1
        let snapshot = try capture(target, sidebar: sidebar)
        var record = try IconHistory.load(for: target, sidebar: sidebar)
            ?? IconHistory(original: snapshot, previous: nil)
        record.previous = snapshot
        try record.save(for: target, sidebar: sidebar)
        if sidebar {
            let live = try requireLiveRow(target)
            var favorite = selectedFavorite ?? Favorite(name: live.displayName, folderPath: target.path)
            favorite.sidebarItemID = live.itemID
            favorite.sidebarProvenance = .adopted
            favorite.iconType = sidebarSVG == nil ? .sfSymbol : .custom
            favorite.iconValue = sidebarSVG.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? sidebarSymbol
            favorite.customSVGPath = sidebarSVG
            favorite.iconScale = iconScale
            favorite.enabled = true
            favorite.locationsOnly = false
            if IconAuthority.detect(atPath: target.path) != nil { favorite.mode = .advanced }
            try await saveFavorite(favorite)
            try await verifySidebar(favorite, target: target)
        } else {
            guard NSWorkspace.shared.setIcon(renderedMainIcon(), forFile: target.path, options: []) else {
                throw IconHistory.failure("macOS could not change this folder’s icon. Check folder permissions.")
            }
            if var favorite = configManager.config.favorites.first(where: { $0.pathMatchCandidates.contains(target.path) }), favorite.enabled {
                favorite.mode = .advanced
                try await saveFavorite(favorite)
                try await verifySidebar(favorite, target: target)
            }
        }
        message = "Icon saved. Check its appearance in Finder."
        await refreshFavorites()
    }

    private func requireLiveRow(_ target: URL) throws -> SidebarItem {
        guard let selectedRow,
              let live = try SidebarItemManager.shared.item(withID: selectedRow),
              live.matches(anyOf: [target.path]) else {
            throw IconHistory.failure("This Favorite is no longer available. Refresh the list; no Favorite was added.")
        }
        return live
    }

    private func capture(_ url: URL, sidebar: Bool) throws -> IconSnapshot {
        if sidebar {
            let live = try requireLiveRow(url)
            return IconSnapshot(image: nil, osType: live.osType, favorite: selectedFavorite)
        }
        let hasCustomIcon = IconAuthority.detect(atPath: url.path) != nil
        let image = hasCustomIcon ? NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation : nil
        if hasCustomIcon && image == nil { throw IconHistory.failure("The original icon could not be backed up.") }
        return IconSnapshot(image: image, osType: nil, favorite: nil)
    }

    @MainActor private func saveFavorite(_ proposed: Favorite) async throws {
        var favorite = proposed
        if IconAuthority.detect(atPath: favorite.expandedFolderPath) != nil { favorite.mode = .advanced }
        let previous = configManager.getFavorite(id: favorite.id)
        if previous != nil { try configManager.updateFavorite(favorite) }
        else { try configManager.addFavorite(favorite) }
        if let previous { await coordinator.favoriteUpdated(favorite, previous: previous) }
        else { await coordinator.favoriteAdded(favorite) }
        if let failure = coordinator.lastError { throw IconHistory.failure(failure) }
    }

    @MainActor private func verifySidebar(_ favorite: Favorite, target: URL) async throws {
        guard let saved = configManager.getFavorite(id: favorite.id), let code = saved.osType,
              let live = try SidebarItemManager.shared.item(matching: [target.path]), live.osType == code else {
            throw IconHistory.failure("The sidebar icon was not applied. Review the messages and retry.")
        }
        if saved.mode == .advanced {
            let statuses = await FinderSyncAppGenerator.shared.helperStatuses(for: [saved])
            switch statuses[saved.id] {
            case .enabled: helperMessage = "Finder extension enabled for this folder."
            default: helperMessage = "Enable the folder’s Finder extension in System Settings to keep both icons."
            }
        }
    }

    @MainActor private func restore(original: Bool) async throws {
        guard let target, var record = try IconHistory.load(for: target, sidebar: location == 1),
              let snapshot = original ? record.original : record.previous else { return }
        let current = try capture(target, sidebar: location == 1)
        record.previous = current
        try record.save(for: target, sidebar: location == 1)
        if location == 0 {
            let image = snapshot.image.flatMap(NSImage.init(data:))
            if snapshot.image != nil && image == nil { throw IconHistory.failure("The saved icon could not be read.") }
            guard NSWorkspace.shared.setIcon(image, forFile: target.path, options: []) else {
                throw IconHistory.failure("macOS could not restore this icon. Check folder permissions.")
            }
        } else if let favorite = snapshot.favorite {
            try await saveFavorite(favorite)
            try await verifySidebar(favorite, target: target)
        } else {
            let live = try requireLiveRow(target)
            if let favorite = selectedFavorite {
                await coordinator.favoriteRemoved(favorite)
                if let failure = coordinator.lastError { throw IconHistory.failure(failure) }
                try configManager.removeFavorite(id: favorite.id)
            }
            if let code = snapshot.osType {
                try SidebarItemManager.shared.setOSType(code, itemID: live.itemID)
            } else {
                try SidebarItemManager.shared.clearOSType(url: target, displayName: live.displayName)
            }
            guard let restored = try SidebarItemManager.shared.item(withID: live.itemID), restored.osType == snapshot.osType else {
                throw IconHistory.failure("Finder did not confirm the restored sidebar icon. Retry Restore Original.")
            }
            helperMessage = nil
        }
        await refreshFavorites()
        if location == 1 { loadSidebarDraft() }
        message = original ? "Original icon restored. Check Finder." : "Previous icon restored. Check Finder."
    }
}

// Implements docs/folder-icons/design.md: recoverable, independent icon changes.
struct IconSnapshot: Codable {
    var image: Data?
    var osType: String?
    var favorite: Favorite?
}

struct IconHistory: Codable {
    var original: IconSnapshot?
    var previous: IconSnapshot?

    static func failure(_ message: String) -> NSError {
        NSError(domain: "FolderIcons", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func file(for url: URL, sidebar: Bool) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let device = (attributes?[.systemNumber] as? NSNumber)?.stringValue ?? "unknown"
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.stringValue ?? "unknown"
        let key = (sidebar ? "sidebar:" : "main:") + url.standardizedFileURL.path + ":" + device + ":" + inode
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return ConfigManager.shared.appSupportURL.appendingPathComponent("History").appendingPathComponent(hash + ".json")
    }

    static func load(for url: URL, sidebar: Bool) throws -> IconHistory? {
        let path = file(for: url, sidebar: sidebar)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }

    func save(for url: URL, sidebar: Bool) throws {
        let path = Self.file(for: url, sidebar: sidebar)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: path, options: .atomic)
    }
}
