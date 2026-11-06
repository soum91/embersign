"""Regression checks for the pairing and navigation source overlay.

Device-level verification still requires two real trusted iPhones on the same LAN.
"""
from pathlib import Path
import unittest


SOURCE = (Path(__file__).resolve().parents[1]
          / "overrides/Feather/Ember/EmberInstallTarget.swift")


class RemoteInstallTests(unittest.TestCase):
    def setUp(self):
        self.source = SOURCE.read_text(encoding="utf-8")

    def test_uses_trusted_lockdown_session_before_requesting_identity(self):
        beginning = self.source.index("private static func withVerifiedProvider")
        end = self.source.index("static func probe(at ", beginning)
        body = self.source[beginning:end]
        connect = body.index("lockdownd_connect(provider, &lockdown)")
        pairing = body.index("idevice_provider_get_pairing_file(provider, &sessionPairing)")
        start = body.index("lockdownd_start_session(lockdown, sessionPairing)")
        identity = body.index('lockdownd_get_value(lockdown, "UniqueDeviceID"')
        self.assertLess(connect, pairing)
        self.assertLess(pairing, start)
        self.assertLess(start, identity)
        self.assertIn("idevice_pairing_file_free(sessionPairing)", body)
        self.assertIn("actual.caseInsensitiveCompare(expected)", body)

    def test_discovery_uses_checked_candidate_address(self):
        self.assertIn("verifyRemoteAddress(ip, timeoutSeconds: 7)", self.source)
        self.assertIn("self.onMatch?(ip)", self.source)
        self.assertIn("remoteSocketAddress(ip)", self.source)

    def test_picker_and_navigation_remain_accessible(self):
        self.assertIn(".fileImporter(isPresented: $importing", self.source)
        self.assertIn(".navigationBarTitleDisplayMode(.inline)", self.source)
        self.assertIn(".safeAreaInset(edge: .bottom)", self.source)


if __name__ == "__main__":
    unittest.main()
