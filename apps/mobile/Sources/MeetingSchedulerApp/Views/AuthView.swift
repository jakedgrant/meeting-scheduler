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
            .navigationDestination(isPresented: $showMagicLinkSent) {
                MagicLinkSentView(email: email) {
                    showMagicLinkSent = false
                }
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
        CapsuleTextField(placeholder: "Email", text: $email, action: signInWithMagicLink) {
            if isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: "arrow.right")
                    .fontWeight(.semibold)
            }
        }
        .textContentType(.emailAddress)
        #if os(iOS)
        .keyboardType(.emailAddress)
        .autocapitalization(.none)
        #endif
        .disabled(isLoading)
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
        authService.performSessionTask(
            operation: { _ in try await authService.signInWithGoogle() },
            onFailure: { errorMessage = $0.localizedDescription },
            onCompletion: { isLoading = false }
        )
    }

    private func signInWithApple() {
        isLoading = true
        errorMessage = nil
        authService.performSessionTask(
            operation: { _ in try await authService.signInWithApple() },
            onFailure: { errorMessage = $0.localizedDescription },
            onCompletion: { isLoading = false }
        )
    }

    private func signInWithMagicLink() {
        isLoading = true
        errorMessage = nil
        authService.performSessionTask(
            operation: { _ in try await authService.signInWithMagicLink(email: email) },
            onSuccess: { _ in showMagicLinkSent = true },
            onFailure: { errorMessage = $0.localizedDescription },
            onCompletion: { isLoading = false }
        )
    }

}

#Preview {
    AuthView()
        .environment(\.authService, MockAuthService.signedOut)
}
