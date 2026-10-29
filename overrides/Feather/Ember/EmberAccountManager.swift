import Foundation
import Security
import AnisetteKit
import SideSign
import UIKit

private struct EmberAnisetteServerIdentity: Decodable {
    let clientInfo: String
    let userAgent: String

    enum CodingKeys: String, CodingKey {
        case clientInfo = "client_info"
        case userAgent = "user_agent"
    }
}

struct EmberStoredAccount: Codable, Identifiable, Equatable {
    var id: String { auth.account.appleID.lowercased() }
    var auth: AuthSession
    var teams: [Team]
    var selectedTeamID: String
    var signingP12: Data?
    var signingCertificateID: String?

    var selectedTeam: Team? {
        teams.first(where: { $0.identifier == selectedTeamID }) ?? teams.first
    }
}

struct EmberAccountInventory {
    var certificates: [X509Certificate] = []
    var appIDs: [AppID] = []
    var profiles: [ListedProvisioningProfile] = []
    var devices: [Device] = []

    func appIDsRemaining(for team: Team) -> Int? {
        team.type == .free ? max(0, 10 - appIDs.count) : nil
    }
}

struct EmberWatchSigningIdentity: Sendable {
    let p12: Data
    let profiles: [String: Data]
}

struct EmberTwoFactorChallenge: Identifiable {
    let id = UUID()
    let request: TwoFactorRequest
}

enum EmberAccountStoreError: LocalizedError {
    case missingAccount
    case missingTeam
    case missingPairingUDID
    case keychain(OSStatus)
    case invalidAnisetteURL
    case anisetteIdentityUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAccount: return "Choose an Apple Account first."
        case .missingTeam: return "No Apple development team is available for this account."
        case .missingPairingUDID: return "Import a Lockdown pairing file containing this device's UDID before provisioning."
        case .keychain(let status): return "Keychain operation failed (\(status))."
        case .invalidAnisetteURL: return "The Anisette server address is invalid."
        case .anisetteIdentityUnavailable: return "This Anisette server did not provide a usable /v3/client_info identity. Select a compatible Mac Anisette server and try again."
        case .cancelled: return "Sign-in was cancelled."
        }
    }
}

@MainActor
final class EmberAccountManager: ObservableObject {
    static let shared = EmberAccountManager()
    static let recommendedAnisetteServer = "https://mac-ani.jkcoxson.com"
    private static let previousDefaultAnisetteServer = "https://ani.sidestore.io"

    @Published private(set) var accounts: [EmberStoredAccount] = []
    @Published private(set) var inventories: [String: EmberAccountInventory] = [:]
    @Published var selectedAccountID: String = ""
    @Published var isBusy = false
    @Published var status = "Add an Apple Account to provision free or paid development signing."
    @Published var twoFactorChallenge: EmberTwoFactorChallenge?

    @Published var anisetteServer: String = {
        let saved = UserDefaults.standard.string(forKey: "EmberSign.anisetteServer")
        // Migrate only the old built-in default. Preserve the user's custom server.
        return saved == nil || saved == EmberAccountManager.previousDefaultAnisetteServer
            ? EmberAccountManager.recommendedAnisetteServer : saved!
    }()

    private let portal = DeveloperPortal.shared
    private var twoFactorContinuation: CheckedContinuation<TwoFactorResponse, Error>?
    private let sessionService = "com.soum91.embersign.apple-accounts"
    private let anisetteService = "com.soum91.embersign.anisette"

    private init() {
        accounts = (try? loadAllAccounts()) ?? []
        selectedAccountID = UserDefaults.standard.string(forKey: "EmberSign.selectedAccount") ?? accounts.first?.id ?? ""
    }

    var selectedAccount: EmberStoredAccount? {
        accounts.first(where: { $0.id == selectedAccountID })
    }

    func select(_ id: String) {
        selectedAccountID = id
        UserDefaults.standard.set(id, forKey: "EmberSign.selectedAccount")
    }

