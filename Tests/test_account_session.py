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
        self.assertIn("if let renewed = try? await renewAnisette(for: account)", code)
        self.assertIn("let value = try await operation(renewed)", code)
        self.assertIn("inventories[targetID] = try await withAppleSession(accountID: targetID)", code)
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

    def test_expired_session_signs_in_again_with_saved_password(self):
        code = self.manager
        self.assertIn('passwordService = "com.soum91.embersign.apple-passwords"', code)
        self.assertIn("try? saveKeychain(Data(password.utf8), service: passwordService, account: stored.id)", code)
        self.assertIn("try? deleteKeychain(service: passwordService, account: id)", code)
        self.assertIn("authenticate(appleID: appleID, password: password, server: server, interactive: false)", code)
        # A silent renewal must fail fast instead of waiting on a hidden 2FA sheet.
        self.assertIn("guard interactive else {", code)
        self.assertIn('(message.contains("please log in") && message.contains("1100"))', code)

    def test_every_portal_provisioning_path_recovers_the_session(self):
        code = self.manager
        for call in ("self.provisionSigningIdentity(bundleID: bundleID, account: account)",
                     "self.provisionIOSExtensionBundleSet(bundleIDs: bundleIDs, account: account)",
                     "self.provisionWatchCompanion(plan: plan, iphoneUDID: iphoneUDID, watchUDID: watchUDID, account: account)"):
            self.assertIn(call, code)
        self.assertEqual(code.count("return try await withAppleSession(accountID:"), 3)


if __name__ == "__main__":
    unittest.main()
