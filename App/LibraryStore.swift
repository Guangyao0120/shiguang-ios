import Foundation
import Photos
import Combine
import UIKit

@MainActor
final class LibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver, ScanDriver {
    @Published var state = LibraryState() { didSet { revision += 1; prepareIndex() } }
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var scanning = false
    @Published var refreshing = false
    @Published var loaded = false
    @Published var detailLayers = 0
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "读取整理记录…"
    @Published var message: String?
    @Published var similar: [[String]] = []
    @Published private(set) var index = LibraryIndex()
    @Published private(set) var indexVersion = 0
    @Published private(set) var visibleIDs: Set<String> = []
    private var revision = 0
    private var scanTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var pendingSaveID: UUID?
    private var indexTask: Task<Void, Never>?
    private var indexWorker: Task<LibraryIndex, Never>?
    private var refreshTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var registered = false
    private var starting = false
    private var storageReadable = true
    private var metadataDirty = true
    private let disk: LibraryDisk
    var records: [MediaRecord] { index.records }
    var active: [MediaRecord] { index.active }
    var visibleActive: [MediaRecord] { index.active }
    var visiblePending: [MediaRecord] { index.pending }
    var permitted: Bool { authorization == .authorized || authorization == .limited }

    override init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        disk = LibraryDisk(url: folder.appendingPathComponent("library-v1.json"))
        super.init()
        for name in [UIApplication.didReceiveMemoryWarningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    if note.name == UIApplication.didReceiveMemoryWarningNotification {
                        PhotoAccess.clearCache(); self?.pause()
                        self?.status = "内存紧张，扫描已暂停；已完成结果保留"
                    }
                }
            })
        }
        ScanRuntime.shared.store = self
    }

    func start() async {
        #if DEBUG
        if DesignPreview.enabled {
            authorization = .authorized
            var sample = LibraryState()
            let person = NamedPerson(name: "桐桐")
            sample.people = [person]
            for i in 0..<78 {
                var record = MediaRecord(id: "preview-\(i)", date: Date().addingTimeInterval(Double(-i * 3600)), isVideo: false, isScreenshot: i % 2 == 0, duration: 0)
                record.analyzed = true
                record.tags = [PhotoTag.allCases[i % PhotoTag.allCases.count]]
                if i % 4 == 0 { record.people = [person.id]; record.keywords = ["日常"] }
                sample.records[record.id] = record
            }
            sample.trips = [Trip(name: "中秋 · 长沙", members: Set((0..<18).map { "preview-\($0)" }))]
            sample.pending = ["preview-3", "preview-7"]
            sample.customTagNames = ["工作", "纪念", "待买"]
            var video = MediaRecord(id: "preview-video", date: Date(), isVideo: true, isScreenshot: false, duration: 32)
            video.videoTitle = "桐桐 · 生日祝福"; video.voiceTranscript = "祝桐桐生日快乐，开开心心每一天。"; video.tags = [.video]
            sample.records[video.id] = video
            state = sample; visibleIDs = Set(sample.records.keys)
            index = await Task.detached { LibraryIndex.build(state: sample, visible: Set(sample.records.keys)) }.value
            indexVersion += 1; status = "从上次继续"; loaded = true
            return
        }
        #endif
        guard !starting else { return }
        guard !loaded else { refreshIfNeeded(); return }
        starting = true
        defer { starting = false }
        do { state = try await disk.load(); storageReadable = true }
        catch {
            storageReadable = false
            if UIApplication.shared.applicationState != .active && !UIApplication.shared.isProtectedDataAvailable {
                status = "等待设备解锁"; return
            }
            message = "无法读取整理记录，已停止覆盖保存，原图未受影响：\(error.localizedDescription)"
        }
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if permitted {
            status = "读取上次分类…"
            let snapshot = state, fullAccess = authorization == .authorized
            let cached = await Task.detached(priority: .utility) {
                let ids = fullAccess ? Set(snapshot.records.keys) : LibraryMetadata.visibleIdentifiers()
                return (ids, LibraryIndex.build(state: snapshot, visible: ids))
            }.value
            // Recheck access before exposing cached records after the asynchronous read.
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == authorization {
                visibleIDs = cached.0; index = cached.1; indexVersion += 1
            }
        }
        loaded = true
        similar = state.similarPairs ?? []
        refreshIfNeeded()
    }

    private func prepareIndex() {
        guard loaded else { return }
        indexTask?.cancel(); indexWorker?.cancel()
        indexTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.state, visible = self.visibleIDs, version = self.revision
            let worker = Task.detached(priority: .utility) { LibraryIndex.build(state: snapshot, visible: visible) }
            self.indexWorker = worker
            let result = await worker.value
            guard !Task.isCancelled, self.revision == version, self.visibleIDs == visible else { return }
            self.index = result
            self.indexVersion += 1
        }
    }

    func save(immediately: Bool = false) {
        guard loaded && storageReadable else { return }
        // While scanning, coalesce all five-record commits into one latest snapshot
        // every five seconds instead of repeatedly encoding the entire library.
        if scanning && !immediately && pendingSaveID != nil { return }
        saveTask?.cancel()
        let ticket = UUID(), delay: UInt64 = scanning ? 5_000_000_000 : 800_000_000
        pendingSaveID = ticket
        saveTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
            }
            guard let self, !Task.isCancelled, self.pendingSaveID == ticket else { return }
            self.pendingSaveID = nil
            let snapshot = self.state, version = self.revision
            do { try await self.disk.write(snapshot, revision: version) }
            catch { self.message = "整理记录保存失败：\(error.localizedDescription)" }
        }
    }

    func connect() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if !loaded { await start() } else { refresh() }
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.metadataDirty = true }
    }
    func refreshIfNeeded() {
        guard !DesignPreview.enabled else { return }
        let updated = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if updated != authorization { authorization = updated; metadataDirty = true }
        if metadataDirty { refresh(force: false) }
    }
    func refresh(force: Bool = true) {
        guard loaded, permitted, !refreshing, !scanning, !busy else { return }
        if !force && !metadataDirty { return }
        if !registered { PHPhotoLibrary.shared().register(self); registered = true }
        refreshing = true; metadataDirty = false
        status = "核对相册中…"
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshing = false }
            let metadata = await Task.detached(priority: .utility) { LibraryMetadata.fetch() }.value
            let ids = Set(metadata.map(\.id))
            while !Task.isCancelled {
                let old = self.state, version = self.revision, full = self.authorization == .authorized
                let next = await Task.detached(priority: .utility) {
                    LibraryMetadata.merge(metadata, into: old, fullAccess: full, retryUnavailable: force)
                }.value
                if version != self.revision { continue } // Preserve edits made during background fetch.
                self.visibleIDs = ids
                self.state = next
                let analyzed = next.records.values.lazy.filter { ids.contains($0.id) && $0.analyzed }.count
                self.status = "已识别 \(analyzed) 项 · 共 \(ids.count) 项"
                self.save()
                return
            }
        }
    }

    func prepareForBackgroundScan() async {
        await start()
        await refreshTask?.value
        await indexTask?.value
    }
    func scan(screenshotsOnly: Bool = true, limit: Int = 100, onFinish: ((Bool, Int) -> Void)? = nil) {
        guard !scanning, !busy, !refreshing, loaded, permitted else { onFinish?(false, 0); return }
        let todo = ScanPolicy.candidates(records.compactMap { state.records[$0.id] }, screenshotsOnly: screenshotsOnly, limit: limit)
        guard !todo.isEmpty else { status = "暂无待识别的\(screenshotsOnly ? "截图" : "图片")"; onFinish?(true, 0); return }
        scanning = true; progress = 0
        status = "开始整理 · \(todo.count)项"
        scanTask = Task { [weak self] in
            guard let self else { return }
            var updates: [MediaRecord] = []
            var handled = 0
            var completedAll = false
            defer {
                self.commitAnalysis(updates); self.scanning = false; self.save(immediately: true)
                let finished = completedAll && !Task.isCancelled, count = handled, saving = self.saveTask
                Task { await saving?.value; onFinish?(finished, count) }
            }
            for (position, record) in todo.enumerated() {
                if Task.isCancelled { return }
                var updated = record
                self.status = "读取图片 · \(position + 1)/\(todo.count)"
                let image = await PhotoAccess.image(id: record.id, size: CGSize(width: record.isScreenshot ? 1024 : 640, height: record.isScreenshot ? 1024 : 640), highQuality: true)
                guard !Task.isCancelled else { return }
                if let image {
                    do {
                        let result = try await LocalAnalyzer.analyze(image, screenshot: record.isScreenshot, video: false, cpuOnly: UIApplication.shared.applicationState != .active)
                        guard !Task.isCancelled else { return }
                        updated.tags = result.tags; updated.text = String(result.text.prefix(4000))
                        updated.reasons = result.reasons; updated.hash = result.hash
                        updated.analyzed = true; updated.unavailable = false
                    } catch { updated.reasons = ["本次识别失败，下次可重试"] }
                } else {
                    updated.unavailable = UIApplication.shared.applicationState == .active
                    if !updated.unavailable { updated.reasons = ["后台暂未读取到原件，下次重试"] }
                }
                updates.append(updated)
                handled += 1
                if updates.count >= 5 { self.commitAnalysis(updates); updates.removeAll(keepingCapacity: true); self.save() }
                self.progress = Double(position + 1) / Double(todo.count)
                ScanRuntime.shared.updateProgress(done: position + 1, total: todo.count)
                self.status = "正在整理 · \(position + 1)/\(todo.count)"
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            self.status = "本批完成 · 可继续整理"
            completedAll = true
        }
    }
    private func commitAnalysis(_ updates: [MediaRecord]) {
        guard !updates.isEmpty else { return }
        var next = state
        for value in updates {
            guard var record = next.records[value.id] else { continue }
            record.tags = value.tags; record.text = value.text; record.reasons = value.reasons
            record.hash = value.hash; record.analyzed = value.analyzed; record.unavailable = value.unavailable
            next.records[value.id] = record // Preserve current manual edits.
        }
        state = next
    }
    func pause() { scanTask?.cancel(); if scanning { status = "已暂停" } }

    func stage(_ id: String) { state.stage(id); save() }
    func restore(_ id: String) {
        state.pending.remove(id)
        if state.lastStaged == id { state.lastStaged = nil }
        save()
    }
    func restoreAllPending() {
        var next = state
        next.pending.subtract(visibleIDs)
        next.lastStaged = nil
        state = next; save()
    }
    func undo() { state.undo(); save() }
    func setTag(_ id: String, _ tag: PhotoTag, enabled: Bool) {
        if enabled { state.records[id]?.addedTags.insert(tag); state.records[id]?.removedTags.remove(tag) }
        else { state.records[id]?.removedTags.insert(tag); state.records[id]?.addedTags.remove(tag) }
        save()
    }
    func addKeywords(_ id: String, input: String) {
        let values = input.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
        state.records[id]?.keywords = TagNames.normalized((state.records[id]?.keywords ?? []) + values)
        save()
    }
    func createCustomTag(_ input: String) {
        let names = input.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
        state.customTagNames = TagNames.normalized((state.customTagNames ?? []) + names)
        save()
    }
    func removeKeyword(_ id: String, keyword: String) {
        state.records[id]?.keywords = state.records[id]?.customTags.filter { $0 != keyword }
        save()
    }
    var allKeywords: [String] {
        index.keywords
    }
    func tagLabels(for record: MediaRecord) -> [String] {
        index.labels[record.id] ?? record.effectiveTags.map(\.rawValue)
    }
    func addPerson(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !state.people.contains(where: { $0.name == name }) else { return }
        state.people.append(NamedPerson(name: name)); save()
    }
    func togglePerson(_ id: String, _ person: UUID) {
        if state.records[id]?.people.contains(person) == true { state.records[id]?.people.remove(person) }
        else { state.records[id]?.people.insert(person) }
        save()
    }
    func associatePerson(_ person: UUID, ids: [String]) {
        var next = state
        for id in ids where visibleIDs.contains(id) { next.records[id]?.people.insert(person) }
        state = next; save()
    }
    func applyAI(_ suggestion: AISuggestion, id: String) {
        guard visibleIDs.contains(id), state.records[id] != nil else {
            message = "这张照片已不在当前授权范围内，未应用 AI 结果。"; return
        }
        for value in suggestion.tags {
            if let tag = PhotoTag(rawValue: value) {
                state.records[id]?.addedTags.insert(tag)
                state.records[id]?.removedTags.remove(tag)
            }
        }
        state.records[id]?.aiSummary = suggestion.summary
        if state.records[id]?.isVideo == true, let title = suggestion.videoTitle, !title.isEmpty {
            state.records[id]?.videoTitle = title
        }
        state.records[id]?.keywords = TagNames.normalized((state.records[id]?.keywords ?? []) + (suggestion.keywords ?? []))
        save()
    }
    func setVideoTitle(_ id: String, title: String) {
        guard visibleIDs.contains(id), state.records[id]?.isVideo == true else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        state.records[id]?.videoTitle = String(value.prefix(40)); save()
    }
    func applyVideoTranscript(_ id: String, text: String) {
        guard visibleIDs.contains(id), state.records[id]?.isVideo == true else { return }
        var next = state
        next.records[id]?.voiceTranscript = text
        if next.records[id]?.videoTitle == nil { next.records[id]?.videoTitle = VideoTitleRules.title(from: text) }
        next.records[id]?.tags.insert(.video)
        state = next; save(immediately: true)
    }
    func rebuildTrips() {
        guard !busy, !scanning, !refreshing else { return }
        busy = true
        let snapshot = records
        Task {
            let proposed = await Task.detached(priority: .utility) { TripBuilder.candidates(snapshot) }.value
            let existing = state.trips
            var result = existing.filter(\.manual)
            for var trip in proposed {
                if result.contains(where: { !$0.members.isDisjoint(with: trip.members) }) { continue }
                if let old = existing.first(where: { !$0.manual && !$0.members.isDisjoint(with: trip.members) }) { trip.id = old.id }
                result.append(trip)
            }
            state.trips = result; busy = false; save()
        }
    }
    func findSimilar() {
        guard !busy, !scanning, !refreshing else { return }
        busy = true
        let snapshot = visibleActive
        Task {
            let pairs = await Task.detached(priority: .utility) { Similarity.pairs(snapshot) }.value
            similar = pairs
            state.similarPairs = pairs
            busy = false; save()
        }
    }
    func createTrip(name: String, start: Date, end: Date) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let dayStart = Calendar.current.startOfDay(for: start)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!
        let ids = visibleActive.filter { $0.date >= dayStart && $0.date < dayEnd }.map(\.id)
        guard !ids.isEmpty else { message = "这个日期范围内没有可访问的照片或视频。"; return }
        state.trips.append(Trip(name: name, members: Set(ids), manual: true)); save()
    }
    func renameTrip(_ id: UUID, name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = state.trips.firstIndex(where: { $0.id == id }) else { return }
        state.trips[index].name = name; state.trips[index].manual = true; save()
    }
    func toggleTrip(_ media: String, trip id: UUID) {
        guard let index = state.trips.firstIndex(where: { $0.id == id }) else { return }
        if state.trips[index].members.contains(media) { state.trips[index].members.remove(media) }
        else { state.trips[index].members.insert(media) }
        state.trips[index].manual = true; save()
    }

    func matches(_ record: MediaRecord, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let content = index.search[record.id] ?? ""
        return words.allSatisfy { content.contains($0) }
    }

    func exportAlbum(name: String, ids: [String]) async {
        guard !busy && !scanning && !refreshing else { message = "请先等待目录读取或暂停扫描。"; return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids.filter { visibleIDs.contains($0) }, options: nil)
        guard assets.count > 0 else { return }
        busy = true
        defer { busy = false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                request.addAssets(assets)
            }
            message = "已在苹果照片中创建「\(name)」，没有复制原图。"
        } catch { message = "未创建相册：\(error.localizedDescription)" }
    }

    func deletePending() async {
        guard !busy && !scanning && !refreshing else { message = "请先等待目录读取或暂停扫描。"; return }
        let ids = Set(visiblePending.map(\.id))
        guard !ids.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        guard assets.count > 0 else { refresh(); return }
        var actual: Set<String> = []
        assets.enumerateObjects { asset, _, _ in actual.insert(asset.localIdentifier) }
        busy = true
        defer { busy = false; refreshIfNeeded() }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            state.forget(actual)
            similar.removeAll { !$0.allSatisfy { state.records[$0] != nil } }
            save(); metadataDirty = true
            message = "系统已接受删除。可在苹果照片的「最近删除」中恢复。"
        } catch { message = "没有完成删除，待删队列已保留：\(error.localizedDescription)" }
    }
}