    func useRecommendedAnisetteServer() {
        anisetteServer = Self.recommendedAnisetteServer
        UserDefaults.standard.set(anisetteServer, forKey: "EmberSign.anisetteServer")
        status = "Mac Anisette selected. Sign in to request a fresh Apple verification challenge."
    }

    func resetCurrentAnisetteIdentity() {
        guard !isBusy else { return }
        guard let server = URL(string: anisetteServer.trimmingCharacters(in: .whitespacesAndNewlines)),
              server.host != nil else {
            status = EmberAccountStoreError.invalidAnisetteURL.localizedDescription
            return
        }
        do {
            try deleteKeychain(service: anisetteService, account: anisetteBlobKey(for: server))
            UserDefaults.standard.removeObject(forKey: anisetteIdentifierKey(for: server))
            status = "Anisette identity reset for this server. Apple Accounts and pairing files were kept."
        } catch {
            EmberErrorCenter.shared.record(error, operation: "Reset Anisette identity")
            status = error.localizedDescription
        }
    }

    func login(appleID: String, password: String) async {
        guard !appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            status = "Enter your Apple Account email and password."
            return
        }
        guard let server = URL(string: anisetteServer.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(server.scheme?.lowercased() ?? ""), server.host != nil else {
            status = EmberAccountStoreError.invalidAnisetteURL.localizedDescription
            return
        }
        isBusy = true
        status = "Requesting Anisette data..."
        UserDefaults.standard.set(anisetteServer, forKey: "EmberSign.anisetteServer")
        do {
            status = "Checking Anisette device identity..."
            let identity = try await fetchServerIdentity(from: server)
            var headers = AnisetteRequestHeaders()
            headers.clientInfo = identity.clientInfo
            headers.userAgent = identity.userAgent

            let deviceID = persistentAnisetteIdentifier(for: server)
            let blobKey = anisetteBlobKey(for: server)
            let existingBlob = try? readKeychain(service: anisetteService, account: blobKey)
            status = "Requesting Anisette data..."
            let manager = AnisetteDataManager(mode: .remote(server: server))
            let result = try await manager.fetchAnisetteData(identifier: deviceID, existingAdiBlob: existingBlob, headers: headers)
            if let blob = result.newAdiBlob { try saveKeychain(blob, service: anisetteService, account: blobKey) }

            // SideSign's default GrandSlam user agent describes Xcode on a newer Mac.
            // Use the user agent advertised by the server that actually made the ADI data.
            var authHeaders = SideSignHeaders()
            authHeaders.grandSlam.userAgent = identity.userAgent
            let loginPortal = DeveloperPortal(customHeaders: authHeaders)
            status = "Authenticating with Apple..."
            let auth = try await loginPortal.authenticate(
                appleID: appleID,
                password: password,
                anisetteData: result.data,
                xcodeVersion: "26.0",
                verificationHandler: { [weak self] request in
                    guard let self else { throw EmberAccountStoreError.cancelled }
                    return try await self.requestTwoFactor(request)
                }
            )
            let teams = try await loginPortal.fetchTeams(for: auth.account, session: auth.session)
            guard let team = teams.first else { throw EmberAccountStoreError.missingTeam }
            let stored = EmberStoredAccount(auth: auth, teams: teams, selectedTeamID: team.identifier)
            try persist(stored)
            upsert(stored)
            select(stored.id)
            status = "Signed in as \(auth.account.appleID)."
            await refresh(accountID: stored.id)
        } catch {
            EmberErrorCenter.shared.record(error, operation: "Apple Account sign-in")
            let message = error.localizedDescription
            if message.contains("80045") {
                status = "Apple rejected the device identity before 2FA (-80045). Use Mac Anisette, reset its identity, and try again later. Repeated attempts may temporarily lock sign-in."
            } else if message.contains("80046") {
                status = "Apple refused the developer app-token step (-80046). Check the Anisette server identity and try a Mac Anisette service."
            } else {
                status = message
            }
        }
        isBusy = false
    }

