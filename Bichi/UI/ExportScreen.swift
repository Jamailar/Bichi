import CoreImage
import Photos
import SwiftUI

/// 4 导出 — before/after, save full resolution to Photos.
struct ExportScreen: View {
    @ObservedObject var session: EditSession
    @EnvironmentObject private var model: AppModel
    @State private var showOriginal = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button { model.path.removeLast() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("返回")
                Spacer()
                Text("导出").font(.system(size: 17, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)

            Group {
                if let img = showOriginal ? session.previewOriginal : session.preview {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                }
            }
            .frame(maxHeight: .infinity)
            .onLongPressGesture(minimumDuration: 0, pressing: { showOriginal = $0 }, perform: {})

            Text("按住图片查看原图").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            if let message { Text(message).font(.system(size: 13)).foregroundStyle(Theme.accent) }

            Button(action: save) {
                Text(saving ? "正在保存…" : "保存到相册")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent))
                    .foregroundStyle(Theme.background)
            }
            .disabled(saving)
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            guard let out = await session.renderFull() else { return }
            do {
                let data = try PhotoExporter.heif(out, properties: session.original.properties)
                try await PhotoExporter.saveToLibrary(data)
                message = "已保存到相册"
            } catch {
                message = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

enum PhotoExporter {
    /// 10-bit HEIF in Display P3, keeping the source metadata (minus the
    /// orientation, which is already applied to the pixels).
    static func heif(_ image: CIImage, properties: [String: Any]) throws -> Data {
        var props = properties
        props[kCGImagePropertyOrientation as String] = 1
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let tagged = image.settingProperties(props)
        return try EditSession.context.heif10Representation(of: tagged, colorSpace: p3, options: [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92,
        ])
    }

    static func saveToLibrary(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CocoaError(.userCancelled) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
