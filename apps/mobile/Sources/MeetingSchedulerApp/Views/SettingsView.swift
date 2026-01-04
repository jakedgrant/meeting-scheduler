import SwiftUI
import Shared

struct SettingsView: View {
    @State var authService = AuthService.shared
    @State var purchaseService = PurchaseService.shared
    @State var calendarService = CalendarService.shared
    @State var showPaywall = false
    @State var showProfileEdit = false
    @State var isSigningOut = false

    var body: some View {
        NavigationStack {
            List {
                // Profile Section
                Section {
                    Button {
                        showProfileEdit = true
                    } label: {
                        HStack(spacing: 12) {
                            if let avatarUrl = authService.profile?.avatarUrl,
                               !avatarUrl.isEmpty,
                               let url = URL(string: avatarUrl) {
                                AsyncImage(url: url) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Circle()
                                        .fill(Color.blue.opacity(0.2))
                                        .overlay {
                                            Text(initials)
                                                .font(.headline)
                                                .foregroundStyle(.blue)
                                        }
                                }
                                .frame(width: 50, height: 50)
                                .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 50, height: 50)
                                    .overlay {
                                        Text(initials)
                                            .font(.headline)
                                            .foregroundStyle(.blue)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(authService.currentUser?.email ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Subscription Section
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

                // Calendar Integration Section
                Section("Calendar Integration") {
                    Toggle(isOn: Binding(
                        get: { calendarService.isEnabled },
                        set: { enabled in
                            Task {
                                await calendarService.setEnabled(enabled)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-mark Conflicts")
                            Text("Automatically mark times when you're busy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if calendarService.isEnabled {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected to Apple Calendar")
                                .font(.caption)
                        }
                    }
                }

                // App Section
                Section("App") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }

                // Sign Out
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
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showProfileEdit) {
                ProfileEditView()
            }
        }
    }

    private var displayName: String {
        authService.profile?.displayName ?? authService.currentUser?.email ?? "User"
    }

    private var initials: String {
        let name = displayName
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

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

#Preview {
    SettingsView()
}