    func respondToTwoFactor(_ response: TwoFactorResponse) {
        let continuation = twoFactorContinuation
        twoFactorContinuation = nil
        twoFactorChallenge = nil
        continuation?.resume(returning: response)
    }

    func cancelTwoFactor() {
        respondToTwoFactor(.cancel)
    }

    private func requestTwoFactor(_ request: TwoFactorRequest) async throws -> TwoFactorResponse {
        try await withCheckedThrowingContinuation { continuation in
            status = "Apple requested two-factor authentication. Choose a delivery method or enter the code below."
            twoFactorContinuation = continuation
            twoFactorChallenge = EmberTwoFactorChallenge(request: request)
        }
    }

    func refresh(accountID: String? = nil) async {
        let targetID = accountID ?? selectedAccountID
        guard let account = accounts.first(where: { $0.id == targetID }), let team = account.selectedTeam else { return }
        isBusy = true
        status = "Refreshing \(account.auth.account.appleID)..."
        do {
            async let certificates = portal.fetchCertificates(for: team, session: account.auth.session)
            async let appIDs = portal.fetchAppIDs(for: team, session: account.auth.session)
            async let profiles = portal.listProvisioningProfiles(for: team, session: account.auth.session)
            async let devices = portal.fetchDevices(for: team, session: account.auth.session)
            inventories[targetID] = try await EmberAccountInventory(
                certificates: certificates,
                appIDs: appIDs,
                profiles: profiles,
                devices: devices
            )
            status = "Account data is current."
        } catch {
            EmberErrorCenter.shared.record(error, operation: "Refresh developer account")
            status = error.localizedDescription
        }
        isBusy = false
    }

    func setTeam(_ teamID: String, for accountID: String) async {
        guard var account = accounts.first(where: { $0.id == accountID }) else { return }
        account.selectedTeamID = teamID
        do {
            try persist(account)
            upsert(account)
            await refresh(accountID: accountID)
        } catch {
            EmberErrorCenter.shared.record(error, operation: "Select developer team")
            status = error.localizedDescription
        }
    }

    func removeAccount(_ id: String) {
        do {
            try deleteKeychain(service: sessionService, account: id)
            accounts.removeAll { $0.id == id }
            inventories[id] = nil
            if selectedAccountID == id { select(accounts.first?.id ?? "") }
            status = "Account removed from this device."
        } catch {
            EmberErrorCenter.shared.record(error, operation: "Remove Apple Account")
            status = error.localizedDescription
        }
    }

    func revokeCertificate(_ certificate: X509Certificate, accountID: String) async {
        guard let account = accounts.first(where: { $0.id == accountID }), let team = account.selectedTeam else { return }
        isBusy = true
        do {
            _ = try await portal.revokeCertificate(certificate, for: team, session: account.auth.session)
            var updated = account
            if updated.signingCertificateID == certificate.identifier {
                updated.signingCertificateID = nil
                updated.signingP12 = nil
                try persist(updated)
                upsert(updated)
            }
            status = "Certificate revoked. Apps signed with it may stop launching."
            await refresh(accountID: accountID)
        } catch {
            EmberErrorCenter.shared.record(error, operation: "Revoke certificate")
            status = error.localizedDescription
        }
        isBusy = false
    }

    func deleteProfile(_ profile: ListedProvisioningProfile, accountID: String) async {
        guard let profileID = profile.identifier,
              let account = accounts.first(where: { $0.id == accountID }),
              let team = account.selectedTeam else { return }
        isBusy = true
        do {
            _ = try await portal.deleteProvisioningProfile(profileID: profileID, team: team, session: account.auth.session)
            status = "Provisioning profile removed."
            await refresh(accountID: accountID)
        } catch {
            EmberErrorCenter.shared.record(error, operation: "Delete provisioning profile")
            status = error.localizedDescription
        }
        isBusy = false
    }

