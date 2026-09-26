# Folder Icons

Open `build-local/Folder Icons.app` on this Mac. This local build targets macOS Tahoe 26 and later.

1. Select **Finder main area**, choose or drop a folder, select a color and symbol or import an image, then Apply.
2. Select **Finder Favorites sidebar**, select an existing Favorite, choose a symbol or SVG, then Apply.
3. If you use both icons, follow the extension setup message; use **Open Extension Settings** when required.
4. Use **Undo** for the preceding appearance or **Restore Original** for the appearance before this app first changed it.
5. Use **Restart Finder** only when ready; the app does not restart it automatically.

Favorites must already exist in Finder. There is no Add Favorite action. Unresolved Favorites are visible but cannot be edited.

The app stores separate settings and recovery records in `~/Library/Application Support/FolderIcons/`. Original icon records include the folder's device and inode identity, so replacing a folder at the same path does not reuse its predecessor's backup. Moving a folder to another path starts a separate history.

This is a local ad-hoc signed build, not a notarized distribution. Finder integration and extension activation still need a manual test on the target Mac; compiling and unit checks cannot establish compatibility with every macOS release.

## Build and checks

Run `bash scripts/build-local.sh` from this repository to rebuild with the installed Apple compiler. Run `bash scripts/check-local.sh` after building for the short recovery and selection checks. These checks do not launch the app, change folder icons, register helpers, or restart Finder.

The Xcode project remains available. On this machine, `xcodebuild` could not load its simulator framework because of a conflicting installed framework; the direct build script bypasses that Xcode failure.

## Provenance

Based on [SidebarFavorites](https://github.com/ivg-design/SidebarFavorites), under its MIT license in `LICENSE`. The original README documents the upstream app, including features intentionally absent from this editor. This fork uses its symbol catalog, SVG pipeline, Finder integration, and per-folder helper mechanism.

The behavior and manual acceptance checks are in `docs/folder-icons/design.md`.
