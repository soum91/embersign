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
        self.assertIn('let afcPath = "PublicStaging/', self.install)
        self.assertIn('let installPath = "PublicStaging/', self.install)
        self.assertIn('let installError = installPath.withCString', self.install)
        self.assertIn('source.read(upToCount: chunkSize)', self.install)
        self.assertIn('attempt <= 2 ? 65_536 : 16_384', self.install)

    def test_remote_install_answers_wireless_heartbeat(self):
        self.assertIn('heartbeat_connect(provider, &client)', self.install)
        self.assertIn('heartbeat_get_marco(client, interval, &next)', self.install)
        self.assertIn('heartbeat_send_polo(client)', self.install)
        self.assertIn('heartbeat_client_free(client)', self.install)
        start = self.install.index('try heartbeat.start()')
        self.assertLess(start, self.install.index('afc_client_connect(provider, &afc)', start))
        self.assertIn('if !heartbeat.isAlive { try heartbeat.start() }', self.install)

    def test_sender_stays_awake_during_remote_install(self):
        self.assertIn('EmberInstallKeepAlive.begin()', self.install)
        self.assertIn('isIdleTimerDisabled = true', self.install)
        self.assertIn('beginBackgroundTask', self.install)

    def test_resumes_staging_without_truncating_previous_upload(self):
        self.assertIn('let maxTransferAttempts = 4', self.install)
        self.assertIn('for attempt in 1...maxReconnects', self.install)
        self.assertIn('stalledAttempts < maxTransferAttempts', self.install)
        self.assertIn('if reachedSize > lastRemoteSize', self.install)
        self.assertIn('attempt == 1 ? AfcWrOnly : AfcRw', self.install)
        self.assertIn('if attempt == 1, let error = afc_remove_path', self.install)
        self.assertIn('afc_file_seek(handle, 0, SEEK_END, &remoteOffset)', self.install)
        self.assertIn('source.seek(toOffset: UInt64(remoteOffset))', self.install)
        self.assertIn('afc_file_seek(handle, 0, SEEK_END, &finalSize)', self.install)
        self.assertIn('UInt64(finalSize) == total', self.install)

    def test_only_retries_before_remote_install_request(self):
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
