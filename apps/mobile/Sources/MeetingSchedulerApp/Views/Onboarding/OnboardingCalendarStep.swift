import SwiftUI
import Shared

/// Step 2: connect calendars so poll times can show conflicts. It reads and changes the same
/// state as the Calendar Integration section in Settings.
struct OnboardingCalendarStep: View {
    let onFinish: () -> Void

    @Environment(\.authService) private var authService
    @Environment(\.calendarService) private var calendarService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var appleConnecting = false
    /// A Google error counts as this screen's failure only after its own Connect.
    @State private var googleAttempted = false

    var body: some View {
        OnboardingStepLayout(
            step: 2,
            title: "Spot conflicts before you answer",
            subtitle: "Connect a calendar and we'll flag poll times when you're already busy.",
            primaryTitle: "Finish",
            onPrimary: onFinish,
            onSkip: onFinish
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    OnboardingCalendarRow(
                        icon: Image(systemName: "calendar"), iconColor: .blue,
                        title: "Apple Calendar", subtitle: appleSubtitle, state: appleState,
                        onConnect: connectApple, onOpenSettings: openSettings)
                    Divider().padding(.leading, OnboardingCalendarRow.textInset)
                    OnboardingCalendarRow(
                        icon: Image(systemName: "g.circle"), iconColor: .red,
                        title: "Google Calendar",
                        subtitle: "Read-only. We only see busy or free, never event details.", state: googleState,
                        onConnect: connectGoogle, onOpenSettings: {})
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                Label("You can change this anytime in Settings.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
        }
        .task(id: authService.currentUserId) {
            calendarService.refreshAppleCalendarAccess()
            await calendarService.refreshGoogleCalendarConnection()
        }
        .onChange(of: scenePhase) { _, phase in
            // Calendar access may have been turned on in Settings.
            if phase == .active { calendarService.refreshAppleCalendarAccess() }
        }
    }

    // MARK: - Apple Calendar

    private var appleState: OnboardingCalendarRow.ConnectionState {
        if appleConnecting { return .connecting }
        if calendarService.appleCalendarEnabled { return .connected }
        if calendarService.appleCalendarAccessDenied { return .denied }
        return .notConnected
    }

    private var appleSubtitle: LocalizedStringKey {
        if appleState == .denied { return "Calendar access is off. Turn it on in Settings." }
        return UIDevice.current.userInterfaceIdiom == .pad
            ? "Checked on this iPad. Nothing leaves your device."
            : "Checked on this iPhone. Nothing leaves your device."
    }

    /// Asks for calendar access only now, then turns on the same preference as Settings.
    private func connectApple() {
        appleConnecting = true
        authService.performSessionTask(
            operation: { _ in await calendarService.setAppleCalendarEnabled(true) },
            onCompletion: { appleConnecting = false })
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    // MARK: - Google Calendar

    private var googleState: OnboardingCalendarRow.ConnectionState {
        if calendarService.googleCalendarEnabled { return .connected }
        if calendarService.googleCalendarLoading { return .connecting }
        if googleAttempted, calendarService.googleCalendarError != nil { return .failed }
        return .notConnected
    }

    private func connectGoogle() {
        googleAttempted = true
        authService.performSessionTask(operation: { _ in await calendarService.setGoogleCalendarEnabled(true) })
    }
}

/// One calendar source: its icon, name and description, and the control for its state.
struct OnboardingCalendarRow: View {
    enum ConnectionState: Equatable { case notConnected, connecting, connected, denied, failed }

    static let iconWidth = 28.0
    /// Where the text column starts, which the divider between rows lines up with.
    static let textInset = 14.0 + iconWidth + 12.0

    let icon: Image
    let iconColor: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let state: ConnectionState
    let onConnect: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
            // At accessibility sizes the control moves under the text.
            let layout =
                dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if state == .failed {
                        Text("Couldn't connect. Try again.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                // The control keeps its natural width; the text column wraps instead.
                control.fixedSize()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .modifier(RowAction(name: actionName, action: action))
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .notConnected, .failed:
            capsuleButton("Connect", action: onConnect)
        case .denied:
            capsuleButton("Open Settings", action: onOpenSettings)
        case .connecting:
            ProgressView()
                .frame(minWidth: 44, minHeight: 36)
        case .connected:
            HStack(spacing: 6) {
                Image(systemName: "checkmark").fontWeight(.semibold)
                Text("Connected")
            }
                .font(.body)
                .foregroundStyle(Self.connectedText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.green.opacity(0.15), in: Capsule())
        }
    }

    private func capsuleButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .foregroundStyle(.tint)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .overlay { Capsule().strokeBorder(Color(.separator), lineWidth: 0.5) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private var actionName: LocalizedStringKey? {
        switch state {
        case .notConnected, .failed: "Connect"
        case .denied: "Open Settings"
        case .connecting, .connected: nil
        }
    }

    private var action: () -> Void {
        state == .denied ? onOpenSettings : onConnect
    }

    private var accessibilityValue: LocalizedStringKey {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .notConnected, .denied, .failed: ""
        }
    }

    /// Dark green on the light tint, a lighter green in dark mode.
    private static let connectedText = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.45, green: 0.85, blue: 0.5, alpha: 1)
                : UIColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1)
        })
}

/// Exposes the row's control as the combined element's action.
private struct RowAction: ViewModifier {
    let name: LocalizedStringKey?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let name {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, action)
                .accessibilityAction(named: Text(name), action)
        } else {
            content
        }
    }
}

#Preview("Calendars") {
    NavigationStack {
        OnboardingCalendarStep(onFinish: {})
    }
    .previewServices(auth: MockAuthService.onboarding, calendar: MockCalendarService(googleCalendarEnabled: true))
}

#Preview("Denied") {
    let calendar = MockCalendarService()
    calendar.appleCalendarAccessDenied = true
    return NavigationStack {
        OnboardingCalendarStep(onFinish: {})
    }
    .previewServices(auth: MockAuthService.onboarding, calendar: calendar)
}
