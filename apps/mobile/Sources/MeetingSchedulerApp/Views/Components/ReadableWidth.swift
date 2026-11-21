import SwiftUI

extension View {
    /// Centers the content and caps its width, so full-width controls stay a
    /// comfortable size in wide windows such as an open iPhone Duo or an iPad.
    func readableWidth() -> some View {
        frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
    }
}
