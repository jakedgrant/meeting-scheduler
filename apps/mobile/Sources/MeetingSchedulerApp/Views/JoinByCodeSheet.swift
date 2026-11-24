import SwiftUI

struct JoinByCodeSheet: View {
    @Binding var joinCode: String
    @Binding var joinError: String?
    @Binding var isJoining: Bool
    var invitationCode: String? = nil
    let onJoin: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let invitationCode {
                        Text(invitationCode)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        TextField("ABC123", text: $joinCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                } header: {
                    Text("Share Code")
                } footer: {
                    if invitationCode != nil { Text("Do you want to join this poll?") }
                    else { Text("Enter the 6-character code shared by the poll creator") }
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
            .navigationTitle(invitationCode == nil ? Text("Join by Code") : Text("Join Poll"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        onDismiss()
                    }
                    .disabled(isJoining)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isJoining)
    }
}