    func deleteAppID(_ appID: AppID, accountID: String) async {
        guard let account = accounts.first(where: { $0.id == accountID }), let team = account.selectedTeam else { return }
        isBusy = true
        do {
            _ = try await portal.deleteAppID(appID, for: team, session: account.auth.session)
            status = "App ID deletion requested. Apple may retain free-account quota until its seven-day window expires."
            await refresh(accountID: accountID)
        } catch {
            EmberErrorCenter.shared.record(error, operation: "Delete App ID")
            status = error.localizedDescription
        }
        isBusy = false
    }

    func revokePortalRecords(bundleID: String, teamID: String?) async throws {
        guard let account = accounts.first(where: { item in
            guard let teamID else { return item.id == selectedAccountID }
            return item.teams.contains(where: { $0.identifier == teamID })
        }), let team = account.teams.first(where: { $0.identifier == teamID }) ?? account.selectedTeam else {
            throw EmberAccountStoreError.missingAccount
        }
        let profiles = try await portal.listProvisioningProfiles(for: team, session: account.auth.session)
        for profile in profiles where profile.bundleIdentifier == bundleID {
            if let id = profile.identifier { _ = try await portal.deleteProvisioningProfile(profileID: id, team: team, session: account.auth.session) }
        }
        let appIDs = try await portal.fetchAppIDs(for: team, session: account.auth.session)
        if let appID = appIDs.first(where: { $0.bundleIdentifier == bundleID }) {
            _ = try await portal.deleteAppID(appID, for: team, session: account.auth.session)
        }
        await refresh(accountID: account.id)
    }

