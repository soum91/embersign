"""Source-level regressions for saved Apple sessions and Anisette renewal.

The Apple Developer Portal and 2FA must be exercised on actual iOS hardware.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MANAGER = ROOT / "overrides/Feather/Ember/EmberAccountManager.swift"
VIEW = ROOT / "overrides/Feather/Ember/EmberAccountsView.swift"


class AccountSessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manager = MANAGER.read_text(encoding="utf-8")
        cls.view = VIEW.read_text(encoding="utf-8")

    def test_one_retry_uses_fresh_anisette_and_preserves_saved_keys(self):
        code = self.manager
        self.assertIn("let renewed = try await renewAnisette(for: account)", code)
        self.assertIn("inventories[targetID] = try await fetchInventory(for: renewed)", code)
        self.assertIn("session.anisetteData = result.data", code)
        self.assertIn("try persist(updated)", code)
        self.assertIn("authAnisetteServer: server.absoluteString", code)
        self.assertIn("signingP12: existing?.signingP12", code)
        self.assertIn("signingCertificateID: existing?.signingCertificateID", code)

    def test_failed_session_recovery_offers_reauthentication(self):
        self.assertIn("sessionsRequiringLogin.insert(targetID)", self.manager)
        self.assertIn("sessionsRequiringLogin.remove(stored.id)", self.manager)
        self.assertIn("manager.sessionsRequiringLogin.contains(account.id)", self.view)
        self.assertIn("Button(\"Sign in again", self.view)
        self.assertIn("manager.selectedAccount?.auth.account.appleID", self.view)


if __name__ == "__main__":
    unittest.main()
