import SwiftUI
import SideSign

struct EmberAccountsView: View {
    @ObservedObject private var manager = EmberAccountManager.shared
    @State private var showLogin = false

    var body: some View {
        List {
            Section {
                if manager.accounts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No Apple Accounts").font(.headline)
                        Text("Add an account to create development certificates and fresh app profiles on-device.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    ForEach(manager.accounts) { account in
                        NavigationLink { EmberAccountDetailView(accountID: account.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(account.auth.account.appleID)
                                    if manager.selectedAccountID == account.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                }
                                Text(account.selectedTeam?.name ?? "No team").font(.caption).foregroundStyle(.secondary)
                                if let inventory = manager.inventories[account.id], let team = account.selectedTeam {
                                    if let remaining = inventory.appIDsRemaining(for: team) {
                                        Text("App IDs: \(inventory.appIDs.count)/10 used, \(remaining) remaining")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("\(inventory.appIDs.count) registered App IDs")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { manager.removeAccount(account.id) } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                        }
                    }
                }
            } header: { Text("Signed-in accounts") } footer: {
                Text("Passwords are used only for Apple's sign-in request and are not saved. Auth sessions and generated signing keys are stored in this device's Keychain. Multiple accounts remain available until you remove them.")
            }

            Section("Anisette") {
                TextField("Server URL", text: $manager.anisetteServer)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("Apple Account authentication depends on Anisette data. The default uses SideStore's public service; you can enter your own compatible server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Status") {
                if manager.isBusy { ProgressView() }
                Text(manager.status).textSelection(.enabled)
            }
        }
        .navigationTitle("Apple Accounts")
        .toolbar { Button { showLogin = true } label: { Label("Add", systemImage: "plus") } }
        .sheet(isPresented: $showLogin) { EmberAccountLoginView(isPresented: $showLogin) }
        .task {
            for account in manager.accounts where manager.inventories[account.id] == nil {
                await manager.refresh(accountID: account.id)
            }
        }
    }
}

struct EmberAccountLoginView: View {
    @ObservedObject private var manager = EmberAccountManager.shared
    @Binding var isPresented: Bool
    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Account") {
                    TextField("Email", text: $appleID).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    Button("Sign in") { Task { await manager.login(appleID: appleID, password: password) } }
                        .disabled(manager.isBusy || appleID.isEmpty || password.isEmpty)
                }
                if let challenge = manager.twoFactorChallenge {
                    EmberTwoFactorView(challenge: challenge, code: $code)
                }
                Section {
                    Text(manager.status).textSelection(.enabled)
                    if manager.isBusy { ProgressView() }
                }
                Section {
                    Text("Your password is not stored. Apple may ask for a trusted-device or SMS verification code. Do not use an app-specific password unless Apple explicitly requires it for the returned error.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Apple Account")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { manager.cancelTwoFactor(); isPresented = false } } }
        }
    }
}

private struct EmberTwoFactorView: View {
    let challenge: EmberTwoFactorChallenge
    @Binding var code: String
    @ObservedObject private var manager = EmberAccountManager.shared

    var body: some View {
        Section("Two-factor authentication") {
            if let error = challenge.request.error { Text(error).foregroundStyle(.red) }
            switch challenge.request {
            case .selectDeliveryMethod(_, let phones):
                Button("Send to trusted devices") { manager.respondToTwoFactor(.requestTrustedDevice) }
                ForEach(phones) { phone in
                    Button("Text \(phone.number)") { manager.respondToTwoFactor(.requestSMS(phoneID: phone.id)) }
                    Button("Call \(phone.number)") { manager.respondToTwoFactor(.requestVoice(phoneID: phone.id)) }
                }
            case .trustedDevice:
                verificationCode
            case .sms(let phones, let activeID, _), .voice(let phones, let activeID, _):
                if let phone = phones.first(where: { $0.id == activeID }) { Text("Code sent to \(phone.number)") }
                verificationCode
            }
            Button("Cancel verification", role: .cancel) { manager.cancelTwoFactor() }
        }
    }

    private var verificationCode: some View {
        Group {
            TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
            Button("Verify") {
                let value = code
                code = ""
                manager.respondToTwoFactor(.verificationCode(value))
            }.disabled(code.isEmpty)
        }
    }
}

