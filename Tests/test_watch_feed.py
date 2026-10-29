import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from update_watch_source import update_watch_feed


class WatchPreviewFeedTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[1]
        self.feed = json.loads((root / "watch-source.json").read_text(encoding="utf-8"))
        self.metadata = {"version": "0.2.1", "build": "23", "size": 22800000, "bundle_identifier": "com.soum91.embersign"}

    def test_preview_is_separate_and_has_direct_release_ipa(self):
        updated = update_watch_feed(copy.deepcopy(self.feed), self.metadata, "soum91/embersign", "2026-10-29")
        app = updated["apps"][0]
        self.assertEqual(app["version"], "0.2.1.23")
        self.assertEqual(app["bundleIdentifier"], "com.soum91.embersign")
        self.assertEqual(app["size"], 22800000)
        self.assertTrue(app["downloadURL"].endswith("/watch-preview-23/EmberSign.ipa"))
        self.assertIn("watch-support", updated["sourceURL"])
        self.assertIn("not yet", app["localizedDescription"])

    def test_republishing_same_build_does_not_duplicate(self):
        first = update_watch_feed(copy.deepcopy(self.feed), self.metadata, "soum91/embersign", "2026-10-29")
        second = update_watch_feed(first, self.metadata, "soum91/embersign", "2026-10-29")
        self.assertEqual(len(second["apps"][0]["versions"]), 1)

    def test_invalid_metadata_is_rejected(self):
        for metadata in [
            dict(self.metadata, size=0),
            dict(self.metadata, bundle_identifier="wrong.app"),
            dict(self.metadata, version="0.2.0"),
        ]:
            with self.assertRaises(ValueError):
                update_watch_feed(copy.deepcopy(self.feed), metadata, "soum91/embersign", "2026-10-29")


if __name__ == "__main__":
    unittest.main()
