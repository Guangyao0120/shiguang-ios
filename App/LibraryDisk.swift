import Foundation
import SQLite3

// Individual records are committed transactionally. The previous JSON is kept
// as a migration backup; normal progress saves never rewrite that whole file.
actor LibraryDisk {
    struct WriteMetrics: Equatable {
        var recordsWritten = 0
        var encodedBytes = 0
        var transactions = 0
    }
    let url: URL
    private let sqliteURL: URL
    private var database: OpaquePointer?
    private var lastRevision = -1
    private var lastRecords: [String: MediaRecord] = [:]
    private var lastMetadata: Data?
    private var lastMetadataState: LibraryState?
    private var cacheLoaded = false
    private var lastMetricTime = Date.distantPast
    private(set) var writeMetrics = WriteMetrics()
    init(url: URL) { self.url = url; sqliteURL = url.deletingPathExtension().appendingPathExtension("sqlite") }
    deinit { if let database { sqlite3_close(database) } }

    private func open() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: sqliteURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        var db: OpaquePointer?
        guard sqlite3_open(sqliteURL.path,&db) == SQLITE_OK, let db else { throw DiskError.database }
        sqlite3_busy_timeout(db,1000)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:sqliteURL.path)
        let schema = "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=2000; CREATE TABLE IF NOT EXISTS library_records (id TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS library_state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);"
        guard sqlite3_exec(db,schema,nil,nil,nil) == SQLITE_OK else { sqlite3_close(db); throw DiskError.database }
        for suffix in ["-wal","-shm"] {
            if FileManager.default.fileExists(atPath:sqliteURL.path+suffix) {
                try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:sqliteURL.path+suffix)
            }
        }
        database = db; return db
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        let db = try open(); var result: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&result,nil) == SQLITE_OK, let result else { throw DiskError.database }
        return result
    }
    private func bind(_ value: String, to statement: OpaquePointer, position: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement,position,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
    }
    private func bind(_ data: Data, to statement: OpaquePointer, position: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement,position,$0.baseAddress,Int32(data.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
    }
    private func data(_ statement: OpaquePointer, column: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(statement,column) else { throw DiskError.database }
        return Data(bytes:bytes,count:Int(sqlite3_column_bytes(statement,column)))
    }
    func load() throws -> LibraryState {
        let metadata = try statement("SELECT payload FROM library_state WHERE id=1")
        defer { sqlite3_finalize(metadata) }
        let step = sqlite3_step(metadata)
        if step == SQLITE_ROW {
            let bytes = try data(metadata,column:0)
            var state = try JSONDecoder().decode(LibraryState.self,from:bytes)
            let metadataState = state
            let records = try statement("SELECT id,payload FROM library_records")
            defer { sqlite3_finalize(records) }
            var result = sqlite3_step(records)
            while result == SQLITE_ROW {
                let record = try JSONDecoder().decode(MediaRecord.self,from:data(records,column:1))
                state.records[record.id] = record
                result = sqlite3_step(records)
            }
            guard result == SQLITE_DONE else { throw DiskError.database }
            lastRecords = state.records; lastMetadata = bytes; lastMetadataState = metadataState; cacheLoaded = true
            return state
        }
        guard step == SQLITE_DONE else { throw DiskError.database }
        cacheLoaded = true; lastRecords = [:]; lastMetadata = nil; lastMetadataState = nil
        guard FileManager.default.fileExists(atPath:url.path) else { return LibraryState() }
        let state = try JSONDecoder().decode(LibraryState.self,from:Data(contentsOf:url))
        try write(state,revision:0)
        return state
    }
    func write(_ state: LibraryState, revision: Int) throws {
        guard revision >= lastRevision else { return }
        if !cacheLoaded { _ = try load() }
        let updates = state.records.values.filter { lastRecords[$0.id] != $0 }
        let removed = Set(lastRecords.keys).subtracting(state.records.keys)
        var metadata = state; metadata.records = [:]
        let metadataChanged = metadata != lastMetadataState
        let metadataBytes = metadataChanged ? try JSONEncoder().encode(metadata) : (lastMetadata ?? Data())
        writeMetrics.recordsWritten = 0; writeMetrics.encodedBytes = 0
        guard !updates.isEmpty || !removed.isEmpty || metadataChanged else { lastRevision = revision; return }
        let db = try open()
        guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK else { throw DiskError.database }
        do {
            var bytesWritten = 0
            let upsert = try statement("INSERT OR REPLACE INTO library_records (id,payload) VALUES (?,?)")
            defer { sqlite3_finalize(upsert) }
            for record in updates {
                let bytes = try JSONEncoder().encode(record); bytesWritten += bytes.count
                sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
                bind(record.id,to:upsert,position:1); bind(bytes,to:upsert,position:2)
                guard sqlite3_step(upsert) == SQLITE_DONE else { throw DiskError.database }
            }
            if !removed.isEmpty {
                let delete = try statement("DELETE FROM library_records WHERE id=?")
                defer { sqlite3_finalize(delete) }
                for id in removed {
                    sqlite3_reset(delete); sqlite3_clear_bindings(delete); bind(id,to:delete,position:1)
                    guard sqlite3_step(delete) == SQLITE_DONE else { throw DiskError.database }
                }
            }
            if metadataChanged {
                let save = try statement("INSERT OR REPLACE INTO library_state (id,payload) VALUES (1,?)")
                defer { sqlite3_finalize(save) }
                bind(metadataBytes,to:save,position:1)
                guard sqlite3_step(save) == SQLITE_DONE else { throw DiskError.database }
                bytesWritten += metadataBytes.count
            }
            guard sqlite3_exec(db,"COMMIT",nil,nil,nil) == SQLITE_OK else { throw DiskError.database }
            lastRevision = revision; lastRecords = state.records; lastMetadata = metadataBytes; lastMetadataState = metadata
            writeMetrics.recordsWritten = updates.count; writeMetrics.encodedBytes = bytesWritten; writeMetrics.transactions += 1
            // Aggregate counters make USB diagnostics possible without copying OCR or images.
            var pendingImages = 0, pendingScreenshots = 0, analyzed = 0, unavailable = 0
            for record in state.records.values {
                if record.analyzed { analyzed += 1 }
                if record.unavailable { unavailable += 1 }
                if (!record.analyzed || record.needsSceneryRefinement) && !record.unavailable && !record.isVideo {
                    pendingImages += 1; if record.isScreenshot { pendingScreenshots += 1 }
                }
            }
            let counters = ["records":state.records.count,"analyzed":analyzed,"unavailable":unavailable,
                "pending_images":pendingImages,"pending_screenshots":pendingScreenshots,
                "last_saved_records":updates.count,"last_encoded_bytes":bytesWritten]
            if let data = try? JSONEncoder().encode(counters) {
                try? data.write(to:url.deletingLastPathComponent().appendingPathComponent("library-counts.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            }
        } catch { sqlite3_exec(db,"ROLLBACK",nil,nil,nil); throw error }
    }
    enum DiskError: LocalizedError {
        case database
        var errorDescription: String? { "整理数据库暂时无法读写，请解锁后重试。" }
    }
    func saveScanMeasurements(_ metrics: ScanMeasurements) throws {
        guard metrics.timestamp >= lastMetricTime else { return }
        let bytes = try JSONEncoder().encode(metrics)
        try bytes.write(to:url.deletingLastPathComponent().appendingPathComponent("scan-performance.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        lastMetricTime = metrics.timestamp
    }
}
