import SwiftUI
import Translation
import NaturalLanguage
import BackgroundTasks
import UserNotifications

@MainActor
final class SemanticSearchController: ObservableObject {
    static let shared = SemanticSearchController()
    @Published var building = false
    @Published var searching = false
    @Published var indexed = 0
    @Published var total = 0
    @Published var processed = 0
    @Published var unavailable = 0
    @Published var elapsed = 0.0
    @Published var status = "照片留在本机，不消耗 API token。"
    @Published var hits: [SemanticHit] = []
    @Published var searched = false
    private var worker: Task<Void, Never>?
    private var searchWorker: Task<Void, Never>?
    private var searchID = UUID()
    private var started = Date()
    weak var library: LibraryStore?
    private var backgroundTask: BGTask?
    private var lease = UIBackgroundTaskIdentifier.invalid
    private var activeRun: UUID?
    private var lastProgress = Date.distantPast
    private var registered = false
    private var continuedRegistered = false
    private var identifiers: [String] { Bundle.main.object(forInfoDictionaryKey:"BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [] }
    private var indexID: String { identifiers.first(where: { $0.hasSuffix(".search") }) ?? "com.example.Shiguang.search" }
    private var resumeID: String { identifiers.first(where: { $0.hasSuffix(".searchResume") }) ?? "com.example.Shiguang.searchResume" }
    func registerBackground() {
        guard !registered, !DesignPreview.enabled else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: resumeID, using: nil) { task in
            Task { @MainActor in await self.resume(task) }
        }
        if #available(iOS 26.0, *) {
            continuedRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: indexID, using: nil) { task in
                Task { @MainActor in
                    guard self.building, self.backgroundTask == nil else { task.setTaskCompleted(success: false); return }
                    self.backgroundTask = task; SortActivityController.shared.end(); self.endLease()
                    task.expirationHandler = { Task { @MainActor in self.pause() } }
                }
            }
        }
    }
    private func resume(_ task: BGTask) async {
        guard UserDefaults.standard.bool(forKey:"searchIndexWanted"),
              UserDefaults.standard.object(forKey:"backgroundEnabled") as? Bool ?? true,
              !building, backgroundTask == nil, let library else { task.setTaskCompleted(success:false); return }
        await library.prepareForBackgroundScan()
        guard !library.scanning, !library.busy, !library.refreshing, library.permitted else { task.setTaskCompleted(success:false); return }
        backgroundTask = task
        task.expirationHandler = { Task { @MainActor in self.worker?.cancel(); self.schedule() } }
        build(library)
    }
    private func schedule() {
        guard UserDefaults.standard.bool(forKey:"searchIndexWanted"),
              UserDefaults.standard.object(forKey:"backgroundEnabled") as? Bool ?? true else { return }
        let request = BGProcessingTaskRequest(identifier:resumeID)
        request.requiresNetworkConnectivity = false; request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(60)
        try? BGTaskScheduler.shared.submit(request)
    }
    private func beginBackgroundSupport() {
        guard UserDefaults.standard.object(forKey:"backgroundEnabled") as? Bool ?? true,
              UIApplication.shared.applicationState == .active else { return }
        if #available(iOS 26.0, *), continuedRegistered {
            let request = BGContinuedProcessingTaskRequest(identifier:indexID,title:L.t("时光在整理您的照片"),subtitle:L.t("建立搜索索引"))
            request.strategy = .fail; try? BGTaskScheduler.shared.submit(request)
        }
        let run = activeRun
        Task {
            try? await Task.sleep(for:.seconds(1.5))
            if self.activeRun == run, let run, self.building, self.backgroundTask == nil { SortActivityController.shared.start(run:run) }
        }
    }
    private func updateBackgroundProgress() {
        guard Date().timeIntervalSince(lastProgress) >= 1 else { return }
        lastProgress = Date()
        SortActivityController.shared.update(done:indexed,total:total)
        if #available(iOS 26.0, *), let task = backgroundTask as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(max(1,total)); task.progress.completedUnitCount = Int64(indexed)
            task.updateTitle(L.t("时光在整理您的照片"),subtitle:"\(indexed)/\(total)")
        }
    }
    private func endLease() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }

    private func eligible(_ store: LibraryStore) -> [String: String] {
        Dictionary(uniqueKeysWithValues: store.visibleActive.filter { !$0.isVideo }.map { ($0.id, $0.searchStamp) })
    }
    func refresh(_ store: LibraryStore) async {
        let eligible = eligible(store); total = eligible.count
        do { indexed = try await LocalSemanticIndex.shared.existing(eligible: eligible).count }
        catch { status = error.localizedDescription }
    }
    func build(_ store: LibraryStore) {
        guard !building, !store.scanning, !store.busy, !store.refreshing, store.loaded else {
            status = "请先暂停当前整理，再建立搜索索引。"; return
        }
        library = store; activeRun = UUID()
        UserDefaults.standard.set(true,forKey:"searchIndexWanted")
        building = true; store.busy = true; processed = 0; unavailable = 0; started = Date()
        status = "准备本地搜索索引…"
        beginBackgroundSupport()
        if UserDefaults.standard.object(forKey:"completionNotice") as? Bool ?? true { Task { await ScanRuntime.shared.requestNotificationPermission() } }
        worker = Task {
            var success = false
            var handled = 0
            var lastFeedback = Date.distantPast
            defer {
                building = false; store.busy = false; worker = nil; activeRun = nil
                backgroundTask?.setTaskCompleted(success:success); backgroundTask = nil
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:indexID)
                SortActivityController.shared.end(); endLease()
                if !success { schedule() }
            }
            do {
                let snapshot = eligible(store)
                total = snapshot.count
                let existing = try await LocalSemanticIndex.shared.existing(eligible: snapshot)
                indexed = existing.count
                let candidates = store.visibleActive.filter { !$0.isVideo && !existing.contains($0.id) }
                var batch: [SearchVector] = []
                for record in candidates {
                    if Task.isCancelled { break }
                    if let image = await PhotoAccess.image(id: record.id, size: CGSize(width: 448,height: 448), highQuality: true) {
                        if Task.isCancelled { break }
                        let vector = try await LocalSemanticIndex.shared.encode(image: image)
                        batch.append(SearchVector(id: record.id, stamp: record.searchStamp, vector: vector))
                        handled += 1
                        if batch.count >= 16 {
                            try await LocalSemanticIndex.shared.putBatch(batch); indexed += batch.count; batch.removeAll(keepingCapacity: true)
                        }
                    } else { unavailable += 1 }
                    if Date().timeIntervalSince(lastFeedback) >= 0.5 {
                        elapsed = Date().timeIntervalSince(started); processed = handled; lastFeedback = Date()
                        status = "正在建立搜索索引 · \(indexed + batch.count)/\(total)"
                    }
                    updateBackgroundProgress()
                    await Task.yield()
                }
                if !batch.isEmpty { try await LocalSemanticIndex.shared.putBatch(batch); indexed += batch.count }
                success = !Task.isCancelled
                if success {
                    UserDefaults.standard.set(false,forKey:"searchIndexWanted")
                    if handled > 0 { await notifyFinished() }
                }
                processed = handled; elapsed = Date().timeIntervalSince(started)
                status = Task.isCancelled ? "已暂停，重开后从已保存进度继续。" : (unavailable > 0 ? "本地图片已处理；\(unavailable) 张原件暂不可用，可下载后补充。" : "搜索索引已就绪。")
            } catch { status = error.localizedDescription }
            await LocalSemanticIndex.shared.unload()
        }
    }
    func pause() {
        UserDefaults.standard.set(false,forKey:"searchIndexWanted")
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:resumeID)
        worker?.cancel(); SortActivityController.shared.end()
    }
    private func notifyFinished() async {
        guard UserDefaults.standard.object(forKey:"completionNotice") as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = L.t("搜索索引已就绪")
        content.body = L.f("已建立 %d 张照片的本地搜索索引。",indexed)
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier:"shiguang-index-finished",content:content,trigger:nil))
    }
    func search(_ text: String, store: LibraryStore) {
        searchWorker?.cancel(); let token = UUID(); searchID = token
        searching = true; hits = []; searched = false
        let eligible = eligible(store)
        searchWorker = Task {
            defer { if searchID == token { searching = false } }
            do {
                let vector = try await LocalSemanticIndex.shared.encode(text: text)
                let ranked = try await LocalSemanticIndex.shared.rank(vector: vector, eligible: eligible)
                guard !Task.isCancelled, searchID == token else { return }
                hits = ranked; searched = true
                indexed = try await LocalSemanticIndex.shared.existing(eligible: eligible).count
                total = eligible.count
                status = "已搜索 \(indexed)/\(total) 张，按画面相关度排列。"
            } catch { if searchID == token { status = error.localizedDescription } }
            if !building { await LocalSemanticIndex.shared.unload() }
        }
    }
    func background() {
        searchWorker?.cancel(); searchID = UUID(); searching = false
        if !building { Task { await LocalSemanticIndex.shared.unload() }; return }
        guard UserDefaults.standard.object(forKey:"backgroundEnabled") as? Bool ?? true else { pause(); return }
        if backgroundTask == nil && lease == .invalid {
            lease = UIApplication.shared.beginBackgroundTask(withName:"保存搜索索引") {
                Task { @MainActor in self.worker?.cancel(); self.schedule(); self.endLease() }
            }
        }
        schedule()
    }
}

