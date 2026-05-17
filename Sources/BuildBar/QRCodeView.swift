import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit

struct QRCodeView: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Text("Scan to install")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            if let img = generate(text) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
            } else {
                Text("Failed to generate QR code")
                    .font(.caption)
                    .frame(width: 220, height: 220)
            }
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: 240)
            Button("Copy link") {
                BuildAction.copy(text)
            }
            .font(.caption)
        }
        .padding(16)
    }

    private func generate(_ s: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
    }
}
