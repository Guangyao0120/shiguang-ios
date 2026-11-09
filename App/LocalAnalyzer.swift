import UIKit
import Vision
import Photos
import ImageIO

struct AnalysisResult {
    var tags: Set<PhotoTag>
    var text: String
    var reasons: [String]
    var hash: UInt64?
    var labels: [String]
}

enum LocalAnalyzer {
    private static let queue = DispatchQueue(label: "shiguang.vision", qos: .utility)
    private final class Job<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T,Error>?
        private var requests: [VNRequest] = []
        private var ended = false
        func begin(_ value: CheckedContinuation<T,Error>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if ended { value.resume(throwing:CancellationError()); return false }
            continuation = value; return true
        }
        func attach(_ values: [VNRequest]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !ended else { return false }; requests = values; return true
        }
        func finish(_ result: Result<T,Error>,cancel: Bool = false) {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            let value = continuation, active = requests
            continuation = nil; requests = []; lock.unlock()
            if cancel { active.forEach { $0.cancel() } }
            value?.resume(with:result)
        }
    }
    private static func perform<T>(_ body: @escaping (Job<T>) throws -> T) async throws -> T {
        let job = Job<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard job.begin(continuation) else { return }
                let timeout = DispatchWorkItem { job.finish(.failure(AnalyzerError.timeout),cancel:true) }
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+45,execute:timeout)
                queue.async {
                    defer { timeout.cancel() }
                    autoreleasepool {
                        do { job.finish(.success(try body(job))) }
                        catch { job.finish(.failure(error)) }
                    }
                }
            }
        } onCancel: { job.finish(.failure(CancellationError()),cancel:true) }
    }
    static func analyze(_ image: UIImage, screenshot: Bool, video: Bool, cpuOnly: Bool = false) async throws -> AnalysisResult {
        try await perform { job in
                        let faces = VNDetectFaceRectanglesRequest()
                        let classification = VNClassifyImageRequest()
                        let textRequest = VNRecognizeTextRequest()
                        textRequest.recognitionLevel = .accurate
                        textRequest.recognitionLanguages = ["zh-Hans","en-US"]
                        textRequest.usesLanguageCorrection = false
                        guard job.attach([faces,classification,textRequest]) else { throw CancellationError() }
                        guard let cg = image.cgImage else { throw AnalyzerError.invalidImage }
                        faces.usesCPUOnly = cpuOnly; classification.usesCPUOnly = cpuOnly; textRequest.usesCPUOnly = cpuOnly
                        let handler = VNImageRequestHandler(cgImage:cg,orientation:image.visionOrientation,options:[:])
                        if screenshot { try handler.perform([faces,classification,textRequest]) }
                        else { try handler.perform([faces,classification]) }
                        let labels = (classification.results ?? []).filter { $0.confidence >= 0.2 }
                            .prefix(12).map(\.identifier)
                        var text = ""
                        // Most camera photos do not need expensive OCR. Screenshots and
                        // document-like photos keep accurate Chinese OCR.
                        if screenshot || labels.contains(where: { $0.contains("document") || $0.contains("receipt") || $0.contains("text") }) {
                            if !screenshot { try handler.perform([textRequest]) }
                            text = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                        }
                        let (tags, reasons) = CategoryRules.classify(text: text, screenshot: screenshot,
                            faces: faces.results?.count ?? 0, labels: labels, isVideo: video)
                        return AnalysisResult(tags: tags, text: text,
                            reasons: reasons, hash: video ? nil : differenceHash(cg), labels: Array(labels))
        }
    }

    static func sceneryLabels(_ image: UIImage, cpuOnly: Bool) async throws -> [String] {
        try await perform { job in
            let classification = VNClassifyImageRequest()
            guard job.attach([classification]) else { throw CancellationError() }
            guard let cg = image.cgImage else { throw AnalyzerError.invalidImage }
            classification.usesCPUOnly = cpuOnly
            try VNImageRequestHandler(cgImage:cg,orientation:image.visionOrientation,options:[:]).perform([classification])
            return Array((classification.results ?? []).filter { $0.confidence >= 0.2 }.prefix(12).map(\.identifier))
        }
    }

    private static func differenceHash(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        return pixels.withUnsafeMutableBytes { buffer -> UInt64? in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8,
                bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            var hash: UInt64 = 0
            let bytes = buffer.bindMemory(to: UInt8.self)
            for row in 0..<8 {
                for column in 0..<8 {
                    if bytes[row * 9 + column] > bytes[row * 9 + column + 1] {
                        hash |= UInt64(1) << (row * 8 + column)
                    }
                }
            }
            // Flat graphics give no meaningful fingerprint and flood candidate pairs.
            let bits = hash.nonzeroBitCount
            return bits >= 4 && bits <= 60 ? hash : nil
        }
    }
    enum AnalyzerError: Error { case invalidImage, timeout }
}

extension UIImage {
    var visionOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
