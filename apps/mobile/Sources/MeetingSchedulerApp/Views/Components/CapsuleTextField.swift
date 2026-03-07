import SwiftUI

struct CapsuleTextField<ButtonContent: View>: View {
    let placeholder: String
    @Binding var text: String
    let action: () -> Void
    @ViewBuilder let buttonContent: () -> ButtonContent

    var body: some View {
        HStack(spacing: 0) {
            TextField(placeholder, text: $text)
                .padding(.leading, 16)
                .padding(.vertical, 8)

            if !text.isEmpty {
                Button(action: action) {
                    buttonContent()
                        .frame(width: 36, height: 36)
                        .background(.tint)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }
                .padding(4)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .background(
            Capsule()
                .strokeBorder(.tertiary, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: text.isEmpty)
    }
}

#Preview("Empty") {
    CapsuleTextField(placeholder: "Email", text: .constant(""), action: {}) {
        Image(systemName: "arrow.right")
            .fontWeight(.semibold)
    }
    .padding()
}

#Preview("With Text") {
    CapsuleTextField(placeholder: "Email", text: .constant("jake@example.com"), action: {}) {
        Image(systemName: "arrow.right")
            .fontWeight(.semibold)
    }
    .padding()
}
