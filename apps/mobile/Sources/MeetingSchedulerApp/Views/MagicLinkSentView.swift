import SwiftUI

struct MagicLinkSentView: View {
    let email: String
    let onChangeEmail: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "envelope.badge")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Check your email")
                .font(.title)
                .fontWeight(.bold)

            Text("We've sent a sign-in link to **\(email)**")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Change Email", action: onChangeEmail)
                .padding(.bottom)
        }
        .padding()
        .navigationBarBackButtonHidden()
    }
}

#Preview {
    NavigationStack {
        MagicLinkSentView(email: "jake@example.com") {}
    }
}
