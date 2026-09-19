import SwiftUI
import UIKit
import UserNotifications

/// Profile, reminders, devices, and the way out.
///
/// Ordered by how often each is actually reached for: quiet hours are the one
/// setting a person changes after the first week of notifications, and account
/// deletion is at the bottom behind a typed confirmation.
struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var notifications: NotificationCoordinator

    @State private var displayName = ""
    @State private var quietStart = Date()
    @State private var quietEnd = Date()
    @State private var usesQuietHours = true

    @State private var devices: [Device] = []
    @State private var unread: Int = 0

    @State private var isSaving = false
    @State private var error: String?

    @State private var confirmSignOut = false
    @State private var showDeleteAccount = false
    @State private var showPaywall = false
    @State private var showReports = false

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { ErrorBanner(message: error) }
                }

                profile
                planSection
                reports
                reminders
                deviceSection
                about
                dangerZone
            }
            .navigationTitle("Settings")
            .refreshable { await load() }
            .task { await load() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || !hasChanges)
                }
            }
            .alert("Sign out?", isPresented: $confirmSignOut) {
                Button("Sign out", role: .destructive) { Task { await signOut() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                // States what happens to the reminders, because that is the part
                // a user cannot see: this phone stops being reachable, which is
                // the opposite of what most apps' sign-out does.
                Text("This phone stops receiving reminders. Your things and their history stay on your account and come back when you sign in again.")
            }
            .sheet(isPresented: $showDeleteAccount) {
                DeleteAccountView { await session.signOut() }
                    .environmentObject(session)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView().environmentObject(session)
            }
            .sheet(isPresented: $showReports) {
                ReportsView().environmentObject(session)
            }
        }
    }

    // MARK: - Profile

    private var profile: some View {
        Section {
            TextField("Your name", text: $displayName)
                .textInputAutocapitalization(.words)
        } header: {
            Text("You")
        } footer: {
            Text(session.user?.email ?? "Signed in with Apple.")
        }
    }

    // MARK: - Reminders

    private var reminders: some View {
        Section {
            HStack {
                Text("Notifications")
                Spacer()
                Text(notifications.authorizationDescription)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Only the system settings pane can flip a denied permission, so
                // the row goes there rather than pretending a toggle here would
                // do something.
                notifications.openSystemSettings()
            }

            Toggle("Quiet hours", isOn: $usesQuietHours)
            if usesQuietHours {
                // "From" is `quietStart`, the hour the window opens. The server's
                // own default is 20:00-08:00, so the window wraps midnight --
                // which is why these are two independent clock times rather than
                // a range, and why nothing here assumes From < Until.
                DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: $quietEnd, displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Reminders")
        } footer: {
            // The window is a real constraint on the server, not a client-side
            // mute, so the wording says what actually happens to a reminder that
            // falls inside it rather than implying it is dropped.
            Text("Hearth only sends between these hours. A reminder that comes due overnight is held and sent in the morning.")
        }
    }

    // MARK: - Devices

    private var deviceSection: some View {
        Section {
            if devices.isEmpty {
                Text("No devices registered")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deviceTitle(device))
                            .font(.subheadline)
                        Text(deviceSubtitle(device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Notifications go to")
        } footer: {
            Text("Every phone signed into your account. Signing out on a phone removes it from this list.")
        }
    }

    private func deviceTitle(_ device: Device) -> String {
        device.environment == "sandbox" ? "This iPhone (test)" : "This iPhone"
    }

    private func deviceSubtitle(_ device: Device) -> String {
        var parts: [String] = []
        if let version = device.appVersion { parts.append("Version \(version)") }
        if let seen = device.lastSeenAt, let date = HearthDate.date(seen) {
            parts.append("Last seen \(date.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Plan

    /// The upgrade row, or what is already owned.
    ///
    /// Subscribed users get a status line rather than a disabled button: the
    /// only action available to them is cancelling, and that lives in Apple's
    /// subscription settings, not here. Sending them to a paywall they cannot
    /// buy from would be worse than saying nothing.
    private var planSection: some View {
        Section {
            if session.user?.plan == "pro" {
                LabeledContent("Plan", value: "Hearth Pro")
                Link("Manage subscription",
                     destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            } else {
                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upgrade to Hearth Pro").font(.body.weight(.medium))
                            Text("Insurance report, every schedule, no limits")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Plan")
        }
    }

    // MARK: - Reports

    /// The export lives here rather than behind a toolbar icon on the asset
    /// list, because it is not an action on an asset. Nobody exports an
    /// inventory twice a week; they export it when something happened, and a
    /// rarely-used destructive-looking icon in the main flow costs more
    /// attention than it earns.
    private var reports: some View {
        Section {
            Button {
                showReports = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Insurance inventory").font(.body)
                        Text(reportSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Reports")
        }
    }

    /// Says which formats this account has, so the row is not a promise the
    /// next screen breaks. Read from the server's limits, not from a local
    /// guess about what Pro means.
    private var reportSubtitle: String {
        let exports = session.user?.limits.exports ?? []
        if exports.contains("pdf") {
            return "PDF and CSV, with photos and serial numbers"
        }
        return "CSV now. The PDF report is part of Hearth Pro."
    }

    // MARK: - About

    private var about: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.shortVersion)
            if let tier = session.user?.limits.templateTier {
                // "all" is the value the server sends; comparing against "full"
                // showed every Pro user "Standard".
                LabeledContent("Maintenance guide", value: tier == "all" ? "Full" : "Standard")
            }
            if let limits = session.user?.limits {
                LabeledContent("Things you can add", value: "\(limits.maxAssets)")
            }
            Link("Privacy policy", destination: Self.privacyURL)
            Link("Support", destination: Self.supportURL)
        } header: {
            Text("About")
        }
    }

    private static let privacyURL = URL(string: "https://hearthlegal.taomindapp.com/privacy")!
    private static let supportURL = URL(string: "https://hearthlegal.taomindapp.com/support")!

    // MARK: - Danger zone

    private var dangerZone: some View {
        Section {
            Button("Sign out") { confirmSignOut = true }
            Button("Delete my account", role: .destructive) { showDeleteAccount = true }
        }
    }

    // MARK: - Data

    /// Quiet hours come from the server's minutes-since-midnight, or from its own
    /// default window if the user has never set them. The `User` type carries the
    /// default so this screen and the scheduler agree on what "unset" means.
    private func load() async {
        if let user = session.user {
            displayName = user.displayName ?? ""
            let window = user.quietWindow
            usesQuietHours = user.quietStartMin != nil || user.quietEndMin != nil
            quietStart = Self.date(fromMinutes: window.start)
            quietEnd = Self.date(fromMinutes: window.end)
        }
        async let deviceList = try? await HearthAPI.devices()
        async let notificationList = try? await HearthAPI.notifications(unreadOnly: true)
        devices = (await deviceList)?.devices ?? []
        unread = (await notificationList)?.unread ?? 0
    }

    private static func date(fromMinutes minutes: Int) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
    }

    private static func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// Whether the Save button has anything to do.
    ///
    /// The timezone is deliberately not part of this: it is written on every
    /// sign-in and is not something the user edits here, so including it would
    /// leave Save enabled on a screen where nothing had been touched.
    private var hasChanges: Bool {
        guard let user = session.user else { return false }
        if displayName.nilIfEmpty != user.displayName { return true }
        let window = user.quietWindow
        if usesQuietHours != (user.quietStartMin != nil || user.quietEndMin != nil) { return true }
        guard usesQuietHours else { return false }
        return Self.minutes(from: quietStart) != window.start
            || Self.minutes(from: quietEnd) != window.end
    }

    /// The save is explicit rather than on-change.
    ///
    /// Each edit would otherwise be a PATCH, and the timezone in particular is
    /// written on every sign-in -- a `PATCH /me` per keystroke in the name field
    /// is both wasteful and a way to lose the last character typed.
    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            _ = try await HearthAPI.updateProfile(HearthAPI.Profile(
                displayName: displayName.nilIfEmpty,
                timezone: SessionStore.currentTimeZone,
                quietStartMin: usesQuietHours ? Self.minutes(from: quietStart) : nil,
                quietEndMin: usesQuietHours ? Self.minutes(from: quietEnd) : nil
            ))
            await session.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func signOut() async {
        // The device token goes first. Signing out is a statement that this
        // phone should stop receiving anything, and if the device row is left
        // behind the next person to hold the handset gets the previous user's
        // reminders.
        for device in devices where device.environment == Self.apnsEnvironment {
            _ = try? await HearthAPI.unregisterDevice(device.id)
        }
        await session.signOut()
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

// MARK: - Account deletion

/// Deleting the account, which is the one destructive action the app has.
///
/// It says what will be lost and what will not, in that order, and makes the
/// user type the word. The server takes a typed `"DELETE"` in the body for the
/// same reason -- a mis-routed request must not be able to trigger this.
struct DeleteAccountView: View {
    let onDeleted: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var typed = ""
    @State private var isDeleting = false
    @State private var error: String?
    /// Set once the server has deleted the account. The screen stays up and
    /// becomes its own confirmation rather than dismissing itself, because the
    /// local session has to be cleared and there may be a second thing to say.
    @State private var finished: AccountDeleteResponse?

    private let confirmation = "DELETE"

    var body: some View {
        NavigationStack {
            Form {
                if let finished {
                    deleted(finished)
                } else {
                    warning
                }
            }
            .navigationTitle(finished == nil ? "Delete account" : "Account deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if finished == nil {
                        Button("Keep my account") { dismiss() }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private var warning: some View {
        Group {
            if let error {
                Section { ErrorBanner(message: error) }
            }

            Section {
                Text("This removes your account and everything in it: every thing you have added, every photo, every repair and its cost, and the whole maintenance schedule.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("Your Home Inventory records are not recoverable. Signing in again with Apple starts a new, empty account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TextField(confirmation, text: $typed)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } header: {
                Text("Type \(confirmation) to confirm")
            }

            Section {
                Button(role: .destructive) {
                    Task { await delete() }
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting { ProgressView().controlSize(.small) }
                        Text("Delete my account")
                        Spacer()
                    }
                }
                .disabled(isDeleting || typed.uppercased() != confirmation)
            }
        }
    }

    /// Shown after the deed, and the `apple_revoked` flag is why this state
    /// exists at all.
    ///
    /// False means the local account is gone but the server could not reach
    /// Apple to revoke the grant -- so Hearth still appears under Settings >
    /// Apple ID, and the user has to remove it there. Reporting that as a
    /// silent success would leave them believing a removal that did not fully
    /// happen, and it is not an error they caused, so it is not shown as one.
    private func deleted(_ response: AccountDeleteResponse) -> some View {
        Group {
            Section {
                Label("Everything Hearth stored about you has been deleted.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
            }

            if !response.appleRevoked {
                Section {
                    Text("One thing is left to you. Apple would not confirm the sign-in was revoked, so Hearth may still be listed under Settings > Apple ID on this iPhone. Opening that screen and choosing \"Stop Using Apple ID\" removes it.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("One more step")
                }
            }
        }
    }

    private func delete() async {
        isDeleting = true
        error = nil
        defer { isDeleting = false }
        do {
            let response = try await HearthAPI.deleteAccount()
            // The session is cleared before the screen changes: the token the
            // server just invalidated must not be left in the keychain for the
            // next launch to retry with.
            await onDeleted()
            finished = response
        } catch {
            self.error = error.localizedDescription
        }
    }
}
