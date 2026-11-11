import SwiftUI

/// A button label whose icon follows the button's foreground style. A `Label` inside a `Form`
/// tints its icon with the accent color, which matches a prominent button's background and
/// hides the icon.
struct ProminentButtonLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(title)
        }
    }
}
