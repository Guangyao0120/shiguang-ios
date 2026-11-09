import UIKit

// One in-flight read while Vision works on the current image. Never queues an
// entire library, and cancellation also cancels the PhotoKit request.
@MainActor
final class ScanImagePrefetcher {
    private let records: [MediaRecord]
    private let loader: (MediaRecord) async -> UIImage?
    private var position = 0
    private var cancelled = false
    private var pending: Task<UIImage?, Never>?
    init(records: [MediaRecord], loader: @escaping (MediaRecord) async -> UIImage? = { record in
        let edge: CGFloat = record.isScreenshot ? 1024 : 640
        return await PhotoAccess.image(id:record.id,size:CGSize(width:edge,height:edge),highQuality:true)
    }) {
        self.records = records; self.loader = loader
        if let first = records.first { pending = Task { await loader(first) } }
    }
    func next() async -> UIImage? {
        guard !cancelled, let pending else { return nil }
        let image = await pending.value
        guard !cancelled, !Task.isCancelled else { cancel(); return nil }
        position += 1
        if position < records.count {
            let record = records[position], loader = loader
            self.pending = Task { await loader(record) }
        } else { self.pending = nil }
        return image
    }
    func cancel() { cancelled = true; pending?.cancel(); pending = nil }
}

struct ScanMeasurements: Codable {
    var timestamp = Date()
    var elapsed = 0.0
    var handled = 0
    var recognized = 0
    var photoWaitSeconds = 0.0
    var visionSeconds = 0.0
    var screenshots = 0
    var phase = "running"
}
