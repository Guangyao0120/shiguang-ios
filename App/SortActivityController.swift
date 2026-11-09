import ActivityKit
import UIKit

@MainActor
final class SortActivityController {
    static let shared = SortActivityController()
    private var activity: Activity<SortActivityAttributes>?
    private var run: UUID?
    private var done = 0
    private var total = 0
    private var lastUpdate = Date.distantPast
    func start(run: UUID) {
        guard UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true,
              UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if self.run == run { return }
        end(); self.run = run
        do {
            activity = try Activity.request(attributes: SortActivityAttributes(run: run),
                content: ActivityContent(state: state(), staleDate: Date().addingTimeInterval(120)),pushType: nil)
        } catch { self.run = nil }
    }
    private func state() -> SortActivityAttributes.ContentState {
        .init(title: L.t("时光在整理您的照片"),completed: done,total: total,stopLabel: L.t("暂停"))
    }
    func update(done: Int,total: Int) {
        self.done = done; self.total = total
        guard let activity, Date().timeIntervalSince(lastUpdate) >= 1 || done == total else { return }
        lastUpdate = Date(); let content = ActivityContent(state: state(),staleDate: Date().addingTimeInterval(120))
        Task { await activity.update(content) }
    }
    func end() {
        let old = activity; activity = nil; run = nil
        Task { await old?.end(nil,dismissalPolicy: .immediate) }
    }
    func removeAbandoned() {
        for old in Activity<SortActivityAttributes>.activities { Task { await old.end(nil,dismissalPolicy: .immediate) } }
    }
}
