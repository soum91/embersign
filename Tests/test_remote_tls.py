"""Regression checks for safe remote Wi-Fi installation and profile preflight."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "overrides/Feather/Ember/EmberInstallTarget.swift"
PREPARE = ROOT / "scripts/prepare.py"


class RemoteTLSAndProvisioningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.install = INSTALL.read_text(encoding="utf-8")
        cls.prepare = PREPARE.read_text(encoding="utf-8")

    def test_uses_separate_afc_and_install_proxy_sessions(self):
        self.assertIn('let afcPath = "/PublicStaging/', self.install)
        self.assertIn('let installPath = "PublicStaging/', self.install)
        self.assertIn('let installError = installPath.withCString', self.install)
        self.assertIn('source.read(upToCount: 262_144)', self.install)

    def test_only_retries_before_remote_install_request(self):
        self.assertIn('for attempt in 1...2', self.install)
        self.assertIn('isRecoverableConnectionFailure(error)', self.install)
        self.assertIn('requestStarted = true', self.install)
        self.assertIn('guard !requestStarted, attempt == 1', self.install)
        self.assertIn('removeStagedIPA(at: afcPath)', self.install)

    def test_profile_preflight_and_explicit_reprovision(self):
        self.assertIn('profile.provisionedDevices.contains', self.prepare)
        self.assertIn('The iPhone 13 is not in this signing profile', self.prepare)
        self.assertIn('Provision & sign for iPhone 13', self.prepare)
        self.assertIn('provisionSigningIdentity(bundleID: alternate)', self.prepare)
        self.assertIn('error.localizedDescription.contains("9401")', self.prepare)


if __name__ == "__main__":
    unittest.main()
