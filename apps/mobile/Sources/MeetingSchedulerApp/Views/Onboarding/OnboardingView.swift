import SwiftUI
import Shared

/// The two optional steps after an account's first sign-in: a display name, then calendars.
/// Skip on the name step moves on; Finish or Skip on the calendar step completes onboarding.
struct OnboardingView: View {
    private enum Step: Hashable { case calendars }

    @Environment(\.authService) private var authService
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            OnboardingNameStep(
                onContinue: { name in
                    authService.saveOnboardingName(name)
                    path = [.calendars]
                },
                onSkip: { path = [.calendars] }
            )
            .navigationDestination(for: Step.self) { _ in
                OnboardingCalendarStep(onFinish: { authService.completeOnboarding() })
                    .modifier(BackSwipe { path = [] })
            }
        }
    }
}

/// Goes back with a rightward swipe from the leading edge, or VoiceOver's escape gesture. Hiding
/// the navigation bar also turns off the system's back swipe, and the steps show no back button.
private struct BackSwipe: ViewModifier {
    let back: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 20).onEnded { drag in
                    let fromEdge = drag.startLocation.x < 44
                    let rightward = drag.translation.width > 80 && abs(drag.translation.height) < drag.translation.width
                    if fromEdge && rightward { back() }
                })
            .accessibilityAction(.escape, back)
    }
}

extension Color {
    /// Meetful's orange, #F7931E.
    static let brandOrange = Color(red: 247 / 255, green: 147 / 255, blue: 30 / 255)
}

/// The chrome both steps share: the step header and progress bar, the serif title and
/// subtitle above scrolling content, and the primary button pinned to the bottom.
struct OnboardingStepLayout<Content: View>: View {
    static var stepCount: Int { 2 }

    let step: Int
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let primaryTitle: LocalizedStringKey
    let onPrimary: () -> Void
    let onSkip: () -> Void
    @ViewBuilder let content: () -> Content

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 30.0
    @ScaledMetric(relativeTo: .body) private var buttonHeight = 54.0

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: titleSize, design: .serif))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    content()
                        .padding(.top, 28)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) { primaryButton }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Step \(step) of \(Self.stepCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip", action: onSkip)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(1...Self.stepCount, id: \.self) { segment in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment <= step ? Color.brandOrange : Color(.systemGray5))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var primaryButton: some View {
        Button(action: onPrimary) {
            Text(primaryTitle)
                .font(.headline)
                .foregroundStyle(Color(.systemBackground))
                .frame(maxWidth: .infinity, minHeight: buttonHeight)
                .background(Color.primary, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview("Onboarding") {
    OnboardingView()
        .previewServices(auth: MockAuthService.onboarding)
}