struct EmberAccountDetailView: View {
    @ObservedObject private var manager = EmberAccountManager.shared
    let accountID: String
    @State private var revokeCertificate: X509Certificate?
    @State private var deleteAppID: AppID?
    @State private var deleteProfile: ListedProvisioningProfile?

    private var account: EmberStoredAccount? { manager.accounts.first(where: { $0.id == accountID }) }
    private var inventory: EmberAccountInventory { manager.inventories[accountID] ?? EmberAccountInventory() }

    var body: some View {
        List {
            if let account {
                Section("Account") {
                    LabeledContent("Apple Account", value: account.auth.account.appleID)
                    Picker("Team", selection: Binding(
                        get: { account.selectedTeamID },
                        set: { value in Task { await manager.setTeam(value, for: accountID) } }
                    )) {
                        ForEach(account.teams) { team in Text("\(team.name) • \(team.type.displayName)").tag(team.identifier) }
                    }
                    Button("Use for new signing") { manager.select(accountID) }
                    if let team = account.selectedTeam, let remaining = inventory.appIDsRemaining(for: team) {
                        LabeledContent("Personal Team App IDs", value: "\(inventory.appIDs.count)/10")
                        LabeledContent("Remaining", value: String(remaining))
                        LabeledContent("Per-device active-app limit", value: "3")
                    }
                }

                Section("Certificates") {
                    if inventory.certificates.isEmpty { Text("No certificates").foregroundStyle(.secondary) }
                    ForEach(inventory.certificates, id: \.serialNumber) { certificate in
                        VStack(alignment: .leading) {
                            Text(certificate.name)
                            Text("Expires \(certificate.expiryDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(certificate.serialNumber).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Revoke", role: .destructive) { revokeCertificate = certificate } }
                    }
                }

                Section("Registered App IDs") {
                    if inventory.appIDs.isEmpty { Text("No App IDs").foregroundStyle(.secondary) }
                    ForEach(inventory.appIDs) { appID in
                        VStack(alignment: .leading) {
                            Text(appID.name)
                            Text(appID.bundleIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let expiration = appID.expirationDate { Text("Expires \(expiration.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { deleteAppID = appID } }
                    }
                }

                Section("Provisioning profiles") {
                    if inventory.profiles.isEmpty { Text("No profiles").foregroundStyle(.secondary) }
                    ForEach(inventory.profiles) { profile in
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text(profile.bundleIdentifier ?? "Unknown bundle ID").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("Expires \(profile.dateExpire.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Delete", role: .destructive) { deleteProfile = profile } }
                    }
                }
            }
            Section("Status") {
                if manager.isBusy { ProgressView() }
                Text(manager.status).textSelection(.enabled)
            }
        }
        .navigationTitle(account?.auth.account.appleID ?? "Account")
        .toolbar { Button { Task { await manager.refresh(accountID: accountID) } } label: { Image(systemName: "arrow.clockwise") } }
        .confirmationDialog("Revoke this certificate?", isPresented: Binding(get: { revokeCertificate != nil }, set: { if !$0 { revokeCertificate = nil } }), titleVisibility: .visible) {
            if let certificate = revokeCertificate {
                Button("Revoke certificate", role: .destructive) { revokeCertificate = nil; Task { await manager.revokeCertificate(certificate, accountID: accountID) } }
            }
        } message: { Text("Every app signed with this certificate may stop launching.") }
        .confirmationDialog("Delete this App ID?", isPresented: Binding(get: { deleteAppID != nil }, set: { if !$0 { deleteAppID = nil } }), titleVisibility: .visible) {
            if let appID = deleteAppID { Button("Delete App ID", role: .destructive) { deleteAppID = nil; Task { await manager.deleteAppID(appID, accountID: accountID) } } }
        } message: { Text("Apple may keep Personal Team quota occupied until the seven-day registration window expires.") }
        .confirmationDialog("Delete this profile?", isPresented: Binding(get: { deleteProfile != nil }, set: { if !$0 { deleteProfile = nil } }), titleVisibility: .visible) {
            if let profile = deleteProfile { Button("Delete profile", role: .destructive) { deleteProfile = nil; Task { await manager.deleteProfile(profile, accountID: accountID) } } }
        }
    }
}
