import SwiftUI
import Shared

struct SettingsView: View {
    @Environment(\.authService) var authService
    @Environment(\.purchaseService) var purchaseService
    @Environment(\.calendarService) var calendarService
    @State var showPaywall = false
    @State var showProfileEdit = false
    @State var isSigningOut = false

    private var displayName: String {
        authService.profile?.displayName ?? authService.currentUserEmail ?? "User"
    }

    private var initials: String {
        let name = displayName
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                subscriptionSection
                calendarIntegrationSection
                appSection
                signOutSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showProfileEdit) {
                ProfileEditView()
            }
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        Section {
            Button {
                showProfileEdit = true
            } label: {
                ProfileRow(
                    avatarUrl: authService.profile?.avatarUrl,
                    displayName: displayName,
                    email: authService.currentUserEmail ?? "",
                    initials: initials
                )
            }
        }
    }

    private var subscriptionSection: some View {
        Section("Subscription") {
            if purchaseService.hasProAccess {
                HStack {
                    Label("Pro", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                    Spacer()
                    Text("Active")
                        .foregroundStyle(.green)
                }
            } else {
                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        Label("Upgrade to Pro", systemImage: "star")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Restore Purchases") {
                restorePurchases()
            }
        }
    }

    private var calendarIntegrationSection: some View {
        Section("Calendar Integration") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Select calendar sources to check for conflicts")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                AppleCalendarToggle()
                GoogleCalendarToggle()

                if calendarService.googleCalendarLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Checking Google Calendar connection...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var appSection: some View {
        Section("App") {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                signOut()
            } label: {
                HStack {
                    Spacer()
                    if isSigningOut {
                        ProgressView()
                    } else {
                        Text("Sign Out")
                    }
                    Spacer()
                }
            }
            .disabled(isSigningOut)
        }
    }

    // MARK: - Actions

    private func signOut() {
        isSigningOut = true

        Task {
            do {
                try await authService.signOut()
            } catch {
                print("Sign out failed: \(error)")
            }
            isSigningOut = false
        }
    }

    private func restorePurchases() {
        Task {
            do {
                _ = try await purchaseService.restorePurchases()
            } catch {
                print("Restore failed: \(error)")
            }
        }
    }
}

// MARK: - ProfileRow

struct ProfileRow: View {
    let avatarUrl: String?
    let displayName: String
    let email: String
    let initials: String

    var body: some View {
        HStack(spacing: 12) {
            avatarView
            userInfo
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatarUrl = avatarUrl,
           !avatarUrl.isEmpty,
           let url = URL(string: avatarUrl) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                initialsAvatar
            }
            .frame(width: 50, height: 50)
            .clipShape(Circle())
        } else {
            initialsAvatar
        }
    }

    private var initialsAvatar: some View {
        Circle()
            .fill(Color.blue.opacity(0.2))
            .frame(width: 50, height: 50)
            .overlay {
                Text(initials)
                    .font(.headline)
                    .foregroundStyle(.blue)
            }
    }

    private var userInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(email)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AppleCalendarToggle

struct AppleCalendarToggle: View {
    @Environment(\.calendarService) var calendarService

    var body: some View {
        Toggle(isOn: Binding(
            get: { calendarService.appleCalendarEnabled },
            set: { enabled in
                Task {
                    await calendarService.setAppleCalendarEnabled(enabled)
                }
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Calendar")
                        .font(.body)
                    Text("Local device calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - GoogleCalendarToggle

struct GoogleCalendarToggle: View {
    @Environment(\.calendarService) var calendarService

    var body: some View {
        Toggle(isOn: Binding(
            get: { calendarService.googleCalendarEnabled },
            set: { enabled in
                Task {
                    await calendarService.setGoogleCalendarEnabled(enabled)
                }
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Calendar")
                        .font(.body)
                    if calendarService.googleCalendarEnabled {
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(calendarService.googleCalendarLoading)
    }
}

#Preview("Signed In") {
    SettingsView()
        .environment(\.authService, MockAuthService.signedIn)
        .environment(\.purchaseService, MockPurchaseService.free)
        .environment(\.calendarService, MockCalendarService.disabled)
}

#Preview("Pro User") {
    SettingsView()
        .environment(\.authService, MockAuthService.signedIn)
        .environment(\.purchaseService, MockPurchaseService.pro)
        .environment(\.calendarService, MockCalendarService.allEnabled)
}
