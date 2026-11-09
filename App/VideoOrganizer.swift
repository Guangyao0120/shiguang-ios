import SwiftUI
import Photos
import Speech
import AVFoundation

private enum VideoError: LocalizedError {
    case permission, unavailable, unsupported, noAudio, tooLong, timeout, noWords
    var errorDescription: String? {
        switch self {
        case .permission: return "请在系统设置中允许拾光使用语音识别。"
        case .unavailable: return "视频不在本机，请先在苹果照片中下载原件。"
        case .unsupported: return "此语言的本机语音模型不可用；没有转为云端识别。"
        case .noAudio: return "视频没有音轨，可以手动填写标题。"
        case .tooLong: return "本次支持10分钟以内的视频，请先截取较短片段。"
        case .timeout: return "本次识别超时，可重试或手动填写标题。"
        case .noWords: return "没有识别到语音，可以手动填写标题。"
        }
    }
}

@MainActor
final class VideoTranscriber: ObservableObject {
    @Published var running = false
    @Published var status = ""
    @Published var error: String?
    private var operation: Task<Void, Never>?
    private var imageRequest: PHImageRequestID?
    private var assetContinuation: CheckedContinuation<AVAsset, Error>?
    private var speechContinuation: CheckedContinuation<String, Error>?
    private var exportContinuation: CheckedContinuation<Void, Error>?
    private var recognition: SFSpeechRecognitionTask?
    private var exporter: AVAssetExportSession?
    private var timeout: Task<Void, Never>?
    private var pendingToken = UUID()

    func start(id: String, language: String, completion: @escaping (String) -> Void) {
        guard !running else { return }
        running = true; error = nil; status = "准备本机语音识别…"
        operation = Task {
            defer { cancelPending(); running = false }
            do {
                let transcript = try await withTaskCancellationHandler(operation: {
                    try await self.transcribe(id: id, language: language)
                }, onCancel: {
                    Task { @MainActor in self.cancelPending() }
                })
                try Task.checkCancellation()
                completion(transcript)
                status = "标题与转写已保存"
            } catch {
                if Task.isCancelled { status = "已取消" }
                else { self.error = error.localizedDescription; status = "未完成" }
            }
        }
    }
    func cancel() { operation?.cancel() }

