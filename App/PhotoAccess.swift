import Photos
import UIKit

@MainActor
enum PhotoAccess {
    private static let loader = BoundedImageLoader()
    static func image(id: String, size: CGSize = CGSize(width: 1000, height: 1000), highQuality: Bool = false) async -> UIImage? {
        await loader.image(id: id, size: size, highQuality: highQuality)
    }
    static func delete(ids: Set<String>) async throws -> Set<String> {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers:Array(ids),options:nil)
        var eligible: [PHAsset] = []
        assets.enumerateObjects { asset,_,_ in if asset.canPerform(.delete) { eligible.append(asset) } }
        guard !eligible.isEmpty else { return [] }
        let deleting = eligible
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(deleting as NSArray) }
        return Set(deleting.map(\.localIdentifier))
    }
    static func clearCache() { loader.clear() }
}

@MainActor
private final class BoundedImageLoader {
    private final class Ticket {
        var cancelled = false
        let token = UUID()
    }
    private struct Job {
        let ticket: Ticket
        let id: String
        let size: CGSize
        let quality: Bool
        let key: String
        let continuation: CheckedContinuation<UIImage?, Never>
    }
    private struct Running {
        let job: Job
        let request: PHImageRequestID
        let timeout: Task<Void, Never>
    }
    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()
    private var queue: [Job] = []
    private var active: [UUID: Running] = [:]

    init() {
        manager.allowsCachingHighQualityImages = false
        cache.totalCostLimit = 20 * 1024 * 1024
        cache.countLimit = 100
    }
    func clear() {
        cache.removeAllObjects(); manager.stopCachingImagesForAllAssets()
    }
    func image(id: String, size: CGSize, highQuality: Bool) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let edge: CGFloat = highQuality ? 2048 : 1024
        let size = CGSize(width: min(edge, size.width), height: min(edge, size.height))
        let key = "\(id):\(Int(size.width)):q\(highQuality)"
        if !highQuality, let cached = cache.object(forKey: key as NSString) { return cached }
        let ticket = Ticket()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !ticket.cancelled && !Task.isCancelled else { continuation.resume(returning: nil); return }
                let job = Job(ticket: ticket, id: id, size: size, quality: highQuality, key: key, continuation: continuation)
                if highQuality { queue.insert(job, at: 0) } else { queue.append(job) }
                pump()
            }
        }, onCancel: {
            Task { @MainActor in self.cancel(ticket) }
        })
    }
    private func cancel(_ ticket: Ticket) {
        ticket.cancelled = true
        if let index = queue.firstIndex(where: { $0.ticket.token == ticket.token }) {
            let job = queue.remove(at: index); job.continuation.resume(returning: nil)
        }
        if let running = active.removeValue(forKey: ticket.token) {
            running.timeout.cancel(); manager.cancelImageRequest(running.request)
            running.job.continuation.resume(returning: nil)
        }
        pump()
    }
    private func pump() {
        while active.count < 3 && !queue.isEmpty {
            let job = queue.removeFirst()
            guard !job.ticket.cancelled,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.id], options: nil).firstObject else {
                job.continuation.resume(returning: nil); continue
            }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.resizeMode = .exact
            options.deliveryMode = job.quality ? .highQualityFormat : .fastFormat
            let request = manager.requestImage(for: asset, targetSize: job.size, contentMode: .aspectFit, options: options) { [weak self] image, info in
                // fastFormat returns once, possibly degraded: accepting it is intentional.
                if job.quality && (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                Task { @MainActor in self?.finish(job.ticket.token, image: image) }
            }
            let timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                self?.cancel(job.ticket)
            }
            active[job.ticket.token] = Running(job: job, request: request, timeout: timeout)
        }
    }
    private func finish(_ token: UUID, image: UIImage?) {
        guard let running = active.removeValue(forKey: token) else { return }
        running.timeout.cancel()
        if !running.job.quality, let image, let cg = image.cgImage {
            cache.setObject(image, forKey: running.job.key as NSString, cost: cg.bytesPerRow * cg.height)
        }
        running.job.continuation.resume(returning: image)
        pump()
    }
}
