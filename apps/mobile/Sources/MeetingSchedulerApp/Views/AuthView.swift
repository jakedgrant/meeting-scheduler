import SwiftUI
import Shared

struct AuthView: View {
    @Environment(\.authService) var authService

    @State var email = ""
    @State var isLoading = false
    @State var errorMessage: String?
    @State var showMagicLinkSent = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                logoHeader
                oauthButtons
                    .padding(.top, 8)
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
    
    private var logoHeader: some View {
        Group {
            LogoTitle()
            
            Text("Find the perfect meeting time")
                .foregroundStyle(.secondary)
                .fontDesign(.serif)
                .font(.title2)
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
                .padding(8)
            }
            .disabled(isLoading)
            .buttonStyle(.borderedProminent)

            Button(action: signInWithApple) {
                HStack {
                    Image(systemName: "apple.logo")
                    Text("Continue with Apple")
                }
                .frame(maxWidth: .infinity)
                .padding(8)
                .foregroundStyle(.white)
            }
            .disabled(isLoading)
            .buttonStyle(.borderedProminent)
            .tint(.black)
        }
    }

    private var divider: some View {
        ZStack(alignment: .center) {
            Divider()
            Text("or")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(8)
                .background(.background)
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
                .padding(8)
            }
            .disabled(isLoading || email.isEmpty)
            .buttonStyle(.borderedProminent)
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
                try await authService.signInWithGoogle()
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
                try await authService.signInWithApple()
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
                try await authService.signInWithMagicLink(email: email)
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
        .environment(\.authService, MockAuthService.signedOut)
}