    private func transcribe(id: String, language: String) async throws -> String {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard authorization == .authorized else { throw VideoError.permission }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition else { throw VideoError.unsupported }
        let asset = try await localAsset(id: id)
        try Task.checkCancellation()
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 600 else { throw VideoError.tooLong }
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw VideoError.noAudio }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speech-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var parts: [String] = []
        let count = Int(ceil(duration / 45))
        for i in 0..<count {
            try Task.checkCancellation()
            status = "本机转写 · \(i + 1)/\(count)"
            let url = folder.appendingPathComponent("\(i).m4a")
            try await exportAudio(asset, to: url, start: Double(i * 45), duration: min(45, duration - Double(i * 45)))
            try Task.checkCancellation()
            let text = try await recognize(url, using: recognizer)
            if !text.isEmpty { parts.append(text) }
            try? FileManager.default.removeItem(at: url)
        }
        let text = parts.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VideoError.noWords }
        return String(text.prefix(60_000))
    }

    private func localAsset(id: String) async throws -> AVAsset {
        try Task.checkCancellation()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              asset.mediaType == .video else { throw VideoError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            assetContinuation = continuation
            let token = UUID(); pendingToken = token
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = false
            imageRequest = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { [weak self] value, _, _ in
                Task { @MainActor in
                    guard let self, self.pendingToken == token, let continuation = self.assetContinuation else { return }
                    self.assetContinuation = nil; self.imageRequest = nil; self.timeout?.cancel()
                    if let value { continuation.resume(returning: value) }
                    else { continuation.resume(throwing: VideoError.unavailable) }
                }
            }
            armTimeout(seconds: 20)
        }
    }

    private func exportAudio(_ asset: AVAsset, to url: URL, start: Double, duration: Double) async throws {
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw VideoError.noAudio }
        exporter = session; session.outputURL = url; session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportContinuation = continuation
            let token = UUID(); pendingToken = token
            session.exportAsynchronously { [weak self] in
                Task { @MainActor in
                    guard let self, self.pendingToken == token, let continuation = self.exportContinuation else { return }
                    self.exportContinuation = nil; self.exporter = nil; self.timeout?.cancel()
                    if session.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: session.error ?? VideoError.noAudio) }
                }
            }
            armTimeout(seconds: 60)
        }
    }

    private func recognize(_ url: URL, using recognizer: SFSpeechRecognizer) async throws -> String {
        try Task.checkCancellation()
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            speechContinuation = continuation
            let token = UUID(); pendingToken = token
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.pendingToken == token, let continuation = self.speechContinuation else { return }
                    if let result, result.isFinal {
                        self.speechContinuation = nil; self.recognition = nil; self.timeout?.cancel()
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    } else if let error {
                        self.speechContinuation = nil; self.recognition = nil; self.timeout?.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }
            armTimeout(seconds: 90)
        }
    }
    private func armTimeout(seconds: UInt64) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            self?.cancelPending(error: VideoError.timeout)
        }
    }
    private func cancelPending(error: Error = CancellationError()) {
        pendingToken = UUID()
        timeout?.cancel(); timeout = nil
        let asset = assetContinuation; assetContinuation = nil
        let speech = speechContinuation; speechContinuation = nil
        let exported = exportContinuation; exportContinuation = nil
        if let imageRequest { PHImageManager.default().cancelImageRequest(imageRequest) }
        imageRequest = nil; recognition?.cancel(); recognition = nil; exporter?.cancelExport(); exporter = nil
        asset?.resume(throwing: error); speech?.resume(throwing: error); exported?.resume(throwing: error)
    }
}

struct VideoOrganizeView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var transcriber = VideoTranscriber()
    @State private var title = ""
    @State private var language = "zh-CN"
    let id: String
    var body: some View {
        NavigationStack {
            Form {
                Section("小标题") {
                    TextField("例如：桐桐 · 生日祝福", text: $title)
                    Button("保存标题") { store.setVideoTitle(id, title: title) }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcriber.running)
                }
                Section {
                    Picker("语音语言", selection: $language) {
                        Text("普通话").tag("zh-CN")
                        Text("英语").tag("en-US")
                    }.disabled(transcriber.running)
                    Button(transcriber.running ? "正在转写…" : "本地转写并生成标题") {
                        store.pause()
                        transcriber.start(id: id, language: language) { text in
                            store.applyVideoTranscript(id, text: text)
                            title = store.state.records[id]?.videoTitle ?? ""
                        }
                    }.disabled(transcriber.running || store.busy || store.scanning)
                    if transcriber.running { ProgressView(); Button("取消") { transcriber.cancel() } }
                    if !transcriber.status.isEmpty { Text(transcriber.status).foregroundStyle(Palette.secondary) }
                    if let error = transcriber.error { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("仅转写本机视频，最长10分钟，不上传音频。首次需授权；模型不可用时不会转为云端识别。")
                }
                if let transcript = store.state.records[id]?.voiceTranscript, !transcript.isEmpty {
                    Section {
                        DisclosureGroup("查看转写文字") { Text(transcript).textSelection(.enabled) }
                        Text("未明确提到姓名时，标题会保留「对象待确认」。转写可能出错，可自行修改标题。")
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }
            }.paperList().navigationTitle("视频标题").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
        .onAppear { title = store.state.records[id]?.videoTitle ?? "" }
        .onDisappear { transcriber.cancel() }
        .onChange(of: phase) { _, phase in if phase != .active { transcriber.cancel() } }
    }
}