    /// Apple's App ID display name accepts only ASCII letters, numbers and spaces.
    /// The bundle identifier itself retains its original dots and other characters.
    private func portalAppIDDisplayName(for bundleID: String) -> String {
        let readable = bundleID.replacingOccurrences(of: "[^A-Za-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "EmberSign \(readable)"
    }

    func provisionSigningIdentity(bundleID: String, accountID: String? = nil) async throws -> CertificatePair {
        let targetID = accountID ?? selectedAccountID
        guard var account = accounts.first(where: { $0.id == targetID }) else { throw EmberAccountStoreError.missingAccount }
        guard let team = account.selectedTeam else { throw EmberAccountStoreError.missingTeam }
        let pairingRecord = try EmberPairingStore.read()
        guard let udid = pairingRecord.udid, !udid.isEmpty else {
            throw EmberAccountStoreError.missingPairingUDID
        }

        status = "Registering this device and App ID..."
        var devices = try await portal.fetchDevices(for: team, session: account.auth.session)
        if !devices.contains(where: { $0.identifier.caseInsensitiveCompare(udid) == .orderedSame }) {
            let registered = try await portal.registerDevice(
                name: UIDevice.current.name,
                identifier: udid,
                type: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
                team: team,
                session: account.auth.session
            )
            devices.append(registered)
        }

        var appIDs = try await portal.fetchAppIDs(for: team, session: account.auth.session)
        let appID: AppID
        if let existing = appIDs.first(where: { $0.bundleIdentifier == bundleID }) {
            appID = existing
        } else {
            appID = try await portal.addAppID(withName: portalAppIDDisplayName(for: bundleID), bundleIdentifier: bundleID, team: team, session: account.auth.session)
            appIDs.append(appID)
        }

        let portalCertificates = try await portal.fetchCertificates(for: team, session: account.auth.session)
        var p12 = account.signingP12
        if account.signingCertificateID == nil || !portalCertificates.contains(where: { $0.identifier == account.signingCertificateID }) || p12 == nil {
            status = "Creating an Apple Development certificate..."
            let keyStore = try await portal.addCertificate(machineName: "EmberSign on \(UIDevice.current.name)", to: team, session: account.auth.session)
            p12 = try keyStore.exportP12(password: "")
            account.signingP12 = p12
            account.signingCertificateID = keyStore.certificate.identifier
            try persist(account)
            upsert(account)
        }

        status = "Downloading a fresh provisioning profile..."
        let profile = try await portal.downloadProvisioningProfile(for: appID, isTeamProfile: true, team: team, session: account.auth.session)
        guard let p12 else { throw EmberAccountStoreError.missingAccount }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberAccount_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let p12URL = directory.appendingPathComponent("certificate.p12")
        let profileURL = directory.appendingPathComponent("profile.mobileprovision")
        try p12.write(to: p12URL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try profile.data.write(to: profileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        let oldIDs = Set(Storage.shared.getAllCertificates().compactMap(\.uuid))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FR.handleCertificateFiles(
                p12URL: p12URL,
                provisionURL: profileURL,
                p12Password: "",
                certificateName: "Apple: \(account.auth.account.appleID) • \(bundleID)"
            ) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        guard let imported = Storage.shared.getAllCertificates().first(where: { !oldIDs.contains($0.uuid ?? "") }) else {
            throw EmberError.message("The Apple signing identity was created but could not be added to EmberSign.")
        }
        setAccountMapping(account.id, for: bundleID)
        status = "Fresh signing identity ready for \(bundleID)."
        await refresh(accountID: account.id)
        return imported
    }

    /// Provision the iPhone host, Watch app and Watch extensions separately.
    /// Watch profiles must explicitly include the registered Watch UDID;
    /// reusing a profile generated for the iPhone would produce an invalid IPA.
    func provisionWatchCompanion(plan: EmberWatchBundlePlan, iphoneUDID: String, watchUDID: String) async throws -> EmberWatchSigningIdentity {
        guard var account = selectedAccount else { throw EmberAccountStoreError.missingAccount }
        guard let team = account.selectedTeam else { throw EmberAccountStoreError.missingTeam }
        guard !watchUDID.isEmpty else { throw EmberError.message("Connect and discover your paired Apple Watch first.") }
        guard !iphoneUDID.isEmpty else { throw EmberAccountStoreError.missingPairingUDID }
        status = "Registering iPhone and Apple Watch…"
        var devices = try await portal.fetchDevices(for: team, session: account.auth.session)
        if !devices.contains(where: { $0.identifier.caseInsensitiveCompare(iphoneUDID) == .orderedSame }) {
            let registered = try await portal.registerDevice(
                name: UIDevice.current.name, identifier: iphoneUDID, type: .iPhone,
                team: team, session: account.auth.session
            )
            devices.append(registered)
        }
        if !devices.contains(where: { $0.identifier.caseInsensitiveCompare(watchUDID) == .orderedSame }) {
            let registered = try await portal.registerDevice(
                name: "EmberSign Apple Watch", identifier: watchUDID, type: .appleWatch,
                team: team, session: account.auth.session
            )
            devices.append(registered)
        }

        var appIDs = try await portal.fetchAppIDs(for: team, session: account.auth.session)
        let certificates = try await portal.fetchCertificates(for: team, session: account.auth.session)
        var p12 = account.signingP12
        if p12 == nil || account.signingCertificateID == nil ||
           !certificates.contains(where: { $0.identifier == account.signingCertificateID }) {
            status = "Creating development signing certificate…"
            let store = try await portal.addCertificate(
                machineName: "EmberSign Apple Watch", to: team, session: account.auth.session
            )
            p12 = try store.exportP12(password: "")
            account.signingP12 = p12
            account.signingCertificateID = store.certificate.identifier
            try persist(account)
            upsert(account)
        }
        guard let p12 else { throw EmberError.message("Could not get a development certificate.") }

        var profiles: [String: Data] = [:]
        for target in plan.targets {
            let id = target.bundleID
            status = "Provisioning \(id)…"
            let appID: AppID
            if let found = appIDs.first(where: { $0.bundleIdentifier == id }) {
                appID = found
            } else {
                appID = try await portal.addAppID(
                    withName: portalAppIDDisplayName(for: id), bundleIdentifier: id,
                    team: team, session: account.auth.session
                )
                appIDs.append(appID)
            }
            let isWatch = target.kind != .iphoneApp
            let profile = try await portal.downloadProvisioningProfile(
                for: appID, isTeamProfile: true,
                subPlatform: isWatch ? "watchOS" : nil,
                deviceType: isWatch ? .appleWatch : .iPhone,
                team: team, session: account.auth.session
            )
            let expectedUDID = isWatch ? watchUDID : iphoneUDID
            guard profile.deviceIDs.contains(where: { $0.caseInsensitiveCompare(expectedUDID) == .orderedSame }) else {
                throw EmberError.message("Apple's \(isWatch ? "watchOS" : "iOS") profile for \(id) does not include the registered device \(expectedUDID). Check your team and device registration.")
            }
            guard profile.bundleIdentifier == id else {
                throw EmberError.message("Apple returned a mismatched profile for \(id).")
            }
            profiles[id] = profile.data
        }
        try plan.validateProfiles(profiles)
        status = "All iPhone, Watch and extension profiles are ready."
        return EmberWatchSigningIdentity(p12: p12, profiles: profiles)
    }

    func accountID(for bundleID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "EmberSign.bundleAccounts") as? [String: String])?[bundleID]
    }

    func account(forTeamID teamID: String?) -> EmberStoredAccount? {
        guard let teamID else { return nil }
        return accounts.first(where: { $0.teams.contains(where: { $0.identifier == teamID }) })
    }

    private func setAccountMapping(_ accountID: String, for bundleID: String) {
        var mappings = UserDefaults.standard.dictionary(forKey: "EmberSign.bundleAccounts") as? [String: String] ?? [:]
        mappings[bundleID] = accountID
        UserDefaults.standard.set(mappings, forKey: "EmberSign.bundleAccounts")
    }

    private func upsert(_ account: EmberStoredAccount) {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        accounts.sort { $0.auth.account.appleID.localizedCaseInsensitiveCompare($1.auth.account.appleID) == .orderedAscending }
    }

    private func persist(_ account: EmberStoredAccount) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try saveKeychain(encoder.encode(account), service: sessionService, account: account.id)
    }

