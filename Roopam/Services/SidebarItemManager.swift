import Foundation
import AppKit
import CoreServices

/// A single row of Finder's Favorites list.
struct SidebarItem: Equatable, Sendable {
    /// `LSSharedFileListItemGetID` of the row. Measured stable across processes and
    /// across in-place updates, which is what makes it usable as the persisted
    /// binding key in config.json.
    let itemID: UInt32

    /// The label Finder shows. For adopted rows this is the name the user chose.
    let displayName: String

    /// The row's resolved path, or nil when its bookmark can no longer be resolved.
    let path: String?

    /// The row's current `OverrideIcon.OSType`, or nil when it carries no override.
    let osType: String?
    var iconData: Data? = nil

    /// True when this row points at one of `candidates`.
    ///
    /// Prefer this over `candidates.contains(item.path!)`. A bookmark can resolve
    /// through a different but equivalent spelling of the same directory (measured:
    /// a row resolved to `/private/tmp/…` while the caller held `/tmp/…`), and
    /// 0.6.0 users were told to point favorites at symlinks into
    /// `~/Library/CloudStorage`.
    func matches(anyOf candidates: Set<String>) -> Bool {
        guard let path else { return false }
        if candidates.contains(path) { return true }
        let forms = Self.equivalentForms(of: path)
        return candidates.contains { !forms.isDisjoint(with: Self.equivalentForms(of: $0)) }
    }

    private static func equivalentForms(of path: String) -> Set<String> {
        let nsPath = path as NSString
        return [path, nsPath.standardizingPath, nsPath.resolvingSymlinksInPath]
    }
}

/// Swift facade over `SFLBridge`, the only code in the project that touches
/// `LSSharedFileList`.
///
/// Deliberately not `@MainActor`: `FavoriteSyncCoordinator` drives this from a
/// detached task so the Launch Services round-trips never block the UI.
///
/// Finder's Favorites list **de-duplicates by URL**. Inserting a URL that is
/// already present is an in-place upsert — the row keeps its position and its
/// persistent item ID while its display name and icon override are updated
/// (measured) — so a second `upsert(url:…)` for the same folder can never produce
/// a duplicate row.
///
/// `@unchecked Sendable` is accurate rather than a shortcut: the class stores no
/// mutable state beyond the lock below, and every list mutation is taken under it.
final class SidebarItemManager: @unchecked Sendable {
    static let shared = SidebarItemManager()

    /// Serializes list mutations. Recursive because `upsert` re-snapshots while
    /// holding it. The coordinator already funnels everything through one
    /// reconcile, but Settings' "Remove All Sidebar Icons" can arrive alongside it.
    private let lock = NSRecursiveLock()

    private init() {}

    // MARK: - Reading

    /// Every Favorites row, in list order.
    func snapshot() throws -> [SidebarItem] {
        lock.lock()
        defer { lock.unlock() }
        return try loadSnapshot()
    }

