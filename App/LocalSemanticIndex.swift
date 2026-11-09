import Foundation
import CoreML
import CoreImage
import UIKit
import SQLite3

enum SemanticError: LocalizedError {
    case resources, invalidVector, database
    var errorDescription: String? {
        switch self {
        case .resources: return "本地搜索模型没有完整载入，请重开 App 或重新安装完整版。"
        case .invalidVector: return "本次图片特征无效，可稍后重试。"
        case .database: return "搜索索引暂时无法读写；解锁手机后重试。"
        }
    }
}

struct SemanticHit: Identifiable, Equatable {
    let id: String
    let score: Float
}

struct SearchVector { let id: String; let stamp: String; let vector: [Float] }

enum VectorMath {
    static func normalized(_ values: [Float]) throws -> [Float] {
        guard values.count == 512, values.allSatisfy(\.isFinite) else { throw SemanticError.invalidVector }
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0.00001 else { throw SemanticError.invalidVector }
        return values.map { $0 / norm }
    }
    static func pack(_ values: [Float]) throws -> Data {
        let half = try normalized(values).map(Float16.init)
        return half.withUnsafeBytes { Data($0) }
    }
    static func unpack(_ data: Data) throws -> [Float] {
        guard data.count == 1024 else { throw SemanticError.invalidVector }
        return try normalized(data.withUnsafeBytes { raw in
            (0..<512).map { Float(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self))) }
        })
    }
    static func score(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -.infinity }
        return zip(a,b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}

// Serial actor keeps Core ML, SQLite, vector ranking and image resizing off the UI.
// Vectors are never serialized into the main library JSON or sent to an API.
actor LocalSemanticIndex {
    static let shared = LocalSemanticIndex()
    static let modelID = "openai-clip-vit-b32-fp16-v1"
    private var database: OpaquePointer?
    private let databaseURL: URL
    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private let context = CIContext(options: [.cacheIntermediates: false])
    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-search-v1.sqlite")
    }
    deinit { if let database { sqlite3_close(database) } }
    private func open() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else { throw SemanticError.database }
        sqlite3_busy_timeout(db, 1000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=DELETE; CREATE TABLE IF NOT EXISTS embeddings (id TEXT PRIMARY KEY, stamp TEXT NOT NULL, model TEXT NOT NULL, vector BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); throw SemanticError.database
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: databaseURL.path)
        database = db; return db
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        let db = try open(); var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SemanticError.database }
        return statement
    }
    private func bind(_ string: String, _ position: Int32, _ statement: OpaquePointer) {
        _ = string.withCString { sqlite3_bind_text(statement, position, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    func existing(eligible: [String: String]) throws -> Set<String> {
        let statement = try statement("SELECT id, stamp FROM embeddings WHERE model = ?")
        defer { sqlite3_finalize(statement) }
        bind(Self.modelID, 1, statement)
        var result: Set<String> = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            if eligible[id] == String(cString: sqlite3_column_text(statement, 1)) { result.insert(id) }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw SemanticError.database }
        return result
    }
    func put(id: String, stamp: String, vector: [Float]) throws {
        let statement = try statement("INSERT OR REPLACE INTO embeddings (id, stamp, model, vector) VALUES (?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(id, 1, statement); bind(stamp, 2, statement); bind(Self.modelID, 3, statement)
        let data = try VectorMath.pack(vector)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SemanticError.database }
    }
    func putBatch(_ batch: [SearchVector]) throws {
        let db = try open()
        guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK else { throw SemanticError.database }
        do {
            for value in batch { try put(id: value.id, stamp: value.stamp, vector: value.vector) }
            guard sqlite3_exec(db,"COMMIT",nil,nil,nil) == SQLITE_OK else { throw SemanticError.database }
        } catch { sqlite3_exec(db,"ROLLBACK",nil,nil,nil); throw error }
    }
    func rank(vector: [Float], eligible: [String: String], limit: Int = 60) throws -> [SemanticHit] {
        let query = try VectorMath.normalized(vector)
        let statement = try statement("SELECT id, stamp, vector FROM embeddings WHERE model = ?")
        defer { sqlite3_finalize(statement) }
        bind(Self.modelID, 1, statement)
        var best: [SemanticHit] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            if eligible[id] == String(cString: sqlite3_column_text(statement, 1)),
               let bytes = sqlite3_column_blob(statement, 2), sqlite3_column_bytes(statement, 2) == 1024 {
                let data = Data(bytes: bytes, count: 1024)
                if let vector = try? VectorMath.unpack(data) {
                    let score = VectorMath.score(query, vector)
                    if best.count < limit || score > (best.last?.score ?? -.infinity) {
                        best.append(SemanticHit(id: id, score: score))
                        best.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
                        if best.count > limit { best.removeLast() }
                    }
                }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw SemanticError.database }
        return best
    }
    private func folder() throws -> URL {
        guard let url = Bundle.main.url(forResource: "CLIPModels", withExtension: nil) else { throw SemanticError.resources }
        return url
    }
    private func load(name: String) throws -> MLModel {
        let url = try folder().appendingPathComponent(name + ".mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { throw SemanticError.resources }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try MLModel(contentsOf: url, configuration: configuration)
    }
    func unload() { imageModel = nil; textModel = nil; tokenizer = nil; context.clearCaches() }
    func encode(text: String) throws -> [Float] {
        if tokenizer == nil { tokenizer = try CLIPTokenizer(folder: folder()) }
        if textModel == nil { textModel = try load(name: "CLIPText") }
        let tokens = try tokenizer!.encode(text)
        let array = try MLMultiArray(shape: [1, 77], dataType: .int32)
        for (index, token) in tokens.enumerated() { array[index] = NSNumber(value: token) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: array)])
        return try embedding(textModel!.prediction(from: input))
    }
    func encode(image: UIImage) throws -> [Float] {
        if imageModel == nil { imageModel = try load(name: "CLIPImage") }
        return try autoreleasepool {
            guard let cg = image.cgImage else { throw SemanticError.invalidVector }
            let source = CIImage(cgImage: cg)
            // Preserve the entire scene: a baguette near the edge of a wide buffet
            // must not be permanently removed by a centre crop.
            let scale = min(224/source.extent.width, 224/source.extent.height)
            let resized = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = resized.transformed(by: CGAffineTransform(translationX: (224-resized.extent.width)/2, y: (224-resized.extent.height)/2))
            let background = CIImage(color: CIColor(red: 0.48145466, green: 0.4578275, blue: 0.40821073)).cropped(to: CGRect(x: 0,y: 0,width: 224,height: 224))
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 224, 224, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw SemanticError.invalidVector }
            context.render(positioned.composited(over: background), to: buffer)
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
            return try embedding(imageModel!.prediction(from: input))
        }
    }
    private func embedding(_ output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue, array.count == 512 else { throw SemanticError.invalidVector }
        return try VectorMath.normalized((0..<512).map { array[$0].floatValue })
    }
}

extension MediaRecord {
    var searchStamp: String { String((modified ?? date).timeIntervalSince1970.bitPattern, radix: 16) }
}
