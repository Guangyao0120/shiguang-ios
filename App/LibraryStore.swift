import Foundation
import Photos
import Combine
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published var state = LibraryState()
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var scanning = false
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "准备好整理你的相册"
    @Published var message: String?
    @Published var similar: [[String]] = []
    private var scanTask: Task<Void, Never>?
    private let saveURL: URL
    private var storageReadable = true
    var records: [MediaRecord] { state.records.values.sorted { $0.date > $1.date } }
    var active: [MediaRecord] { records.filter { !state.pending.contains($0.id) } }
    var permitted: Bool { authorization == .authorized || authorization == .limited }

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        saveURL = folder.appendingPathComponent("library-v1.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: saveURL.path) {
                state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: saveURL))
            }
        } catch {
            storageReadable = false
            message = "无法读取本地整理记录：\(error.localizedDescription)。已停止覆盖保存，请保留 App 数据；原图未受影响。"
        }
    }

    func save() {
        guard storageReadable else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: saveURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch { message = "整理记录保存失败：\(error.localizedDescription)" }
    }

    func connect() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permitted else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        var visible: Set<String> = []
        assets.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            let id = asset.localIdentifier
            visible.insert(id)
            var record = self.state.records[id] ?? MediaRecord(id: id, date: asset.creationDate ?? .distantPast,
                modified: asset.modificationDate, latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude, isVideo: asset.mediaType == .video,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot), duration: asset.duration)
            if record.modified != asset.modificationDate {
                record.analyzed = false
                record.hash = nil
                record.text = ""
                record.tags = []
                record.reasons = []
                record.aiSummary = nil
            }
            record.date = asset.creationDate ?? .distantPast
            record.modified = asset.modificationDate
            record.latitude = asset.location?.coordinate.latitude
            record.longitude = asset.location?.coordinate.longitude
            record.duration = asset.duration
            self.state.records[id] = record
        }
        // Limited access can temporarily hide records. Do not erase their saved labels.
        if authorization == .authorized {
            state.forget(Set(state.records.keys).subtracting(visible))
        }
        visibleIDs = visible
        status = "可访问 \(visible.count) 项 · 已分析 \(records.filter { visible.contains($0.id) && $0.analyzed }.count) 项"
        save()
    }

    @Published private(set) var visibleIDs: Set<String> = []
    var visibleActive: [MediaRecord] { active.filter { visibleIDs.contains($0.id) } }
    var visiblePending: [MediaRecord] { records.filter { visibleIDs.contains($0.id) && state.pending.contains($0.id) } }

    func scan() {
        guard !scanning && !busy && permitted else { return }
        refresh()
        scanning = true
        progress = 0
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.scanning = false; self.save() }
            let todo = self.records.filter { self.visibleIDs.contains($0.id) && !$0.analyzed }
            for (index, record) in todo.enumerated() {
                if Task.isCancelled { self.status = "扫描已暂停，下次从未完成项目继续"; return }
                self.status = "本地识别 \(index + 1) / \(todo.count)"
                if let image = await PhotoAccess.image(id: record.id) {
                    do {
                        let result = try await LocalAnalyzer.analyze(image, screenshot: record.isScreenshot, video: record.isVideo)
                        guard !Task.isCancelled else { return }
                        self.state.records[record.id]?.tags = result.tags
                        self.state.records[record.id]?.text = result.text
                        self.state.records[record.id]?.reasons = result.reasons
                        self.state.records[record.id]?.hash = result.hash
                        self.state.records[record.id]?.analyzed = true
                        self.state.records[record.id]?.unavailable = false
                    } catch {
                        self.state.records[record.id]?.reasons = ["本次识别失败，可稍后重试"]
                    }
                } else {
                    self.state.records[record.id]?.unavailable = true
                }
                self.progress = Double(index + 1) / Double(max(todo.count, 1))
                if index % 10 == 0 { self.save() }
            }
            let snapshots = self.records.filter { self.visibleIDs.contains($0.id) }
            let pairs = await Task.detached(priority: .utility) { Similarity.pairs(snapshots) }.value
            if Task.isCancelled { return }
            self.similar = pairs
            self.rebuildTrips()
            self.progress = 1
            self.status = "扫描完成 · \(self.similar.count) 组疑似相似照片"
        }
    }
    func pause() { scanTask?.cancel() }

    func stage(_ id: String) { state.stage(id); save() }
    func restore(_ id: String) {
        state.pending.remove(id)
        if state.lastStaged == id { state.lastStaged = nil }
        save()
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
    func removeKeyword(_ id: String, keyword: String) {
        state.records[id]?.keywords = state.records[id]?.customTags.filter { $0 != keyword }
        save()
    }
    var allKeywords: [String] {
        Array(Set(visibleActive.flatMap(\.customTags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func tagLabels(for record: MediaRecord) -> [String] {
        let category = PhotoTag.allCases.filter { record.effectiveTags.contains($0) }.map(\.rawValue)
        let people = state.people.filter { record.people.contains($0.id) }.map(\.name)
        let trips = state.trips.filter { $0.members.contains(record.id) }.map(\.name)
        return TagNames.normalized(record.customTags + people + trips + category)
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
        for id in ids where visibleIDs.contains(id) { state.records[id]?.people.insert(person) }
        save()
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
        state.records[id]?.keywords = TagNames.normalized((state.records[id]?.keywords ?? []) + (suggestion.keywords ?? []))
        save()
    }
    func rebuildTrips() {
        let existing = state.trips
        let proposed = TripBuilder.candidates(records.filter { visibleIDs.contains($0.id) })
        var result = existing.filter(\.manual)
        for var trip in proposed {
            if result.contains(where: { !$0.members.isDisjoint(with: trip.members) }) { continue }
            if let old = existing.first(where: { !$0.manual && !$0.members.isDisjoint(with: trip.members) }) {
                trip.id = old.id
            }
            result.append(trip)
        }
        state.trips = result
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
        let names = state.people.filter { record.people.contains($0.id) }.map(\.name)
        let trips = state.trips.filter { $0.members.contains(record.id) }.map(\.name)
        let content = ([record.text, record.aiSummary ?? ""] + record.customTags + record.effectiveTags.map(\.rawValue) + names + trips).joined(separator: " ").lowercased()
        return words.allSatisfy { content.contains($0) }
    }

    func exportAlbum(name: String, ids: [String]) async {
        guard !busy && !scanning else { message = "请先暂停扫描，再创建系统相册。"; return }
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
        guard !busy && !scanning else { message = "请先暂停扫描，再提交删除。"; return }
        let ids = Set(visiblePending.map(\.id))
        guard !ids.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        guard assets.count > 0 else { refresh(); return }
        var actual: Set<String> = []
        assets.enumerateObjects { asset, _, _ in actual.insert(asset.localIdentifier) }
        busy = true
        defer { busy = false }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            state.forget(actual)
            similar.removeAll { !$0.allSatisfy { state.records[$0] != nil } }
            save(); refresh()
            message = "系统已接受删除。可在苹果照片的「最近删除」中恢复。"
        } catch { message = "没有完成删除，待删队列已保留：\(error.localizedDescription)" }
    }
}
