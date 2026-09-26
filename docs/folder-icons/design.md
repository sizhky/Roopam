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

Original and previous appearance records persist in Application Support/FolderIcons/History. Folder images are restored from TIFF snapshots of the displayed custom icon; absent custom icons restore the system icon. Sidebar snapshots preserve the prior override and app configuration.

## Manual acceptance

1. Select a local folder, change its color and symbol, and apply; confirm Finder shows the preview.
2. Select an existing Favorite, choose a different glyph, and apply; enable its helper when needed and confirm both icons remain distinct.
3. Switch modes before applying and confirm drafts survive; Undo and Restore Original must affect only the selected location.
4. Remove a Favorite in Finder while the editor is open; Apply must fail without adding it back.
5. Quit and reopen; restore an original appearance, check an unavailable folder, and confirm Finder only restarts on explicit request.

GUI and Finder behavior require the user's test. Build validation does not establish runtime sidebar compatibility.
