import SwiftUI
import Shared

struct AuthView: View {
    @State var email = ""
    @State var isLoading = false
    @State var errorMessage: String?
    @State var showMagicLinkSent = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                logoSection
                Spacer()
                oauthButtons
                divider
                magicLinkSection
                errorMessageView
                Spacer()
            }
            .padding()
            .alert("Check your email", isPresented: $showMagicLinkSent) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("We've sent a sign-in link to \(email)")
            }
        }
    }

    // MARK: - Subviews

    private var logoSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Meeting Scheduler")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Find the perfect meeting time")
                .foregroundStyle(.secondary)
        }
    }

    private var oauthButtons: some View {
        VStack(spacing: 12) {
            Button(action: signInWithGoogle) {
                HStack {
                    Image(systemName: "globe")
                    Text("Continue with Google")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(isLoading)

            Button(action: signInWithApple) {
                HStack {
                    Image(systemName: "apple.logo")
                    Text("Continue with Apple")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.black)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(isLoading)
        }
    }

    private var divider: some View {
        HStack {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
            Text("or")
                .foregroundStyle(.secondary)
                .font(.caption)
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
        }
    }

    private var magicLinkSection: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                #endif
                .disabled(isLoading)

            Button(action: signInWithMagicLink) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(isLoading ? "Sending..." : "Send Magic Link")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(isLoading || email.isEmpty)
        }
    }

    @ViewBuilder
    private var errorMessageView: some View {
        if let error = errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    // MARK: - Actions

    private func signInWithGoogle() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await AuthService.shared.signInWithGoogle()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func signInWithApple() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await AuthService.shared.signInWithApple()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func signInWithMagicLink() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await AuthService.shared.signInWithMagicLink(email: email)
                showMagicLinkSent = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    AuthView()
}
