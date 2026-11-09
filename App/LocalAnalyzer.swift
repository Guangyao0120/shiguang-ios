import UIKit
import Vision
import Photos

struct AnalysisResult {
    var tags: Set<PhotoTag>
    var text: String
    var reasons: [String]
    var hash: UInt64?
}

enum LocalAnalyzer {
    private static let queue = DispatchQueue(label: "shiguang.vision", qos: .utility)

    static func analyze(_ image: UIImage, screenshot: Bool, video: Bool) async throws -> AnalysisResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                autoreleasepool {
                    do {
                        guard let cg = image.cgImage else { throw AnalyzerError.invalidImage }
                        let textRequest = VNRecognizeTextRequest()
                        textRequest.recognitionLevel = .accurate
                        textRequest.recognitionLanguages = ["zh-Hans", "en-US"]
                        textRequest.usesLanguageCorrection = true
                        let faces = VNDetectFaceRectanglesRequest()
                        let classification = VNClassifyImageRequest()
                        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                        try handler.perform([textRequest, faces, classification])
                        let text = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .joined(separator: "\n")
                        let labels = (classification.results ?? []).filter { $0.confidence >= 0.2 }
                            .prefix(12).map(\.identifier)
                        let (tags, reasons) = CategoryRules.classify(text: text, screenshot: screenshot,
                            faces: faces.results?.count ?? 0, labels: labels, isVideo: video)
                        continuation.resume(returning: AnalysisResult(tags: tags, text: text,
                            reasons: reasons, hash: video ? nil : differenceHash(cg)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
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
    enum AnalyzerError: Error { case invalidImage }
}

enum PhotoAccess {
    static func image(id: String, size: CGSize = CGSize(width: 1400, height: 1400)) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                continuation.resume(returning: image)
            }
        }
    }
}
