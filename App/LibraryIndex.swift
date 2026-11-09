import Foundation
import Photos

// Built once per data revision off the UI thread. Views only read prepared arrays.
struct LibraryIndex {
    var records: [MediaRecord] = []
    var active: [MediaRecord] = []
    var pending: [MediaRecord] = []
    var byTag: [PhotoTag: [MediaRecord]] = [:]
    var byKeyword: [String: [MediaRecord]] = [:]
    var byPerson: [UUID: [MediaRecord]] = [:]
    var byTrip: [UUID: [MediaRecord]] = [:]
    var labels: [String: [String]] = [:]
    var search: [String: String] = [:]
    var keywords: [String] = []

    static func build(state: LibraryState, visible: Set<String>) -> LibraryIndex {
        var index = LibraryIndex()
        index.records = state.records.values.filter { visible.contains($0.id) }
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        let people = Dictionary(uniqueKeysWithValues: state.people.map { ($0.id, $0.name) })
        var tripsByMedia: [String: [(UUID, String)]] = [:]
        for trip in state.trips {
            for id in trip.members where visible.contains(id) { tripsByMedia[id, default: []].append((trip.id, trip.name)) }
        }
        var keywordNames: [String: String] = [:]
        for record in index.records {
            if Task.isCancelled { return LibraryIndex() }
            let tags = record.effectiveTags
            let categories = PhotoTag.allCases.filter { tags.contains($0) }
            let personNames = record.people.compactMap { people[$0] }.sorted()
            let tripNames = (tripsByMedia[record.id] ?? []).map { $0.1 }.sorted()
            index.labels[record.id] = TagNames.normalized(record.customTags + personNames + tripNames + categories.map(\.rawValue))
            index.search[record.id] = ([record.text, record.aiSummary ?? ""] + record.customTags + personNames + tripNames + categories.map(\.rawValue)).joined(separator: " ").lowercased()
            if state.pending.contains(record.id) { index.pending.append(record); continue }
            index.active.append(record)
            for tag in categories { index.byTag[tag, default: []].append(record) }
            for keyword in record.customTags {
                let key = keyword.lowercased()
                keywordNames[key] = keywordNames[key] ?? keyword
                index.byKeyword[key, default: []].append(record)
            }
            for person in record.people { index.byPerson[person, default: []].append(record) }
            for trip in tripsByMedia[record.id] ?? [] { index.byTrip[trip.0, default: []].append(record) }
        }
        index.keywords = keywordNames.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return index
    }
}

enum ScanPolicy {
    static func candidates(_ records: [MediaRecord], screenshotsOnly: Bool, limit: Int = 100) -> [MediaRecord] {
        Array(records.lazy.filter {
            !$0.analyzed && !$0.isVideo && !$0.unavailable && (!screenshotsOnly || $0.isScreenshot)
        }.prefix(max(0, limit)))
    }
}

actor LibraryDisk {
    let url: URL
    private var lastRevision = -1
    init(url: URL) { self.url = url }
    func load() throws -> LibraryState {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryState() }
        return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: url))
    }
    func write(_ state: LibraryState, revision: Int) throws {
        guard revision >= lastRevision else { return }
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        lastRevision = revision
    }
}

enum LibraryMetadata {
    static func visibleIdentifiers() -> Set<String> {
        let assets = PHAsset.fetchAssets(with: nil)
        var ids: Set<String> = []
        assets.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }
    static func fetch() -> [MediaRecord] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let assets = PHAsset.fetchAssets(with: options)
        var records: [MediaRecord] = []
        records.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            autoreleasepool {
                records.append(MediaRecord(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast,
                    modified: asset.modificationDate, latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude, isVideo: asset.mediaType == .video,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot), duration: asset.duration))
            }
        }
        return records
    }
    static func merge(_ metadata: [MediaRecord], into old: LibraryState, fullAccess: Bool, retryUnavailable: Bool) -> LibraryState {
        var next = old
        let visible = Set(metadata.map(\.id))
        for value in metadata {
            var record = next.records[value.id] ?? value
            if record.modified != value.modified {
                record.analyzed = false; record.hash = nil; record.text = ""
                record.tags = []; record.reasons = []; record.aiSummary = nil
            }
            record.date = value.date; record.modified = value.modified
            record.latitude = value.latitude; record.longitude = value.longitude
            record.duration = value.duration
            if retryUnavailable { record.unavailable = false }
            if record.isScreenshot { record.tags.insert(.screenshot) }
            if record.isVideo { record.tags.insert(.video) }
            next.records[value.id] = record
        }
        if fullAccess { next.forget(Set(next.records.keys).subtracting(visible)) }
        return next
    }
}