    private func loadAllAccounts() throws -> [EmberStoredAccount] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw EmberAccountStoreError.keychain(status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (result as? [Data] ?? []).compactMap { try? decoder.decode(EmberStoredAccount.self, from: $0) }
    }

    private func anisetteScope(for server: URL) -> String {
        server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func anisetteIdentifierKey(for server: URL) -> String {
        "EmberSign.anisetteIdentifier.\(anisetteScope(for: server))"
    }

    private func anisetteBlobKey(for server: URL) -> String {
        "adi.pb.\(anisetteScope(for: server))"
    }

    private func persistentAnisetteIdentifier(for server: URL) -> UUID {
        let key = anisetteIdentifierKey(for: server)
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    private func fetchServerIdentity(from server: URL) async throws -> EmberAnisetteServerIdentity {
        let identityURL = server.appendingPathComponent("v3/client_info")
        var request = URLRequest(url: identityURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let identity = try? JSONDecoder().decode(EmberAnisetteServerIdentity.self, from: data),
              !identity.clientInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmberAccountStoreError.anisetteIdentityUnavailable
        }
        return identity
    }

    private func saveKeychain(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw EmberAccountStoreError.keychain(status) }
    }

    private func readKeychain(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw EmberAccountStoreError.keychain(status) }
        return data
    }

    private func deleteKeychain(service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EmberAccountStoreError.keychain(status) }
    }
}
