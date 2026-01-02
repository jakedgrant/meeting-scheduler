import SwiftUI
import Shared

struct ProfileEditView: View {
    @State var authService = AuthService.shared
    @Environment(\.dismiss) var dismiss

    @State var displayName: String = ""
    @State var avatarUrl: String = ""
    @State var timezone: String = "UTC"
    @State var isSaving = false
    @State var errorMessage: String?
    @State var showSuccessAlert = false

    // Common timezones
    private let timezones = [
        "UTC",
        "America/New_York",
        "America/Chicago",
        "America/Denver",
        "America/Los_Angeles",
        "America/Phoenix",
        "America/Anchorage",
        "Pacific/Honolulu",
        "Europe/London",
        "Europe/Paris",
        "Europe/Berlin",
        "Europe/Rome",
        "Europe/Madrid",
        "Asia/Dubai",
        "Asia/Kolkata",
        "Asia/Singapore",
        "Asia/Tokyo",
        "Asia/Hong_Kong",
        "Asia/Shanghai",
        "Australia/Sydney",
        "Australia/Melbourne",
        "Pacific/Auckland",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display Name", text: $displayName)
                        .autocorrectionDisabled()

                    TextField("Avatar URL", text: $avatarUrl)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    if !avatarUrl.isEmpty, let url = URL(string: avatarUrl) {
                        HStack {
                            Spacer()
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(width: 100, height: 100)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.gray.opacity(0.2), lineWidth: 1))
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                } header: {
                    Text("Profile Information")
                } footer: {
                    Text("Your display name and avatar will be shown to other participants")
                }

                Section {
                    Picker("Timezone", selection: $timezone) {
                        ForEach(timezones, id: \.self) { tz in
                            Text(tz).tag(tz)
                        }
                    }
                } header: {
                    Text("Timezone")
                } footer: {
                    Text("Your local timezone for meeting scheduling")
                }

                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProfile()
                    }
                    .disabled(isSaving)
                }
            }
            .alert("Profile Updated", isPresented: $showSuccessAlert) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Your profile has been updated successfully")
            }
        }
        .onAppear {
            loadCurrentProfile()
        }
    }

    private func loadCurrentProfile() {
        displayName = authService.profile?.displayName ?? ""
        avatarUrl = authService.profile?.avatarUrl ?? ""
        timezone = authService.profile?.timezone ?? "UTC"
    }

    private func saveProfile() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await authService.updateProfile(
                    displayName: displayName.isEmpty ? nil : displayName,
                    avatarUrl: avatarUrl.isEmpty ? nil : avatarUrl,
                    timezone: timezone
                )

                await MainActor.run {
                    isSaving = false
                    showSuccessAlert = true
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Failed to update profile: \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    ProfileEditView()
}
