import SwiftUI

struct JoinByCodeSheet: View {
    @Binding var joinCode: String
    @Binding var joinError: String?
    @Binding var isJoining: Bool
    let onJoin: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ABC123", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Share Code")
                } footer: {
                    Text("Enter the 6-character code shared by the poll creator")
                }

                if let error = joinError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(action: onJoin) {
                        if isJoining {
                            ProgressView()
                        } else {
                            Text("Join Poll")
                        }
                    }
                    .disabled(isJoining || joinCode.count != 6)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Join by Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        onDismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
