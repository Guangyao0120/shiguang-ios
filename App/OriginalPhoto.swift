import SwiftUI
import Photos
import QuickLook
import UniformTypeIdentifiers

@MainActor
final class OriginalPhotoLoader: ObservableObject {
    @Published var file: URL?
    @Published var loading = false
    @Published var progress = 0.0
    @Published var note: String?
    private var request: PHImageRequestID?
    private var token = UUID()
    private var timeout: Task<Void, Never>?

    func load(_ id: String, allowDownload: Bool = false) {
        cancel(); let current = UUID(); token = current
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { note = "照片不在当前授权范围内"; return }
        loading = true; note = nil; progress = 0
        let options = PHImageRequestOptions()
        options.version = .current; options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowDownload
        options.progressHandler = { [weak self] value, _, _, _ in Task { @MainActor in
            guard let self, self.token == current else { return }; self.progress = value
        } }
        request = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, type, _, info in
            if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
            Task { @MainActor in
                guard let self, self.token == current else { return }
                self.timeout?.cancel(); self.request = nil
                guard let data else { self.loading = false; self.note = "原图可能在 iCloud，可下载后查看"; return }
                let ext = type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-" + UUID().uuidString)
                let result = await Task.detached(priority: .userInitiated) { () -> URL? in
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let url = folder.appendingPathComponent("照片." + ext)
                        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                        return url
                    } catch { try? FileManager.default.removeItem(at: folder); return nil }
                }.value
                guard self.token == current else { try? FileManager.default.removeItem(at: folder); return }
                self.loading = false; self.file = result
                if result == nil { self.note = "无法准备原图，请检查可用存储空间" }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
            guard let self, self.token == current else { return }
            self.cancel(); self.note = "读取原图超时，可重试"
        }
    }
    func cancel() {
        token = UUID(); timeout?.cancel(); timeout = nil
        if let request { PHImageManager.default().cancelImageRequest(request) }; request = nil
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        file = nil; loading = false
    }
}

private struct OriginalQuickLook: UIViewControllerRepresentable {
    let url: URL
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
}

struct OriginalPhotoView: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = OriginalPhotoLoader()
    var body: some View {
        NavigationStack {
            Group {
                if let file = loader.file { OriginalQuickLook(url: file).ignoresSafeArea(edges: .bottom) }
                else {
                    VStack(spacing: 20) {
                        if loader.loading { ProgressView(); Text("读取清晰原图…"); if loader.progress > 0 { ProgressView(value: loader.progress) } }
                        if let note = loader.note {
                            Text(note).foregroundStyle(Palette.secondary)
                            Button("下载并查看原图") { loader.load(id, allowDownload: true) }.buttonStyle(QuietPrimaryButtonStyle())
                        }
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
                }
            }.navigationTitle("原图").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }.task { loader.load(id) }.onDisappear { loader.cancel() }
    }
}
