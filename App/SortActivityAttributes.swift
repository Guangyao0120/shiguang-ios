import ActivityKit
import Foundation

struct SortActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var completed: Int
        var total: Int
        var stopLabel: String
    }
    let run: UUID
}
