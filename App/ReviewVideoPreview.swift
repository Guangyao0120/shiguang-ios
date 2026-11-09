import SwiftUI
import Photos
import AVKit

@MainActor
private final class ReviewVideoLoader: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = false
    @Published var note = ""
    private var request: PHImageRequestID?
    private var token = UUID()
    private var timeout: Task<Void,Never>?
    func load(id: String, download: Bool = false) {
        cancel(); let token = UUID(); self.token = token; loading = true; note = ""
        if DesignPreview.enabled { loading = false; note = "示例视频预览"; return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers:[id],options:nil).firstObject else {
            loading = false; note = "视频暂时不可访问"; return
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = download; options.deliveryMode = .highQualityFormat
        request = PHImageManager.default().requestPlayerItem(forVideo:asset,options:options) { [weak self] item,_ in
            Task { @MainActor in
                guard let self, self.token == token else { return }
                self.timeout?.cancel(); self.timeout = nil; self.request = nil; self.loading = false
                if let item { self.player = AVPlayer(playerItem:item) }
                else { self.note = "原视频可能在 iCloud，可下载后查看。" }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(download ? 90 : 15)) } catch { return }
            guard let self, self.token == token else { return }
            self.cancel(); self.note = "读取超时，可稍后重试。"
        }
    }
    func cancel() {
        token = UUID(); timeout?.cancel(); timeout = nil
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil; player?.pause(); player = nil; loading = false
    }
}

struct ReviewVideoPreview: View {
    let id: String
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = ReviewVideoLoader()
    var body: some View {
        NavigationStack {
            Group {
                if let player = loader.player { VideoPlayer(player:player) }
                else {
                    VStack(spacing:20) {
                        if loader.loading { ProgressView() }
                        if !loader.note.isEmpty { Text(loader.note).foregroundStyle(Palette.secondary) }
                        if !loader.loading && !DesignPreview.enabled {
                            Button("下载并播放原视频") { loader.load(id:id,download:true) }.buttonStyle(.bordered)
                        }
                    }.padding().frame(maxWidth:.infinity,maxHeight:.infinity).background(AlbumCanvas())
                }
            }.navigationTitle("视频").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {
                        Button("完成") { dismiss() }.accessibilityIdentifier("review.preview.close")
                    }
                    ToolbarItem(placement:.primaryAction) {
                        Button(store.state.pending.contains(id) ? "恢复" : "待删",role:store.state.pending.contains(id) ? nil : .destructive) {
                            if store.state.pending.contains(id) { store.restore(id) } else { store.stage(id) }
                        }
                    }
                }
        }.task { loader.load(id:id) }.onDisappear { loader.cancel() }
    }
}
