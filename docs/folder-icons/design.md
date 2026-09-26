# Folder Icons

The app edits folder artwork and Finder Favorites glyphs independently on macOS 26 and later.
The main-area picker accepts any accessible folder. Sidebar mode reads the live Favorites snapshot, including unresolved entries with an explanation; it never offers adding or deleting a Favorite.

## Contract

A radio picker selects the editing location. Separate drafts survive location switches. Applying targets only the selected location. Original appearance is backed up before the first change; Undo restores the immediately preceding appearance. Restore Original restores the state before this app first edited that folder and location.

SidebarFavorites supplies the symbol catalog, SVG validation and compilation, Favorites bridge, icon registration, and Finder Sync helper generation. The original MIT license remains in LICENSE. This fork uses separate application data and bundle identifiers.

Sidebar glyphs use monochrome SF Symbols or imported SVG silhouettes. Main-area icons use colored folder artwork with a symbol, or an imported image. The rendered image is previewed before Apply. Colors are baked into artwork; Finder tags are not changed.

## State and failure behavior

Reading Favorites does not apply icons. Missing, inaccessible, or removed Favorites cannot be applied. Failures remain visible with retry and Undo available. Finder restart is always a separate user action. The app never restarts Finder during build or launch.

Keeping a custom main-area icon and a sidebar glyph uses the upstream per-folder Finder Sync helper. Apply explains helper setup when necessary and reports activation status. Future macOS compatibility requires verification because sidebar integration uses private APIs.

Original and previous appearance records persist in Application Support/Roopam/History. Folder images are restored from TIFF snapshots of the displayed custom icon; absent custom icons restore the system icon. Sidebar snapshots preserve the prior override and app configuration.

## Manual acceptance

1. Select a local folder, change its color and symbol, and apply; confirm Finder shows the preview.
2. Select an existing Favorite, choose a different glyph, and apply; enable its helper when needed and confirm both icons remain distinct.
3. Switch modes before applying and confirm drafts survive; Undo and Restore Original must affect only the selected location.
4. Remove a Favorite in Finder while the editor is open; Apply must fail without adding it back.
5. Quit and reopen; restore an original appearance, check an unavailable folder, and confirm Finder only restarts on explicit request.

GUI and Finder behavior require the user's test. Build validation does not establish runtime sidebar compatibility.

## Current icon refresh

The Favorites list and Current preview share icons from the latest Finder snapshot. The snapshot includes the row icon as fallback. An OSType override resolves through its registered bundle's current on-disk type declaration, so changing the symbol behind an unchanged row identifier and OSType is visible after Refresh. Neither display uses the editing draft or saved Favorite configuration as evidence of Finder's current appearance. Unknown icons display an explicit unavailable placeholder. Refresh replaces the displayed icon collection without resetting the draft; superseded refresh results are discarded.

Regression checks cover both display consumers, refresh invalidation, same-code symbol changes, foreign-code isolation, case sensitivity, and removed declarations. The final visual comparison with Finder remains a manual check.

## Image folder icons

An imported PNG, JPEG, or TIFF is painted onto the folder, not used as the icon directly. `FolderArtComposer` loads the three layers macOS 26 uses to draw folders from `CoreTypes.bundle`: `FolderComponent_BackFlap`, `FolderComponent_PaperSheet`, and `FolderComponent_FrontFlap`. The image aspect-fills the back flap's bounds, so it runs continuously across the back tab and the front flap. Each flap pixel takes the image color multiplied by the cube of that flap pixel's brightness relative to the front flap's mean brightness; this keeps the system gradient and makes the back flap darker than the front. The white paper sheet is drawn unchanged between the flaps. Transparent image pixels keep the flap's own color. An imported `.icns` is already a finished icon and is used as-is. If a future macOS removes these layers, the imported image is used as-is.

The raw imported image and a `FolderArtPlacement` (zoom 100–400%, offset as a fraction of the back flap's width and height) are kept in the editor. Dragging the preview pans, and a trackpad pinch or the zoom slider zooms. `FolderArtComposer.clamped` limits the offset so the image always covers the whole folder. Reset returns to 100% zoom, centered. A new import resets the placement. The preview composes at 256 px (about 1 ms) on each change; Apply composes at 1024 px. The layers and the back flap's bounds are loaded once per launch. The system icon from `NSWorkspace.icon(for: .folder)` was rejected as the source because it has no paper sheet.

## Data folder

App data lives in `~/Library/Application Support/Roopam`; the bundle identifier is `local.roopam.Roopam`. Builds before the Roopam rename used `FolderIcons` and `local.foldericons.SidebarFavoritesManager`. The app kept no UserDefaults at the rename, so the identifier change lost no settings.

On launch, before `config.json` loads, `ConfigManager.migrateLegacyDataFolder` moves `FolderIcons` to `Roopam` when only `FolderIcons` exists and is a real directory. Launch Services knows the sidebar icon helper (`SidebarFavoritesIcons.app`) and each both-icons host (`AdvancedApps/*.app`) by path. The migration unregisters each at the old path, moves the folder, and registers each at the new path with the same `lsregister -f -R -trusted` flags the builders use. If the move fails, it re-registers the old paths and the app keeps using `FolderIcons` for that launch.

The helper bundle identifier, UTI prefix (`local.foldericons.SidebarFavorites.icon.`), Finder Sync extension identifiers, and `SBF-` display names are unchanged. Users never see the identifiers, and changing them would require re-registering every sidebar icon and re-enabling every extension. Strings in `MigrationService` describe upstream SidebarFavorites 0.6 artifacts and stay as they are.

## Editor layout

The window is a `NavigationSplitView`. The sidebar is a native `.sidebar` list, so its material, row height and selection match Finder's. It has two sections. **Folders** has a Choose a Folder row and up to six recently edited folders (stored in the `recentFolders` user default, newest first, missing folders hidden). **Remove from List** (the ✕ button that appears when hovering a row, Delete while the folder is selected, or the VoiceOver action) takes a folder off the list and clears the selection if it was selected; the folder and its icon are not changed. **Favorites** lists Finder's Favorites with their live glyphs. Selecting a row selects the location; the separate location picker is gone. Dropping a folder on the sidebar or the empty stage selects it. Refresh is an icon-only toolbar button. The window title is hidden because the detail header already names the selection.

The detail pane stays native except for the preview stage (`EaselStage`): a warm painted canvas showing "now → after apply". Folder artwork is chosen with image / color / symbol pill tabs, named color swatches, a surprise-me button, and symbol stickers. Sidebar glyphs use symbol / svg tabs and the same stickers; their preview draws the selected Favorite between its neighbours at Finder's sidebar size. Headings and controls with personality use the system rounded font at black or heavy weight; errors and warnings stay plain text. A successful Apply bounces the preview and splashes paint; Reduce Motion turns both off.