    // Implements docs/folder-icons/design.md: Current reads Finder's icon declaration, not the editing draft.
    @MainActor
    static func currentIcon(for row: SidebarItem) -> NSImage? {
        if let code = row.osType,
           let type = UTTypeCreatePreferredIdentifierForTag("com.apple.ostype" as CFString, code as CFString, nil)?.takeRetainedValue(),
           let bundleURL = UTTypeCopyDeclaringBundleURL(type)?.takeRetainedValue() as URL? {
            let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: plistURL),
               let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
               let symbol = symbolName(for: code, declarations: info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []) {
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: row.displayName) {
                    return image
                }
                if let image = Bundle(url: bundleURL)?.image(forResource: NSImage.Name(symbol)) {
                    return image.copy() as? NSImage
                }
            }
        }
        return row.iconData.flatMap(NSImage.init(data:))
    }

    static func symbolName(for code: String, declarations: [[String: Any]]) -> String? {
        for declaration in declarations {
            guard let tags = declaration["UTTypeTagSpecification"] as? [String: Any] else { continue }
            let codes = tags["com.apple.ostype"] as? [String] ?? (tags["com.apple.ostype"] as? String).map { [$0] } ?? []
            guard codes.contains(code) else { continue }
            return (declaration["UTTypeIcons"] as? [String: Any])?["UTTypeSymbolName"] as? String
        }
        return nil
    }

    /// The first row resolving to any of `candidates`, or nil.
    func item(matching candidates: Set<String>) throws -> SidebarItem? {
        try snapshot().first { $0.matches(anyOf: candidates) }
    }

    /// The row with this persistent ID, or nil when it is no longer in the list.
    func item(withID itemID: UInt32) throws -> SidebarItem? {
        try snapshot().first { $0.itemID == itemID }
    }

    // MARK: - Writing

    /// What one `upsert` did.
    struct UpsertResult: Sendable {
        /// The row as it stands now, carrying the DURABLE item ID.
        let row: SidebarItem

        /// The row as it was immediately BEFORE the write, when the list already
        /// held one for this URL - so nil means the write genuinely created the
        /// row and non-nil means it patched somebody's existing one.
        ///
        /// Read inside the bridge from the very snapshot the insert anchors
        /// against, which is what makes it usable as the ownership base case: a
        /// row that appeared between the caller's own snapshot and this write is
        /// still reported as pre-existing.
        let preexisting: SidebarItem?
    }

    /// Inserts the folder, or patches the existing row for it in place, then
    /// re-snapshots and returns the row carrying the DURABLE item ID.
    ///
    /// Re-reading is mandatory: the ID on the reference the insert returns is
    /// transient and can differ from the one the list persists.
    @discardableResult
    func upsert(url: URL, displayName: String, osType: String) throws -> UpsertResult {
        lock.lock()
        defer { lock.unlock() }

        var previous: NSDictionary?
        do {
            try SFLBridge.upsert(url: url, displayName: displayName, osType: osType, preexisting: &previous)
        } catch {
            throw Self.sidebarError(from: error)
        }

        guard let row = try loadSnapshot().first(where: { $0.matches(anyOf: [url.path]) }) else {
            throw SidebarError.itemNotFound
        }
        return UpsertResult(
            row: row,
            preexisting: (previous as? [String: Any]).flatMap(Self.item(from:))
        )
    }

    /// Applies the icon override to an existing row without touching its name.
    func setOSType(_ osType: String, itemID: UInt32) throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            try SFLBridge.setOSType(osType, itemID: itemID)
        } catch {
            throw Self.sidebarError(from: error)
        }
    }

    /// Removes the icon override, leaving the row itself in place.
    ///
    /// `displayName` MUST be the row's current name — the underlying call rewrites
    /// the label, and omitting it resets the row to the folder's file-system name.
    func clearOSType(url: URL, displayName: String) throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            try SFLBridge.clearOSType(url: url, displayName: displayName)
        } catch {
            throw Self.sidebarError(from: error)
        }
    }

    /// Applies, repairs or clears the icon override on the **Locations** row for
    /// this path. Pass nil to clear.
    ///
    /// A volume appears in Favorites only if someone put it there, but Finder
    /// always lists it under Locations - so a favorite pointing at a volume has
    /// two rows on screen, and icon-ing only one of them looks like a bug. This
    /// keeps the other in step.
    ///
    /// Silently does nothing when the volume is not mounted or Finder is not
    /// showing it: those are ordinary states, not failures.
    /// Returns whether a row was actually found and written. False means Finder
    /// has no row here to patch - the volume is not mounted, or it is a network
    /// share whose Locations entry Finder synthesises from the mount table.
    @discardableResult
    func setVolumeOSType(_ osType: String?, path: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var patched: ObjCBool = false
        do {
            try SFLBridge.setOSType(osType, volumePath: path, patched: &patched)
        } catch {
            throw Self.sidebarError(from: error)
        }
        return patched.boolValue
    }

    /// Deletes a row. Only ever called for rows this app inserted itself — the
    /// coordinator owns that decision, which is why there is no remove-by-path.
    func remove(itemID: UInt32) throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            try SFLBridge.remove(itemID: itemID)
        } catch {
            throw Self.sidebarError(from: error)
        }
    }

    // MARK: - Private

    /// Snapshot without taking the lock, for callers that already hold it.
    private func loadSnapshot() throws -> [SidebarItem] {
        let rows: [[String: Any]]
        do {
            rows = try SFLBridge.snapshot()
        } catch {
            throw Self.sidebarError(from: error)
        }
        return rows.compactMap(Self.item(from:))
    }

    private static func item(from row: [String: Any]) -> SidebarItem? {
        guard let identifier = row[SFLItemIDKey] as? NSNumber else { return nil }
        return SidebarItem(
            itemID: identifier.uint32Value,
            displayName: row[SFLItemDisplayNameKey] as? String ?? "",
            path: row[SFLItemPathKey] as? String,
            osType: row[SFLItemOSTypeKey] as? String,
            iconData: row[SFLItemIconDataKey] as? Data
        )
    }

    private static func sidebarError(from error: Error) -> SidebarError {
        if let sidebarError = error as? SidebarError {
            return sidebarError
        }
        let nsError = error as NSError
        guard nsError.domain == SFLBridgeErrorDomain else {
            return .operationFailed(nsError.localizedDescription)
        }
        switch nsError.code {
        case SFLBridgeErrorCode.listUnavailable.rawValue:
            return .listUnavailable
        case SFLBridgeErrorCode.itemNotFound.rawValue:
            return .itemNotFound
        default:
            return .operationFailed(nsError.localizedDescription)
        }
    }

    enum SidebarError: LocalizedError {
        case listUnavailable
        case itemNotFound
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .listUnavailable:
                return "Finder's Favorites list is unavailable."
            case .itemNotFound:
                return "That sidebar row is no longer in Finder's Favorites."
            case .operationFailed(let message):
                return message
            }
        }
    }
}
