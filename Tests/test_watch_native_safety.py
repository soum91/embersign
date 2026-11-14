"""Native Watch entry points must never let a Rust panic abort EmberSign."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WatchNativeSafetyTests(unittest.TestCase):
    def test_watch_ffi_catches_panics(self):
        code = (ROOT / "pairing-native/src/lib.rs").read_text(encoding="utf-8")
        self.assertIn("std::panic::catch_unwind(std::panic::AssertUnwindSafe(work))", code)
        self.assertIn("let outcome = guard_panics(|| -> Result<(String, String), String> {", code)
        self.assertIn("let outcome = guard_panics(|| -> Result<(), String> {", code)
        cargo = (ROOT / "pairing-native/Cargo.toml").read_text(encoding="utf-8")
        self.assertNotIn('panic = "abort"', cargo)

    def test_idevice_errors_show_their_message(self):
        code = (ROOT / "overrides/IDeviceKitten/Sources/IDeviceSwift/IDeviceSwiftError.swift").read_text(encoding="utf-8")
        self.assertIn("extension IDeviceSwiftError: LocalizedError", code)
        self.assertIn("var errorDescription: String?", code)


if __name__ == "__main__":
    unittest.main()
