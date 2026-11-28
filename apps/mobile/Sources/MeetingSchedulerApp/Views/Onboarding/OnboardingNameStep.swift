import SwiftUI
import Shared

/// Step 1: the name others see next to this account's poll answers.
struct OnboardingNameStep: View {
    let onContinue: (String) -> Void
    let onSkip: () -> Void

    @Environment(\.authService) private var authService
    @State private var name = ""
    /// Once the person types, a name arriving later from sign-in no longer replaces theirs.
    @State private var edited = false
    @FocusState private var fieldFocused: Bool
    @State private var focusedOnce = false
    @ScaledMetric(relativeTo: .body) private var fieldHeight = 52.0

    var body: some View {
        OnboardingStepLayout(
            step: 1,
            title: "What should people call you?",
            subtitle: "Your name shows next to your answers in polls. Leave it blank to appear as Anonymous.",
            primaryTitle: "Continue",
            onPrimary: { leave { onContinue(name) } },
            onSkip: { leave(onSkip) }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                nameField
                Text("How others will see you")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .padding(.top, 34)
                OnboardingResponsePreview(
                    name: DisplayNameInput.stored(name), avatarUrl: authService.profile?.avatarUrl
                )
                .padding(.top, 10)
            }
        }
        // Sign in with Apple saves its name just after sign-in, which can be after this appears.
        .onChange(of: authService.profile?.displayName, initial: true) { _, providerName in
            if !edited { name = providerName ?? "" }
        }
        // Only the first time, for the same reason as `leave(_:)`.
        .onAppear {
            guard !focusedOnce else { return }
            focusedOnce = true
            fieldFocused = true
        }
    }

    /// Drops focus before moving on. SwiftUI otherwise restores it on the way back, raising the
    /// keyboard mid-transition, and the pinned button then stays under the keyboard.
    private func leave(_ next: () -> Void) {
        fieldFocused = false
        next()
    }

    private var nameField: some View {
        TextField(
            "Your name",
            text: Binding(
                get: { name },
                set: {
                    name = DisplayNameInput.limited($0)
                    edited = true
                })
        )
        .font(.body)
        .textContentType(.name)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .submitLabel(.continue)
        .focused($fieldFocused)
        .onSubmit { leave { onContinue(name) } }
        .padding(.horizontal, 22)
        .frame(minHeight: fieldHeight)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                fieldFocused ? Color.brandOrange : Color(.separator), lineWidth: fieldFocused ? 1.5 : 1)
        }
    }
}

/// A poll response row showing `name` answering yes, or "Anonymous" when there is no name.
struct OnboardingResponsePreview: View {
    let name: String?
    let avatarUrl: String?

    @ScaledMetric(relativeTo: .body) private var avatarSize = 36.0
    @ScaledMetric(relativeTo: .body) private var rowHeight = 64.0

    private var shownName: String { name ?? String(localized: "Anonymous") }

    var body: some View {
        HStack(spacing: 14) {
            avatar
            Text(shownName)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 44, height: 34)
                .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: rowHeight)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(shownName), answered yes")
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarUrl, let url = URL(string: avatarUrl) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                initialCircle
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
        } else {
            initialCircle
        }
    }

    private var initialCircle: some View {
        let anonymous = name == nil
        return Text(anonymous ? "?" : String(shownName.prefix(1)).uppercased())
            .font(.body.weight(.semibold))
            .foregroundStyle(anonymous ? Color.secondary : Self.initialColor)
            .frame(width: avatarSize, height: avatarSize)
            .background(anonymous ? Color(.systemGray5) : Color.brandOrange.opacity(0.15), in: Circle())
    }

    /// A darker orange that stays readable on the light tint; the brand orange in dark mode.
    private static let initialColor = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 247 / 255, green: 147 / 255, blue: 30 / 255, alpha: 1)
                : UIColor(red: 178 / 255, green: 94 / 255, blue: 6 / 255, alpha: 1)
        })
}

#Preview("Name") {
    NavigationStack {
        OnboardingNameStep(onContinue: { _ in }, onSkip: {})
    }
    .previewServices(auth: MockAuthService.onboarding)
}

#Preview("Anonymous") {
    OnboardingResponsePreview(name: nil, avatarUrl: nil)
        .padding()
        .background(Color(.systemGroupedBackground))
}
