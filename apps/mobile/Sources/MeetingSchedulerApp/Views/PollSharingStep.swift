import CoreImage.CIFilterBuiltins
import SwiftUI
import Shared

/// The final screen of the new-poll flow: the created poll's code, link and QR code.
struct PollSharingStep: View {
    let poll: Poll
    @State private var qrImage: UIImage?

    private var link: String { "\(Config.webURL)/polls/\(poll.id)" }

    init(poll: Poll) {
        self.poll = poll
        _qrImage = State(initialValue: Self.qrImage(for: "\(Config.webURL)/polls/\(poll.id)"))
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

                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(14)
                        // Scanners expect dark modules on a light background in every appearance.
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
                        .accessibilityLabel("QR code that opens \(poll.title)")

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

    // MARK: - QR code

    /// A QR code for `text`, scaled up by whole pixels so its modules stay sharp.
    private static func qrImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