struct SemanticSearchView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var engine = SemanticSearchController.shared
    let initialQuery: String
    @State private var query = ""
    @State private var translationQuery = ""
    @State private var translationNote = ""
    private var validHits: [MediaRecord] {
        engine.hits.compactMap { hit in
            guard store.visibleIDs.contains(hit.id), !store.state.pending.contains(hit.id) else { return nil }
            return store.state.records[hit.id]
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TextField("例如：法棍、酒店自助早餐", text: $query)
                    .textFieldStyle(.roundedBorder).submitLabel(.search).onSubmit { search() }
                HStack {
                    Button("搜索照片", systemImage: "sparkle.magnifyingglass") { search() }
                        .buttonStyle(QuietPrimaryButtonStyle()).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.searching)
                    if engine.searching { ProgressView() }
                }
                if !translationNote.isEmpty { Text(L.t(translationNote)).font(.footnote).foregroundStyle(Palette.secondary) }
                VStack(alignment: .leading, spacing: 12) {
                    Label(L.f("本地 CLIP · %d/%d 张",engine.indexed,engine.total), systemImage: "iphone")
                    Text(L.status(engine.status)).font(.subheadline).foregroundStyle(Palette.secondary)
                    if engine.building {
                        ProgressView(value: Double(engine.indexed), total: Double(max(1,engine.total)))
                        if engine.elapsed > 2 { Text(L.f("本次 %.1f 张/秒", Double(engine.processed)/max(engine.elapsed,1))).font(.caption).foregroundStyle(Palette.secondary) }
                        Button("暂停建索引") { engine.pause() }
                    } else {
                        Button(engine.indexed == 0 ? "建立搜索索引" : "补充新增与改动的照片") { engine.build(store) }
                            .disabled(store.scanning || store.busy || store.refreshing)
                    }
                }.padding().paperCard()
                if engine.searched {
                    Text("可能相关").font(.title3)
                    Text("相似度不是识别概率。切片、遮挡或画面中的小物体可能漏检，请查看原图确认。")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                    MediaGrid(records: validHits)
                }
                if engine.indexed < engine.total {
                    Text("结果只覆盖已建索引的照片。视频暂不参与画面搜索。")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
                if #available(iOS 18.0, *) {
                    LocalQueryTranslation(text: translationQuery) { source, result in
                        guard translationQuery == source else { return }
                        switch result {
                        case .success(let english): translationNote = L.t("本地翻译：") + english; engine.search(english, store: store)
                        case .failure: translationNote = "本地翻译尚未就绪。可下载系统语言包，或输入英文描述；不会改用付费 API。"
                        }
                    }.frame(width: 0,height: 0)
                }
            }.padding()
        }.background(Palette.canvas).navigationTitle("找照片").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .task { query = initialQuery; await engine.refresh(store) }
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        translationNote = ""
        let aliases = ["法棍":"a photo of a baguette or sliced French bread", "美食":"a photo of food and dishes", "酒店自助早餐":"a photo of a hotel breakfast buffet"]
        if let english = aliases[text] { translationNote = L.t("本地检索：") + english; engine.search(english, store: store) }
        else if text.unicodeScalars.allSatisfy({ $0.value < 128 }) { engine.search(text, store: store) }
        else if #available(iOS 18.0, *) {
            if translationQuery == text { translationQuery = ""; Task { await Task.yield(); translationQuery = text } }
            else { translationQuery = text }
            translationNote = "正在使用系统本地翻译…"
        } else { translationNote = "此模型使用英文检索；通用中文描述需要 iOS 18 及系统本地翻译。" }
    }
}

@available(iOS 18.0, *)
private struct LocalQueryTranslation: View {
    let text: String
    let completion: (String, Result<String, Error>) -> Void
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        Color.clear
            .task(id: text) {
                guard !text.isEmpty else { configuration = nil; return }
                if configuration != nil { configuration?.invalidate() }
                else { configuration = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: "en")) }
            }
            .translationTask(configuration) { session in
                let requested = text
                guard !requested.isEmpty else { return }
                do { let response = try await session.translate(requested); completion(requested,.success(response.targetText)) }
                catch { completion(requested,.failure(error)) }
            }
    }
}
