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
    @Published var loadError: String?
    @Published var saveError: String?
    @Published var detailLayers = 0
    @Published var busy = false
    @Published var progress = 0.0
    @Published var scanRate = 0.0
    @Published var status = "读取整理记录…"
    @Published var message: String?
    @Published var similar: [[String]] = []
    @Published private(set) var index = LibraryIndex()
    @Published private(set) var indexVersion = 0
    @Published private(set) var visibleIDs: Set<String> = []
    private var revision = 0
    private var scanTask: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var lastSaveTicket: UUID?
    private var activeScan: ScanRun?
    private let deleteOverride: ((Set<String>) async throws -> Set<String>)?
    private let imageOverride: ((MediaRecord) async -> UIImage?)?
    private let analysisOverride: ((UIImage,MediaRecord) async throws -> AnalysisResult)?
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

    init(storageURL: URL? = nil, images: ((MediaRecord) async -> UIImage?)? = nil,
         analyze: ((UIImage,MediaRecord) async throws -> AnalysisResult)? = nil,
         delete: ((Set<String>) async throws -> Set<String>)? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        disk = LibraryDisk(url: storageURL ?? folder.appendingPathComponent("library-v1.json"))
        imageOverride = images; analysisOverride = analyze; deleteOverride = delete
        super.init()
        for name in [UIApplication.didReceiveMemoryWarningNotification,UIApplication.protectedDataDidBecomeAvailableNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    if note.name == UIApplication.protectedDataDidBecomeAvailableNotification, self?.loaded == false { await self?.start() }
                    if note.name == UIApplication.didReceiveMemoryWarningNotification {
                        PhotoAccess.clearCache(); self?.pause(); SemanticSearchController.shared.pause()
                        self?.status = "内存紧张，扫描已暂停；已完成结果保留"
                    }
                }
            })
        }
        ScanRuntime.shared.store = self
        SemanticSearchController.shared.library = self
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
            video.videoTitle = "桐桐 · 生日祝福"; video.voiceTranscript = "祝桐桐生日快乐，开开心心每一天。"; video.tags = [.video,.portrait]; video.people = [person.id]
            sample.records[video.id] = video
            sample.trips[0].members.insert(video.id)
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
        do { state = try await disk.load(); storageReadable = true; loadError = nil }
        catch {
            storageReadable = false
            if UIApplication.shared.applicationState != .active && !UIApplication.shared.isProtectedDataAvailable {
                status = "等待设备解锁"; return
            }
            loadError = error.localizedDescription
            status = "整理记录暂时无法读取，请重试；不会覆盖原记录"
            return
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
            await Task.yield()
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
        guard loaded && storageReadable && !DesignPreview.enabled else { return }
        // Coalesce progress commits; LibraryDisk persists only changed rows.
        if (scanning || busy) && !immediately && pendingSaveID != nil { return }
        saveTask?.cancel()
        let ticket = UUID(), delay: UInt64 = (scanning || busy) ? 5_000_000_000 : 800_000_000
        pendingSaveID = ticket; lastSaveTicket = ticket
        saveTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(nanoseconds: delay) } catch { return false }
            }
            guard let self, !Task.isCancelled, self.pendingSaveID == ticket else { return false }
            self.pendingSaveID = nil
            let snapshot = self.state, version = self.revision
            do {
                try await self.disk.write(snapshot, revision: version)
                if self.lastSaveTicket == ticket { self.saveError = nil }
                return true
            } catch {
                if self.lastSaveTicket == ticket {
                    self.saveError = error.localizedDescription
                    self.message = "整理记录保存失败；本次结果仍保留在内存中，可重试保存。"
                }
                return false
            }
        }
    }

    func flushPendingSaves() async -> Bool {
        while let task = saveTask {
            let ticket = lastSaveTicket
            let saved = await task.value
            if ticket == lastSaveTicket { return saved }
        }
        return storageReadable
    }
    func retrySave() async {
        save(immediately:true)
        _ = await flushPendingSaves()
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
            if metadata.isEmpty && !self.state.records.isEmpty {
                self.status = "相册暂时返回空目录，已保留上次结果；可稍后刷新"
                self.metadataDirty = true; return
            }
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
        guard !scanning, !busy, !refreshing, loaded, permitted, storageReadable else { onFinish?(false,0); return }
        let scope = records.compactMap { state.records[$0.id] }.filter { !$0.isVideo && (!screenshotsOnly || $0.isScreenshot) }
        let todo = ScanPolicy.candidates(scope,screenshotsOnly:screenshotsOnly,limit:limit)
        guard !todo.isEmpty else { status = "暂无待识别图片"; onFinish?(true,0); return }
        let loader: (MediaRecord) async -> UIImage? = imageOverride ?? { record in
            let edge: CGFloat = record.isScreenshot ? 1024 : 640
            return await PhotoAccess.image(id:record.id,size:CGSize(width:edge,height:edge),highQuality:true)
        }
        let before = scope.filter { $0.analyzed && !$0.needsSceneryRefinement }.count
        let run = ScanRun(records:todo,completedBefore:before,total:scope.count,loader:loader,completion:onFinish)
        activeScan = run; scanning = true; scanRate = 0
        progress = Double(before)/Double(max(1,scope.count))
        status = "继续整理 · 已识别 \(before)/\(scope.count)"
        scanTask = Task { [weak self] in
            guard let self else { return }
            var completed = false, lastCommit = Date(), lastFeedback = Date.distantPast
            defer { run.images.cancel(); self.finishScan(run,completed:completed) }
            for record in todo {
                guard self.activeScan === run, !Task.isCancelled else { return }
                var updated = record
                let waiting = Date(), image = await run.images.next()
                guard self.activeScan === run, !Task.isCancelled else { return }
                run.measurements.photoWaitSeconds += Date().timeIntervalSince(waiting)
                if let image {
                    do {
                        let started = Date()
                        if let analyze = self.analysisOverride {
                            let result = try await analyze(image,record)
                            updated.tags = result.tags; updated.text = String(result.text.prefix(4000))
                            updated.hash = result.hash; updated.reasons = result.reasons; updated.visualLabels = result.labels
                        } else if record.needsSceneryRefinement {
                            let labels = try await LocalAnalyzer.sceneryLabels(image,cpuOnly:UIApplication.shared.applicationState != .active)
                            updated.visualLabels = labels; updated.tags.remove(.scenery); updated.tags.formUnion(CategoryRules.sceneryTags(labels))
                        } else {
                            let result = try await LocalAnalyzer.analyze(image,screenshot:record.isScreenshot,video:false,cpuOnly:UIApplication.shared.applicationState != .active)
                            updated.tags = result.tags; updated.text = String(result.text.prefix(4000))
                            updated.hash = result.hash; updated.reasons = result.reasons; updated.visualLabels = result.labels
                        }
                        guard self.activeScan === run, !Task.isCancelled else { return }
                        run.measurements.visionSeconds += Date().timeIntervalSince(started)
                        run.measurements.recognized += 1
                        if record.isScreenshot { run.measurements.screenshots += 1 }
                        updated.analyzed = true; updated.unavailable = false; run.failures = 0
                    } catch {
                        guard self.activeScan === run, !Task.isCancelled else { return }
                        run.failures += 1; updated.reasons = ["本次识别未完成，已保留旧结果，可稍后重试"]
                    }
                } else {
                    // A timeout or a temporary PhotoKit failure is retryable, not a permanent exclusion.
                    updated.unavailable = false; run.failures += 1
                    updated.reasons = ["暂未读取到本地图片，可下载原件后重试"]
                }
                guard self.activeScan === run, !Task.isCancelled else { return }
                run.updates.append(updated); run.handled += 1
                run.measurements.handled = run.handled; run.measurements.elapsed = Date().timeIntervalSince(run.started)
                if run.updates.count >= 24 || Date().timeIntervalSince(lastCommit) >= 2 {
                    self.commitAnalysis(run.updates); run.updates.removeAll(keepingCapacity:true)
                    self.save(immediately:true)
                    guard await self.flushPendingSaves() else { self.status = "保存失败，已暂停；已完成结果仍在本次会话中"; return }
                    guard self.activeScan === run, !Task.isCancelled else { return }
                    lastCommit = Date()
                }
                if run.failures >= 3 { run.stopReason = "连续读取或识别失败，已暂停；已完成进度保留"; return }
                ScanRuntime.shared.updateProgress(done:run.handled,total:todo.count)
                if Date().timeIntervalSince(lastFeedback) >= 0.5 {
                    self.progress = Double(run.completedBefore + run.measurements.recognized)/Double(max(1,run.total))
                    self.scanRate = Double(run.measurements.recognized)/max(0.001,run.measurements.elapsed)
                    self.status = "正在整理 · 已识别 \(run.completedBefore + run.measurements.recognized)/\(run.total)"
                    lastFeedback = Date()
                }
                await Task.yield()
            }
            completed = true
        }
    }
    private func finishScan(_ run: ScanRun,completed: Bool) {
        guard activeScan === run else { return }
        run.images.cancel(); commitAnalysis(run.updates); run.updates.removeAll()
        activeScan = nil; scanning = false; scanTask = nil
        run.measurements.elapsed = Date().timeIntervalSince(run.started); run.measurements.timestamp = Date()
        run.measurements.phase = completed ? "finished" : "paused"
        let metrics = run.measurements
        Task { try? await disk.saveScanMeasurements(metrics) }
        save(immediately:true)
        Task {
            let saved = await flushPendingSaves()
            if self.activeScan == nil && !self.busy {
                if !saved { self.status = "保存失败；本次结果仍在内存中，请重试保存" }
                else { self.status = run.stopReason ?? (completed ? "本批完成 · 已保存整理结果" : "已暂停 · 已完成结果已保存") }
            }
            run.completion?(completed && saved,run.handled)
        }
    }
    private func commitAnalysis(_ updates: [MediaRecord]) {
        guard !updates.isEmpty else { return }
        var next = state
        for value in updates {
            guard var record = next.records[value.id] else { continue }
            record.tags = value.tags; record.text = value.text; record.reasons = value.reasons
            record.visualLabels = value.visualLabels
            record.hash = value.hash; record.analyzed = value.analyzed; record.unavailable = value.unavailable
            next.records[value.id] = record // Preserve current manual edits.
        }
        state = next
    }
    func pause() {
        guard let run = activeScan else { return }
        scanTask?.cancel(); run.images.cancel()
        status = "正在保存已完成的整理结果…"
        finishScan(run,completed:false)
    }
    #if DEBUG
    func seedForTesting(_ value: LibraryState) {
        state = value; authorization = .authorized; visibleIDs = Set(value.records.keys)
        index = LibraryIndex.build(state:value,visible:visibleIDs); loaded = true; storageReadable = true
    }
    #endif

    func stage(_ id: String) { state.stage(id); save() }
    func restore(_ id: String) {
        state.pending.remove(id)
        if state.lastStaged == id { state.lastStaged = nil }
        save()
    }
    func restoreAllPending(ids: Set<String>? = nil) {
        let restoring = (ids ?? visibleIDs).intersection(visibleIDs)
        var next = state
        next.pending.subtract(restoring)
        if let last = next.lastStaged, restoring.contains(last) { next.lastStaged = nil }
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

    func deletePending(selected: Set<String>) async {
        guard !busy else { return }
        let ids = PendingSelection.valid(selected,pending:state.pending,visible:visibleIDs)
        guard !ids.isEmpty else { return }
        busy = true
        defer { busy = false; refreshIfNeeded() }
        pause(); save(immediately:true)
        guard await flushPendingSaves() else { message = "请先重试保存整理记录，再删除照片。"; return }
        do {
            let actual: Set<String>
            if let deleteOverride { actual = try await deleteOverride(ids).intersection(ids) }
            else { actual = try await PhotoAccess.delete(ids:ids) }
            guard !actual.isEmpty else { message = "所选照片当前无法由系统删除，待删记录已保留。"; metadataDirty = true; return }
            state.forget(actual); visibleIDs.subtract(actual)
            similar.removeAll { !$0.allSatisfy { state.records[$0] != nil } }
            save(immediately:true); _ = await flushPendingSaves(); metadataDirty = true
            message = actual.count == ids.count ? "已删除所选照片，可在苹果照片的最近删除中恢复。" : "已删除可删除的照片，其余仍保留在待删区。"
        } catch {
            if error is CancellationError || (error as? PHPhotosError)?.code == .userCancelled || (error as? CocoaError)?.code == .userCancelled {
                status = "已取消删除，所选照片保留"; return
            }
            message = "没有完成删除，所选照片仍保留在待删区：\(error.localizedDescription)"
        }
    }
}
