import UIKit

@MainActor
final class ScanRun {
    let id = UUID()
    let images: ScanImagePrefetcher
    let completion: ((Bool,Int)->Void)?
    let completedBefore: Int
    let total: Int
    var updates: [MediaRecord] = []
    var handled = 0
    var stopReason: String?
    var failures = 0
    var measurements = ScanMeasurements()
    let started = Date()
    init(records: [MediaRecord],completedBefore: Int,total: Int,loader: @escaping (MediaRecord) async -> UIImage?,completion: ((Bool,Int)->Void)?) {
        images = ScanImagePrefetcher(records:records,loader:loader)
        self.completedBefore = completedBefore; self.total = total; self.completion = completion
    }
}

struct ReviewPreview: Identifiable {
    let id: String
    let wasPending: Bool
}

enum PendingSelection {
    static func valid(_ selected: Set<String>,pending: Set<String>,visible: Set<String>) -> Set<String> {
        selected.intersection(pending).intersection(visible)
    }
}
