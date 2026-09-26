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
    @State private var currentSidebarIcons: [UInt32: NSImage] = [:]
    @State private var refreshToken = UUID()
    @State private var selectedRow: UInt32?
    @State private var folder: URL?
    @State private var mainSymbol = "hammer.fill"
    @State private var sidebarSymbol = "star.fill"
    @State private var folderColor: Color = .blue
    @State private var importedImage: NSImage?
    @State private var importedIsIcon = false
    @State private var artPlacement = FolderArtPlacement()
    @State private var gestureStart: FolderArtPlacement?
    @State private var sidebarSVG: String?
    @State private var iconScale = 1.0
    @State private var symbolBrowser = false
    @State private var busy = false
    @State private var message = "Pick a folder or a Favorite in the sidebar."
    @State private var errorMessage: String?
    @State private var importWarnings: [String] = []
    @State private var confirmRestore = false
    @State private var confirmRestart = false
    @State private var revision = 0
    @State private var helperMessage: String?
    @State private var folderTab = "symbol"
    @State private var splashCount = 0
    @State private var bounce = false
    /// Folders edited here, newest first, one path per line.
    @AppStorage("recentFolders") private var recentFolders = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let folderHint = "The new icon shows wherever this folder appears. Its sidebar glyph does not change."
    private static let favoriteHint = "Only this Favorite’s glyph in Finder’s sidebar changes."

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
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem {
                Button { Task { await refreshFavorites() } } label: {
                    Label("Refresh Favorites", systemImage: "arrow.clockwise")
                }
                .help("Reload Finder’s Favorites")
                .disabled(busy)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
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
        .confirmationDialog("Restore the original icon?", isPresented: $confirmRestore) {
            Button("Restore Original") { run { try await restore(original: true) } }
        } message: {
            Text(location == 0 ? "The folder’s sidebar glyph stays as it is. You can undo this change."
                               : "The folder’s own icon stays as it is. You can undo this change.")
        }
        .confirmationDialog("Restart Finder to display the updated icons?", isPresented: $confirmRestart) {
            Button("Restart Finder") { run { await coordinator.restartFinderAndWait() } }
        } message: { Text("Finder windows may close and reopen. Finish any Finder operations first.") }
    }

    // MARK: Sidebar

    /// Sidebar row identity: a folder edited in Finder windows, or a Finder Favorite.
    private enum Pick: Hashable {
        case folder(String)
        case favorite(UInt32)
    }

    private var pick: Binding<Pick?> {
        Binding(
            get: { location == 0 ? folder.map { .folder($0.path) } : selectedRow.map { .favorite($0) } },
            set: { value in
                switch value {
                case .folder(let path)?:
                    location = 0
                    selectFolder(URL(fileURLWithPath: path))
                case .favorite(let id)?:
                    location = 1
                    selectedRow = id
                    loadSidebarDraft()
                case nil:
                    break
                }
            }
        )
    }

    private var recentFolderPaths: [String] {
        var paths = recentFolders.split(separator: "\n").map(String.init)
        if let folder, !paths.contains(folder.path) { paths.insert(folder.path, at: 0) }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private var sidebar: some View {
        List(selection: pick) {
            Section("Folders") {
                Button(action: chooseFolder) {
                    Label("Choose a Folder…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                ForEach(recentFolderPaths, id: \.self) { path in
                    Label {
                        Text(FileManager.default.displayName(atPath: path)).lineLimit(1)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
                            .id("\(path)-\(revision)")
                    }
                    .help(path)
                    .tag(Pick.folder(path))
                }
            }
            Section("Favorites") {
                if rows.isEmpty {
                    Text("No Favorites yet. Add a folder to Finder’s sidebar, then refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.itemID) { item in
                    Label {
                        Text(item.displayName.isEmpty ? "Unavailable Favorite" : item.displayName).lineLimit(1)
                    } icon: {
                        currentSidebarIcon(item, size: 16)
                    }
                    .help(item.path ?? "Finder could not find this Favorite’s folder.")
                    .tag(Pick.favorite(item.itemID))
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy, let url = urls.first, urls.count == 1 else { return false }
            location = 0
            selectFolder(url)
            return true
        }
        .disabled(busy)
    }

    // MARK: Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let target {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(location == 0 ? target.lastPathComponent : (row?.displayName ?? target.lastPathComponent))
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .lineLimit(1)
                        Text(target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    stage
                    if location == 0 { folderControls(target) } else { glyphControls(target) }
                    ForEach(importWarnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                } else {
                    emptyStage
                }
            }.padding(26)
        }.disabled(busy)
    }

    private var emptyStage: some View {
        EaselStage(splash: 0) {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus").font(.system(size: 44, weight: .semibold))
                Text("Drop a folder here").font(.system(size: 22, weight: .black, design: .rounded))
                Text("or pick a folder or Favorite in the sidebar").font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Easel.ink)
            .frame(maxWidth: .infinity, minHeight: 320)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy, let url = urls.first, urls.count == 1 else { return false }
            location = 0
            selectFolder(url)
            return true
        }
    }

    private var stage: some View {
        EaselStage(splash: splashCount) {
            HStack(spacing: 40) {
                VStack(spacing: 8) {
                    Group {
                        if location == 0, let target {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: target.path))
                                .resizable().scaledToFit().frame(width: 96, height: 96).id(revision)
                        } else if let row {
                            currentSidebarIcon(row, size: 44).foregroundStyle(Easel.ink).frame(height: 96)
                        }
                    }
                    Easel.label("now")
                }
                Text("→").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(Easel.ink.opacity(0.45))
                VStack(spacing: 8) {
                    Group {
                        if location == 0 {
                            if let importedImage, !importedIsIcon {
                                artCanvas(importedImage)
                            } else {
                                Image(nsImage: renderedMainIcon(size: 256)).resizable().scaledToFit().frame(width: 150, height: 150)
                            }
                        } else {
                            finderRowPreview
                        }
                    }
                    .scaleEffect(bounce ? 1.08 : 1)
                    .rotationEffect(.degrees(bounce ? -2 : 0))
                    Easel.label(location == 0 && importedImage != nil && !importedIsIcon ? "after apply · drag to move" : "after apply")
                }
            }
        }
    }

    /// The selected Favorite and its neighbours, drawn at Finder's sidebar size.
    private var finderRowPreview: some View {
        let index = rows.firstIndex { $0.itemID == selectedRow } ?? 0
        let nearby = rows.indices.filter { abs($0 - index) <= 1 }.map { rows[$0] }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Favorites").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 8).padding(.bottom, 2)
            ForEach(nearby, id: \.itemID) { item in
                HStack(spacing: 8) {
                    Group {
                        if item.itemID == selectedRow { sidebarGlyph(size: 15) } else { currentSidebarIcon(item, size: 15) }
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                    Text(item.displayName).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(item.itemID == selectedRow ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .frame(width: 230)
        .background(Color(white: 0.12).opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func folderControls(_ target: URL) -> some View {
        PillPicker(selection: $folderTab, options: ["image", "color", "symbol"])
        switch folderTab {
        case "image":
            HStack(spacing: 12) {
                Button("Import Image…", action: importArtwork)
                Text(importedImage == nil ? "PNG, JPEG or TIFF. It is painted onto the folder." : "Drag the preview to move the image.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            if let importedImage, !importedIsIcon { zoomControls(importedImage) }
        case "color":
            HStack(alignment: .top, spacing: 14) {
                ForEach(Self.swatches, id: \.name) { swatch in
                    Button {
                        folderColor = swatch.color; importedImage = nil
                    } label: {
                        VStack(spacing: 5) {
                            Circle().fill(swatch.color).frame(width: 34, height: 34)
                                .overlay(Circle().strokeBorder(.primary.opacity(folderColor == swatch.color ? 0.9 : 0.1), lineWidth: folderColor == swatch.color ? 3 : 1))
                            Text(swatch.name).font(.system(size: 11, weight: .heavy, design: .rounded))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                }
                ColorPicker("Custom", selection: Binding(get: { folderColor }, set: { folderColor = $0; importedImage = nil }), supportsOpacity: false)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
            }
            Button("surprise me", action: surprise)
                .font(.system(size: 14, weight: .black, design: .rounded))
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.orange)
        default:
            stickers
            symbolField
        }
        if configManager.config.favorites.contains(where: { $0.enabled && $0.pathMatchCandidates.contains(target.path) }) {
            Text("This folder is also a Favorite. Apply sets up its Finder extension so the sidebar glyph stays.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Extension Settings") { FinderSyncAppGenerator.openExtensionsSettings() }
        }
    }

    @ViewBuilder private func glyphControls(_ target: URL) -> some View {
        PillPicker(selection: Binding(get: { sidebarSVG == nil ? "symbol" : "svg" },
                                      set: { if $0 == "svg" { importArtwork() } else { sidebarSVG = nil; importWarnings = [] } }),
                   options: ["symbol", "svg"])
        if sidebarSVG == nil {
            stickers
            symbolField
        } else {
            HStack {
                Text("Symbol size")
                Slider(value: $iconScale, in: Favorite.iconScaleRange)
                Text(iconScale, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
            Button("Import Another SVG…", action: importArtwork)
        }
        Text("Finder draws sidebar glyphs as one-color silhouettes.").font(.caption).foregroundStyle(.secondary)
        if IconAuthority.detect(atPath: target.path) != nil || selectedFavorite?.mode == .advanced {
            VStack(alignment: .leading, spacing: 6) {
                Label("Keep both icons", systemImage: "square.on.square")
                Text("This folder has its own icon. Apply sets up a Finder extension so the folder keeps it and the sidebar shows this glyph.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Extension Settings") { FinderSyncAppGenerator.openExtensionsSettings() }
            }
        }
    }

    private var symbolField: some View {
        HStack {
            TextField("SF Symbol name", text: Binding(
                get: { location == 0 ? mainSymbol : sidebarSymbol },
                set: { value in
                    if location == 0 { mainSymbol = value; importedImage = nil }
                    else { sidebarSymbol = value; sidebarSVG = nil; importWarnings = [] }
                }
            )).textFieldStyle(.roundedBorder)
            Button("Browse Symbols…") { symbolBrowser = true }
        }
    }

    private static let swatches: [(name: String, color: Color)] = [
        ("Lagoon", Color(red: 0.15, green: 0.64, blue: 0.95)), ("Mango", Color(red: 1, green: 0.67, blue: 0.18)),
        ("Lavender", Color(red: 0.65, green: 0.48, blue: 1)), ("Chili", Color(red: 0.94, green: 0.31, blue: 0.24)),
        ("Moss", Color(red: 0.3, green: 0.69, blue: 0.42)), ("Ink", Color(red: 0.17, green: 0.17, blue: 0.21)),
    ]

    private static let stickerSymbols = ["folder.fill", "hammer.fill", "star.fill", "briefcase.fill", "house.fill", "heart.fill", "book.fill", "camera.fill",
                                         "music.note", "photo.fill", "doc.fill", "archivebox.fill", "cloud.fill", "terminal.fill", "leaf.fill", "shippingbox.fill"]

    private func surprise() {
        folderColor = Self.swatches.randomElement()!.color
        mainSymbol = Self.stickerSymbols.randomElement()!
        importedImage = nil
    }

    private var stickers: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8), spacing: 10) {
            ForEach(Self.stickerSymbols, id: \.self) { symbol in
                let selected = (location == 0 ? (importedImage == nil && mainSymbol == symbol) : (sidebarSVG == nil && sidebarSymbol == symbol))
                Button {
                    if location == 0 { mainSymbol = symbol; importedImage = nil }
                    else { sidebarSymbol = symbol; sidebarSVG = nil; importWarnings = [] }
                } label: {
                    Image(systemName: symbol)
                }
                .buttonStyle(StickerButtonStyle(selected: selected))
                .help(symbol)
                .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
            }
        }
    }

    @ViewBuilder private func currentSidebarIcon(_ item: SidebarItem, size: CGFloat) -> some View {
        if let image = currentSidebarIcons[item.itemID] {
            Image(nsImage: image).resizable().renderingMode(.template)
                .scaledToFit().frame(width: size, height: size).id("\(item.itemID)-\(revision)")
        } else {
            Image(systemName: "questionmark.folder").font(.system(size: size))
                .frame(width: size, height: size).help("Finder's current icon could not be read.")
        }
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
                Button { run { try await apply() } } label: {
                    Text("apply").font(.system(size: 13, weight: .black, design: .rounded)).padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(!canApply)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(20)
    }

    private func selectFolder(_ url: URL) {
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            errorMessage = "Choose an accessible folder."; return
        }
        let standardized = url.standardizedFileURL
        if folder != standardized { importedImage = nil; artPlacement = FolderArtPlacement() }
        folder = standardized
        recentFolders = ([standardized.path] + recentFolders.split(separator: "\n").map(String.init).filter { $0 != standardized.path })
            .prefix(6).joined(separator: "\n")
        message = Self.folderHint
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
        message = Self.favoriteHint
        revision += 1
    }

    @MainActor private func refreshFavorites() async {
        let token = UUID()
        refreshToken = token
        do {
            let snapshot = try await Task.detached { try SidebarItemManager.shared.snapshot() }.value
            guard refreshToken == token else { return }
            currentSidebarIcons = Dictionary(uniqueKeysWithValues: snapshot.compactMap { item in
                SidebarItemManager.currentIcon(for: item).map { (item.itemID, $0) }
            })
            rows = snapshot
            revision += 1
            if let selectedRow, !snapshot.contains(where: { $0.itemID == selectedRow }) {
                self.selectedRow = nil
                message = "That Favorite was removed from Finder."
            }
        } catch {
            guard refreshToken == token else { return }
            rows = []
            currentSidebarIcons = [:]
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
            importedIsIcon = url.pathExtension.lowercased() == "icns"
            artPlacement = FolderArtPlacement()
            folderTab = "image"
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

    /// Imported image on the folder. Drag pans; pinch zooms.
    private func artCanvas(_ art: NSImage) -> some View {
        let side: CGFloat = 170
        return Image(nsImage: renderedMainIcon(size: 256)).resizable().scaledToFit().frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let start = gestureStart ?? artPlacement
                    gestureStart = start
                    var next = start
                    next.offset.width += drag.translation.width / side
                    next.offset.height -= drag.translation.height / side
                    artPlacement = FolderArtComposer.clamped(next, artSize: art.size)
                }
                .onEnded { _ in gestureStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { pinch in
                    let start = gestureStart ?? artPlacement
                    gestureStart = start
                    var next = start
                    next.zoom *= pinch.magnification
                    artPlacement = FolderArtComposer.clamped(next, artSize: art.size)
                }
                .onEnded { _ in gestureStart = nil })
            .help("Drag to move the image. Pinch to zoom.")
            .accessibilityLabel("Folder image position")
    }

    private func zoomControls(_ art: NSImage) -> some View {
        HStack {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { artPlacement.zoom },
                set: { artPlacement = FolderArtComposer.clamped(FolderArtPlacement(zoom: $0, offset: artPlacement.offset), artSize: art.size) }
            ), in: FolderArtPlacement.zoomRange).accessibilityLabel("Image zoom")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button("Reset") { artPlacement = FolderArtPlacement() }
                .disabled(artPlacement == FolderArtPlacement())
        }
        .frame(maxWidth: 320)
    }

    /// Bounce the preview and splash paint after a successful Apply.
    private func celebrate() {
        splashCount += 1
        guard !reduceMotion else { return }
        withAnimation(.spring(duration: 0.25, bounce: 0.6)) { bounce = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.spring(duration: 0.35)) { bounce = false }
        }
    }

    private func renderedMainIcon(size: Int = 1024) -> NSImage {
        if let importedImage {
            return importedIsIcon ? importedImage : FolderArtComposer.icon(with: importedImage, placement: artPlacement, size: size)
        }
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
        message = "Done. \(location == 0 ? target.lastPathComponent : (row?.displayName ?? target.lastPathComponent)) has a new look. Take a peek in Finder."
        celebrate()
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
        NSError(domain: "Roopam", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
