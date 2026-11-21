import CoreImage.CIFilterBuiltins
import SwiftUI

/// A scannable QR code for a URL, drawn as dark modules on a white tile.
struct QRCodeImage: View {
    private let image: UIImage?
    private let accessibilityLabel: Text

    /// Generates the code once, so redrawing the view doesn't rerun the filter.
    init(url: URL, accessibilityLabel: Text) {
        self.image = Self.makeImage(for: url.absoluteString)
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        if let image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(14)
                // Scanners expect dark modules on a light background in every appearance.
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
                .accessibilityLabel(accessibilityLabel)
        }
    }

    /// The generated image, for sharing it as a file.
    var uiImage: UIImage? { image }

    /// Scaled up by whole pixels so the modules stay sharp.
    private static func makeImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
