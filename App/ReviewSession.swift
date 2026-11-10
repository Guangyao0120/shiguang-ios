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

// Preserve the album's original order, but keep pending and missing assets out
// of both navigation directions and the visible count. Reconcile only on data
// changes, never while the finger is moving.
struct ReviewQueue {
    private let original: [String]
    private(set) var ids: [String]
    private(set) var index: Int
    var current: String? { ids.indices.contains(index) ? ids[index] : nil }
    init(ids: [String],startID: String? = nil) {
        let session = ReviewSession(ids:ids,startID:startID)
        original = session.ids; self.ids = session.ids
        index = session.startID.flatMap { session.ids.firstIndex(of:$0) } ?? 0
    }
    mutating func synchronize(records: [String:MediaRecord],pending: Set<String>,preferred: String? = nil) {
        func available(_ id: String) -> Bool { records[id] != nil && !pending.contains(id) }
        let target = preferred.flatMap { original.contains($0) && available($0) ? $0 : nil }
            ?? current.flatMap { available($0) ? $0 : nil }
            ?? ids.dropFirst(min(index+1,ids.count)).first(where:available)
        let updated = original.filter(available)
        if updated != ids { ids = updated }
        index = target.flatMap { ids.firstIndex(of:$0) } ?? ids.count
    }
    mutating func next(records: [String:MediaRecord],pending: Set<String>) {
        index = ReviewNavigation.next(from:index,ids:ids,records:records,pending:pending)
    }
    mutating func previous(records: [String:MediaRecord],pending: Set<String>) {
        index = ReviewNavigation.previous(from:index,ids:ids,records:records,pending:pending)
    }
}
