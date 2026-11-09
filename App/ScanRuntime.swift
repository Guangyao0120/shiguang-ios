import SwiftUI
import BackgroundTasks
import UserNotifications
import UIKit

enum AlbumAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

@MainActor
final class ScanRuntime: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ScanRuntime()
    @Published var note = ""
    @Published var launching = false
    weak var store: LibraryStore?
    private var continued: BGTask?
    private var lease = UIBackgroundTaskIdentifier.invalid
    private var registered = false
    private var userPaused = UserDefaults.standard.bool(forKey: "scanPaused") {
        didSet { UserDefaults.standard.set(userPaused, forKey: "scanPaused") }
    }
    private var scheduledScope = true
    private var continuedRegistered = false
    private var backgroundEnabled: Bool { UserDefaults.standard.object(forKey: "backgroundEnabled") as? Bool ?? true }
    private var noticesEnabled: Bool { UserDefaults.standard.object(forKey: "completionNotice") as? Bool ?? true }
    private var identifiers: [String] { Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [] }
    private var continuedID: String { identifiers.first(where: { $0.hasSuffix(".organize") }) ?? "com.example.Shiguang.organize" }
    private var resumeID: String { identifiers.first(where: { $0.hasSuffix(".resume") }) ?? "com.example.Shiguang.resume" }

    func register() {
        guard !registered, !DesignPreview.enabled else { return }
        registered = true
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: resumeID, using: nil) { task in
            Task { @MainActor in ScanRuntime.shared.runScheduled(task) }
        }
        if #available(iOS 26.0, *) {
            continuedRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedID, using: nil) { task in
                Task { @MainActor in ScanRuntime.shared.runContinued(task) }
            }
        }
    }
    func start(screenshotsOnly: Bool? = nil, limit: Int? = nil) {
        guard !launching, let store, !store.scanning, !store.refreshing, !store.busy, store.loaded else { return }
        let scope = screenshotsOnly ?? (UserDefaults.standard.object(forKey: "screenshotsOnly") as? Bool ?? true)
        let setting = UserDefaults.standard.object(forKey: "scanLimit") as? Int ?? 0
        let count = limit ?? (setting == 0 ? Int.max : setting)
        guard !ScanPolicy.candidates(store.records.compactMap { store.state.records[$0.id] }, screenshotsOnly: scope, limit: 1).isEmpty else {
            store.status = "暂无待整理图片"; return
        }
        userPaused = false; scheduledScope = scope
        UserDefaults.standard.set(scope, forKey: "resumeScreenshotsOnly")
        UserDefaults.standard.set(count, forKey: "resumeScanLimit")
        launching = true
        Task {
            defer { launching = false }
            if noticesEnabled { await requestNotificationPermission() }
            guard !userPaused, !store.scanning, !store.busy, !store.refreshing else { return }
            if backgroundEnabled, #available(iOS 26.0, *), continuedRegistered {
                let request = BGContinuedProcessingTaskRequest(identifier: continuedID, title: "拾光正在整理照片", subtitle: "本机识别，不上传图片")
                request.strategy = .fail
                do { try BGTaskScheduler.shared.submit(request); note = "已申请持续后台整理"; return }
                catch { note = "系统暂未批准持续后台，切后台后可短暂继续" }
            }
            runScan(scope: scope, limit: count, task: nil)
        }
    }
    @available(iOS 26.0, *)
    private func runContinued(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
        continued = task
        task.expirationHandler = { Task { @MainActor in ScanRuntime.shared.expired() } }
        let limit = UserDefaults.standard.integer(forKey: "resumeScanLimit")
        runScan(scope: scheduledScope, limit: limit == 0 ? Int.max : limit, task: task)
    }
    private func runScheduled(_ task: BGTask) {
        guard backgroundEnabled, !userPaused, let store else { task.setTaskCompleted(success: false); return }
        task.expirationHandler = { Task { @MainActor in ScanRuntime.shared.expired() } }
        continued = task; userPaused = false
        Task {
            await store.prepareForBackgroundScan()
            guard !store.scanning, !store.busy, store.permitted else { task.setTaskCompleted(success: false); continued = nil; return }
            let scope = UserDefaults.standard.object(forKey: "resumeScreenshotsOnly") as? Bool ?? true
            runScan(scope: scope, limit: 100, task: task)
        }
    }
    private func runScan(scope: Bool, limit: Int, task: BGTask?) {
        guard let store, !store.scanning, !store.busy, !store.refreshing else { task?.setTaskCompleted(success: false); continued = nil; return }
        store.scan(screenshotsOnly: scope, limit: limit) { [weak self] finished, count in
            guard let self else { return }
            task?.setTaskCompleted(success: finished)
            self.continued = nil; self.endLease()
            self.note = finished ? "本次整理完成" : "进度已保存"
            if finished && count > 0 { Task { await self.notify(count: count, scope: scope) } }
            if !self.userPaused { self.schedule() }
        }
    }
    func updateProgress(done: Int, total: Int) {
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(total)
            task.progress.completedUnitCount = Int64(done)
            task.updateTitle("拾光正在整理照片", subtitle: "\(done)/\(total)")
        }
    }
    func pause() {
        userPaused = true
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: resumeID)
        if continued == nil { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedID) }
        store?.pause()
    }
    func enterBackground() {
        guard backgroundEnabled else { pause(); return }
        if store?.scanning == true && continued == nil && lease == .invalid {
            lease = UIApplication.shared.beginBackgroundTask(withName: "保存整理进度") { Task { @MainActor in ScanRuntime.shared.expired() } }
        }
        schedule()
    }
    func enterForeground() { endLease() }
    private func expired() {
        note = "系统结束了本次后台时段，已请求保存；等待下一次调度"
        store?.pause(); store?.save(immediately: true)
        schedule()
        endLease()
    }
    private func endLease() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }
    func schedule() {
        guard backgroundEnabled, !userPaused, let store, store.loaded else { return }
        let scope = UserDefaults.standard.object(forKey: "resumeScreenshotsOnly") as? Bool ?? true
        guard !ScanPolicy.candidates(store.records.compactMap { store.state.records[$0.id] }, screenshotsOnly: scope, limit: 1).isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: resumeID)
        request.requiresNetworkConnectivity = false; request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { note = "后台任务暂未获系统安排，可回到前台继续" }
    }
    func backgroundSettingChanged() {
        if backgroundEnabled { userPaused = false; schedule() }
        else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: resumeID) }
    }
    func requestNotificationPermission() async {
        guard !DesignPreview.enabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { note = "未能开启通知，可在系统设置中调整" }
        }
    }
    private func notify(count: Int, scope: Bool) async {
        guard noticesEnabled else { return }
        let center = UNUserNotificationCenter.current(), settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let remaining = store.map { library in ScanPolicy.candidates(library.records.compactMap { library.state.records[$0.id] }, screenshotsOnly: scope, limit: Int.max).count } ?? 0
        let content = UNMutableNotificationContent()
        let unavailable = store?.state.records.values.contains(where: { $0.unavailable && (!scope || $0.isScreenshot) }) ?? false
        content.title = remaining > 0 ? "本批整理完成" : (unavailable ? "本次整理结束" : "照片整理完成")
        content.body = "已处理\(count)项" + (remaining > 0 ? "，还有\(remaining)项等待整理。" : (unavailable ? "，部分原件需下载后再整理。" : "，打开拾光查看分类。"))
        content.sound = .default
        do { try await center.add(UNNotificationRequest(identifier: "shiguang-scan-finished", content: content, trigger: nil)) }
        catch { note = "整理完成，通知未能送达" }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct AlbumSettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("appearance") private var appearance = AlbumAppearance.system.rawValue
    @AppStorage("backgroundEnabled") private var background = true
    @AppStorage("completionNotice") private var notifications = true
    @AppStorage("screenshotsOnly") private var screenshots = true
    @AppStorage("scanLimit") private var limit = 0
    @ObservedObject private var runtime = ScanRuntime.shared
    @State private var notificationStatus = ""
    var body: some View {
        Form {
            Section("外观") {
                Picker("显示模式", selection: $appearance) {
                    ForEach(AlbumAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section {
                Picker("默认范围", selection: $screenshots) { Text("截图").tag(true); Text("所有图片").tag(false) }
                Picker("每次整理", selection: $limit) { Text("全部待整理").tag(0); Text("100张").tag(100); Text("500张").tag(500) }
                Toggle("后台继续整理", isOn: $background).onChange(of: background) { _, _ in runtime.backgroundSettingChanged() }
                if !runtime.note.isEmpty { Text(runtime.note).font(.footnote).foregroundStyle(Palette.secondary) }
            } header: { Text("整理") } footer: { Text("后台执行由 iOS 调度；锁定、强制关闭或系统资源不足时可能暂停，已完成进度会保留。") }
            Section {
                Toggle("整理完成通知", isOn: $notifications).onChange(of: notifications) { _, enabled in
                    if enabled { Task { await runtime.requestNotificationPermission(); await refreshNotificationStatus() } }
                }
                if !notificationStatus.isEmpty { Text(notificationStatus).font(.footnote).foregroundStyle(Palette.secondary) }
                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } header: { Text("通知与权限") }
            Section("数据与隐私") {
                LabeledContent("可访问", value: "\(store.visibleIDs.count)项")
                Button("清理图片缓存") { PhotoAccess.clearCache(); store.message = "图片缓存已清理，原图与标签保留。" }
                NavigationLink("DeepSeek 设置") { AISettingsView() }
                NavigationLink("使用说明") { AlbumHelpView() }
            }
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("原图保存在苹果照片。本地整理不上传；可选 AI 发送前会预览。")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
        }.paperList().navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .task { await refreshNotificationStatus() }
    }
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus == .denied ? "系统未允许通知，可在系统设置中开启" : ""
    }
}
