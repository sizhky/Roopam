import Foundation

@main
struct RecoveryChecks {
    static func main() throws {
        let start = ContinuousClock.now
        let image = Data([0x49, 0x49, 0x2A, 0x00])
        let original = IconSnapshot(image: image, osType: nil, favorite: nil)
        var history = IconHistory(original: original, previous: nil)
        history.previous = IconSnapshot(image: Data([1, 2, 3]), osType: nil, favorite: nil)
        let restored = try JSONDecoder().decode(IconHistory.self, from: JSONEncoder().encode(history))
        precondition(restored.original?.image == image, "Apply must preserve the original appearance")
        precondition(restored.previous?.image == Data([1, 2, 3]), "Undo must preserve the preceding appearance")

        let favorite = Favorite(name: "Work", folderPath: "/tmp/Work", iconType: .custom,
                                iconValue: "custom.mark", customSVGPath: "custom.mark.svg",
                                osType: "S123", sidebarItemID: 42, sidebarProvenance: .adopted,
                                iconScale: 1.25, mode: .advanced)
        let sidebar = IconSnapshot(image: nil, osType: "X789", favorite: favorite)
        let decoded = try JSONDecoder().decode(IconSnapshot.self, from: JSONEncoder().encode(sidebar))
        precondition(decoded.favorite == favorite, "Recovery must retain SVG, scale, helper mode and adopted ownership")
        precondition(decoded.osType == "X789", "Recovery must retain a pre-existing third-party override")
        let system = IconSnapshot(image: nil, osType: nil, favorite: nil)
        let decodedSystem = try JSONDecoder().decode(IconSnapshot.self, from: JSONEncoder().encode(system))
        precondition(decodedSystem.image == nil && decodedSystem.osType == nil && decodedSystem.favorite == nil,
                     "Recovery must distinguish default icons from saved custom icons")

        let row = SidebarItem(itemID: 42, displayName: "Work", path: "/tmp/Work/", osType: "S123")
        precondition(row.matches(anyOf: favorite.pathMatchCandidates), "Equivalent folder paths must match")
        precondition(!row.matches(anyOf: ["/tmp/Other"]), "A different folder must never match a saved selection")
        let unresolved = SidebarItem(itemID: 43, displayName: "Offline", path: nil, osType: nil)
        precondition(!unresolved.matches(anyOf: favorite.pathMatchCandidates), "Unresolved Favorites cannot be edited")
        func declaration(_ symbol: String, code: String = "S123") -> [[String: Any]] {
            [["UTTypeTagSpecification": ["com.apple.ostype": [code]],
              "UTTypeIcons": ["UTTypeSymbolName": symbol]]]
        }
        let before = SidebarItemManager.symbolName(for: "S123", declarations: declaration("star.fill"))
        let after = SidebarItemManager.symbolName(for: "S123", declarations: declaration("hammer.fill"))
        precondition(before == "star.fill" && after == "hammer.fill",
                     "Refresh must read new artwork even when the row and OSType stay unchanged")
        precondition(SidebarItemManager.symbolName(for: "S123", declarations: declaration("heart.fill", code: "X789")) == nil,
                     "A different Favorite's declaration must not supply the displayed icon")
        precondition(SidebarItemManager.symbolName(for: "s123", declarations: declaration("heart.fill")) == nil,
                     "OSType icon tags remain case-sensitive")
        precondition(SidebarItemManager.symbolName(for: "S123", declarations: []) == nil,
                     "A removed override must not retain its previous displayed symbol")
        print("12 recovery, selection, and refresh checks passed in \(start.duration(to: .now)).")
    }
}
