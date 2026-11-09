import Foundation

// Every entry point freezes the same ordered list when review starts. The
// collection behind it may change as photos are staged or restored.
struct ReviewSession: Identifiable {
    let id = UUID()
    let ids: [String]
    let startID: String?
    init(ids: [String],startID: String? = nil) {
        var seen: Set<String> = []
        let ordered = ids.filter { seen.insert($0).inserted }
        self.ids = ordered
        self.startID = startID.flatMap { ordered.contains($0) ? $0 : nil }
    }
}
