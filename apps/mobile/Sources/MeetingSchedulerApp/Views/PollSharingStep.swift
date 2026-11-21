import SwiftUI
import Shared

/// The final screen of the new-poll flow: the created poll's code, link and QR code.
struct PollSharingStep: View {
    let poll: Poll
    private let qrCode: QRCodeImage?

    private var link: String { "\(Config.webURL)/polls/\(poll.id)" }

    init(poll: Poll) {
        self.poll = poll
        qrCode = URL(string: "\(Config.webURL)/polls/\(poll.id)").map {
            QRCodeImage(url: $0, accessibilityLabel: Text("QR code that opens \(poll.title)"))
        }
    }

    var body: some View {
        Form {
            header
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            codeSection
            linkSection
            qrSection
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.orange, in: Circle())
                .accessibilityHidden(true)

            Text("Poll created")
                .font(.title.bold())

            Text("\(poll.title) is live. Share it any way you like.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var codeSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack {
                    Text("Share code")
                        .font(.headline)
                    Spacer()
                    CopyButton { UIPasteboard.general.string = poll.shareCode }
                }

                Text(poll.shareCode)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Share code \(poll.shareCode.map(String.init).joined(separator: " "))")

                Text("People can enter this code to join your poll.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
    }

    private var linkSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack {
                    Text("Share link")
                        .font(.headline)
                    Spacer()
                    CopyButton { UIPasteboard.general.string = link }
                }

                Text(link)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                if let url = URL(string: link) {
                    ShareLink(item: url, message: Text("Join my poll: \(poll.title)")) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var qrSection: some View {
        Section {
            VStack(spacing: 14) {
                Text("QR code")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let qrCode, let qrImage = qrCode.uiImage {
                    qrCode
                        .frame(width: 228, height: 228)

                    ShareLink(
                        item: Image(uiImage: qrImage),
                        preview: SharePreview("QR code for \(poll.title)", image: Image(uiImage: qrImage))
                    ) {
                        Label("Share QR code", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
