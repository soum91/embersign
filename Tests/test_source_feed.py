import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from update_source import update_feed


ROOT = Path(__file__).resolve().parents[1]


class SourceFeedTests(unittest.TestCase):
    def setUp(self):
        self.feed = json.loads((ROOT / "source.json").read_text(encoding="utf-8"))
        # The release workflow commits newer versions into source.json after
        # every successful build. Always test with the next build instead of
        # assuming a historical number is still newest.
        latest_build = max(
            int(version["buildVersion"])
            for app in self.feed["apps"]
            for version in app.get("versions", [])
        )
        self.next_build = str(latest_build + 1)
        self.metadata = {
            "version": "0.2.0", "build": self.next_build, "size": 19000123,
            "bundle_identifier": "com.soum91.embersign",
        }

    def test_new_build_is_first_and_older_builds_remain(self):
        result = update_feed(copy.deepcopy(self.feed), self.metadata, "soum91/embersign", "2026-10-25")
        app = result["apps"][0]
        self.assertEqual(app["versions"][0]["buildVersion"], self.next_build)
        self.assertEqual(app["version"], f"0.2.0.{self.next_build}")
        self.assertEqual(app["size"], 19000123)
        self.assertTrue(app["downloadURL"].endswith(f"/v0.2.0-build.{self.next_build}/EmberSign.ipa"))
        self.assertTrue(any(version["buildVersion"] == "4" for version in app["versions"]))
        self.assertIn("Apple Account", app["localizedDescription"])

    def test_rerun_does_not_duplicate_same_build(self):
        first = update_feed(copy.deepcopy(self.feed), self.metadata, "soum91/embersign", "2026-10-25")
        second = update_feed(first, self.metadata, "soum91/embersign", "2026-10-25")
        matching = [v for v in second["apps"][0]["versions"] if v["buildVersion"] == self.next_build]
        self.assertEqual(len(matching), 1)

    def test_incorrect_bundle_identifier_is_rejected(self):
        metadata = dict(self.metadata, bundle_identifier="other.app")
        with self.assertRaises(ValueError):
            update_feed(copy.deepcopy(self.feed), metadata, "soum91/embersign", "2026-10-25")


if __name__ == "__main__":
    unittest.main()
