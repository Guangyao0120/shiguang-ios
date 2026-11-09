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
    private var latestEnglish: String?
    private var latestOriginal = ""
    private var lastSearchRefresh = Date.distantPast
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
        if !building && !searched { status = indexed == 0 ? "搜索时会先显示标签与文字匹配，并开始建立画面索引。" : "本地搜索已就绪。" }
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
                            refreshLatestSearch(store)
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
                refreshLatestSearch(store, force: true)
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
    private func refreshLatestSearch(_ store: LibraryStore, force: Bool = false) {
        guard !latestOriginal.isEmpty, force || Date().timeIntervalSince(lastSearchRefresh) > 8 else { return }
        lastSearchRefresh = Date()
        search(latestEnglish, store: store, originalQuery: latestOriginal, startIndex: false)
    }
    func search(_ text: String?, store: LibraryStore, originalQuery: String? = nil, startIndex: Bool = true) {
        let original = originalQuery ?? text ?? ""
        guard !PhotoSearchQuery.normalized(original).isEmpty else { return }
        latestEnglish = text; latestOriginal = original
        searchWorker?.cancel(); let token = UUID(); searchID = token
        searching = true
        let eligible = eligible(store)
        let records = store.visibleActive, content = store.index.search
        searchWorker = Task {
            defer { if searchID == token { searching = false } }
            let metadata = await Task.detached(priority: .userInitiated) {
                PhotoSearchQuery.metadata(query: original, records: records, content: content)
            }.value
            guard !Task.isCancelled, searchID == token else { return }
            hits = metadata; searched = true
            do {
                let count = try await LocalSemanticIndex.shared.existing(eligible: eligible).count
                guard !Task.isCancelled, searchID == token else { return }
                indexed = count
                total = eligible.count
                if indexed > 0, let text {
                    let vector = try await LocalSemanticIndex.shared.encode(text: text)
                    try Task.checkCancellation()
                    let ranked = try await LocalSemanticIndex.shared.rank(vector: vector, eligible: eligible)
                    guard !Task.isCancelled, searchID == token else { return }
                    hits = PhotoSearchQuery.merged(metadata: metadata, visual: ranked)
                }
                if !building { status = indexed == 0 ? "已显示标签与文字匹配；画面索引尚未建立。" : "已搜索 \(indexed)/\(total) 张，按画面相关度排列。" }
                if startIndex && indexed == 0 && total > 0 && !building && !DesignPreview.enabled {
                    if store.scanning || store.busy || store.refreshing { status = "已显示标签与文字匹配。请暂停整理，再建立画面索引。" }
                    else { build(store) }
                }
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
    @State private var submitted = ""
    @State private var translationID = UUID()
    @FocusState private var typing: Bool
    private var validHits: [MediaRecord] {
        engine.hits.compactMap { hit in
            guard store.visibleIDs.contains(hit.id), !store.state.pending.contains(hit.id) else { return nil }
            return store.state.records[hit.id]
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField("例如：法棍、酒店自助早餐", text: $query)
                        .submitLabel(.search).focused($typing).onSubmit { search() }.accessibilityIdentifier("search.query")
                    if !query.isEmpty { Button { query = ""; typing = true } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清空搜索") }
                }.padding(16).paperCard(radius: 14)
                HStack {
                    Button("搜索照片", systemImage: "sparkle.magnifyingglass") { search() }
                        .albumGlassButton(prominent: true).controlSize(.large).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.searching)
                        .accessibilityIdentifier("search.submit")
                    if engine.searching { ProgressView() }
                }
                if !translationNote.isEmpty { Text(L.t(translationNote)).font(.footnote).foregroundStyle(Palette.secondary) }
                VStack(alignment: .leading, spacing: 12) {
                    Label(L.f("画面索引 · %d/%d 张",engine.indexed,engine.total), systemImage: "iphone")
                    Text(L.status(engine.status)).font(.subheadline).foregroundStyle(Palette.secondary)
                    if engine.building {
                        ProgressView(value: Double(engine.indexed), total: Double(max(1,engine.total)))
                        if engine.elapsed > 2 { Text(L.f("本次 %.1f 张/秒", Double(engine.processed)/max(engine.elapsed,1))).font(.caption).foregroundStyle(Palette.secondary) }
                        Button("暂停建索引") { engine.pause() }
                    } else {
                        Button(engine.indexed == 0 ? "建立画面索引" : "补充新增照片") { engine.build(store) }
                            .disabled(store.scanning || store.busy || store.refreshing)
                    }
                }.padding().paperCard()
                if engine.searched {
                    HStack {
                        Text("搜索结果").font(.title3.weight(.semibold))
                        Spacer()
                        Text("\(validHits.count) 项").foregroundStyle(Palette.secondary).monospacedDigit().accessibilityIdentifier("search.count")
                    }
                    if validHits.isEmpty {
                        ContentUnavailableView("暂未找到", systemImage: "magnifyingglass", description: Text(engine.indexed < engine.total ? "标签与文字中没有匹配，画面索引完成后可找到更多照片。" : "试试更具体的物品、场景或标签。"))
                    } else { MediaGrid(records: validHits) }
                }
                if engine.indexed < engine.total {
                    Text("标签与文字可直接搜索；画面搜索覆盖已建索引的照片。")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
                if #available(iOS 18.0, *) {
                    LocalQueryTranslation(text: translationQuery, requestID: translationID) { request, source, result in
                        guard request == translationID, translationQuery == source else { return }
                        switch result {
                        case .success(let english): translationNote = ""; engine.search(english, store: store, originalQuery: submitted)
                        case .failure: translationNote = "已显示标签与文字结果。画面搜索需要系统语言包，也可输入英文。"
                        }
                    }.frame(width: 0,height: 0)
                }
            }.padding()
        }.background(AlbumCanvas()).navigationTitle("找照片").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .task { query = initialQuery; await engine.refresh(store) }
            .onDisappear { translationQuery = "" }
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typing = false; submitted = text; translationNote = ""; translationQuery = ""; translationID = UUID()
        if let english = PhotoSearchQuery.english(text) { engine.search(english, store: store, originalQuery: text) }
        else if #available(iOS 18.0, *) {
            engine.search(nil, store: store, originalQuery: text)
            translationQuery = PhotoSearchQuery.normalized(text)
            translationNote = "正在补充画面搜索…"
        } else { engine.search(nil, store: store, originalQuery: text); translationNote = "已显示标签与文字结果。画面搜索可输入英文描述。" }
    }
}

@available(iOS 18.0, *)
private struct LocalQueryTranslation: View {
    let text: String
    let requestID: UUID
    let completion: (UUID, String, Result<String, Error>) -> Void
    @State private var configuration: TranslationSession.Configuration?
    @State private var sourceLanguage = ""
    var body: some View {
        Color.clear
            .task(id: requestID) {
                guard !text.isEmpty else { configuration = nil; return }
                let language = PhotoSearchQuery.sourceLanguage(text)
                if configuration != nil && language == sourceLanguage { configuration?.invalidate() }
                else {
                    sourceLanguage = language
                    configuration = TranslationSession.Configuration(source: Locale.Language(identifier: language), target: Locale.Language(identifier: "en"))
                }
            }
            .translationTask(configuration) { session in
                let requested = text
                let token = requestID
                guard !requested.isEmpty else { return }
                do { let response = try await session.translate(requested); completion(token,requested,.success(response.targetText)) }
                catch { completion(token,requested,.failure(error)) }
            }
    }
}
