import Foundation

// Every entry point freezes the same ordered list when review starts. The
// collection behind it may change as photos are staged or restored.
struct ReviewSession: Identifiable {
    let id = UUID()
    let ids: [String]
    init(ids: [String]) {
        var seen: Set<String> = []
        self.ids = ids.filter { seen.insert($0).inserted }
    }
}
