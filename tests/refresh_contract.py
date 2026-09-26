from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[1]
view = (root / 'Roopam/Views/ContentView.swift').read_text()

class RefreshContract(unittest.TestCase):
    def test_list_uses_refreshed_icons(self):
        row = view.split('ForEach(rows, id:', 1)[1].split('.padding(.vertical, 5)', 1)[0]
        self.assertIn('currentSidebarIcon(item', row)
        self.assertNotIn('Image(systemName: item.path', row)

    def test_current_preview_uses_same_live_source(self):
        current = view.split('private var preview:', 1)[1].split('Image(systemName: "arrow.right")', 1)[0]
        self.assertIn('currentSidebarIcon(row', current)
        self.assertNotIn('favorite = selectedFavorite', current)

    def test_refresh_replaces_icons_even_for_unchanged_row_ids(self):
        refresh = view.split('private func refreshFavorites()', 1)[1].split('private func importArtwork()', 1)[0]
        self.assertIn('currentSidebarIcons =', refresh)
        self.assertIn('revision += 1', refresh)
        self.assertNotIn('loadSidebarDraft()', refresh)

if __name__ == '__main__':
    unittest.main()
