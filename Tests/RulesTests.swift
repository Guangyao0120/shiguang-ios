import XCTest
import SwiftUI
import UIKit
@testable import Shiguang

final class RulesTests: XCTestCase {
    func testLegacySceneryRefinesOnceWithoutRepeatingCompletedOCR() {
        var old = media("old"); old.tags = [.scenery]; old.analyzed = true; old.text = "Keep OCR"
        let unprocessed = media("new")
        XCTAssertTrue(old.needsSceneryRefinement)
        XCTAssertEqual(ScanPolicy.candidates([unprocessed,old],screenshotsOnly:false,limit:1).map(\.id),["old"])
        old.visualLabels = []
        XCTAssertFalse(old.needsSceneryRefinement)
        XCTAssertEqual(ScanPolicy.candidates([old,unprocessed],screenshotsOnly:false,limit:10).map(\.id),["new"])
        XCTAssertEqual(old.text,"Keep OCR")
    }


    func testLegacyBillsShareOneCategoryAndManualRemovalStillWorks() throws {
        var record = media("bill")
        record.tags = [.receipt,.invoice,.payment,.ticket]
        let oldData = try JSONEncoder().encode(record)
        let loaded = try JSONDecoder().decode(MediaRecord.self,from:oldData)
        XCTAssertEqual(loaded.effectiveTags,[.documents])
        XCTAssertFalse(PhotoTag.allCases.contains(.receipt))
        XCTAssertFalse(PhotoTag.allCases.contains(.invoice))
        XCTAssertFalse(PhotoTag.allCases.contains(.payment))
        XCTAssertFalse(PhotoTag.allCases.contains(.ticket))
        record.removedTags = [.documents]
        XCTAssertEqual(record.effectiveTags,[.other])
        record.removedTags = []; record.addedTags = [.portrait]
        XCTAssertEqual(record.effectiveTags,[.documents,.portrait])
    }
    func testCityAndNatureSplitUsesEvidenceAndPreservesUncertainLegacyPhotos() {
        XCTAssertEqual(CategoryRules.sceneryTags(["urban","building"]),[.cityScenery])
        XCTAssertEqual(CategoryRules.sceneryTags(["forest","mountain"]),[.naturalScenery])
        XCTAssertEqual(CategoryRules.sceneryTags(["cityscape","river"]),[.cityScenery,.naturalScenery])
        var old = media("old"); old.tags = [.scenery]
        XCTAssertEqual(old.effectiveTags,[.other])
        old.visualLabels = ["cityscape"]
        XCTAssertEqual(old.effectiveTags,[.cityScenery])
        old.visualLabels = ["mountain"]
        XCTAssertEqual(old.effectiveTags,[.naturalScenery])
        XCTAssertEqual(old.tags,[.scenery]) // Preserve the original stored classification.
    }
    func testReviewSnapshotsStayStableForAllPhotosPortraitPeopleAndTrips() {
        var state = LibraryState()
        let person = NamedPerson(name:"Test person")
        state.people = [person]
        for (i,id) in ["a","b","c"].enumerated() {
            var value = media(id,Double(3-i)); value.tags = [.portrait]; value.people = [person.id]
            state.records[id] = value
        }
        let trip = Trip(name:"Test trip",members:["a","b","c"]); state.trips = [trip]
        let before = LibraryIndex.build(state:state,visible:Set(state.records.keys))
        let sessions = [before.active,before.byTag[.portrait]!,before.byPerson[person.id]!,before.byTrip[trip.id]!].map { ReviewSession(ids:$0.map(\.id)) }
        state.stage("a")
        let after = LibraryIndex.build(state:state,visible:Set(state.records.keys))
        XCTAssertEqual(after.byTag[.portrait]?.map(\.id),["b","c"])
        for session in sessions {
            XCTAssertEqual(session.ids,["a","b","c"])
            let next = ReviewNavigation.next(from:0,ids:session.ids,existing:Set(state.records.keys),pending:state.pending)
            XCTAssertEqual(session.ids[next],"b")
            let previous = ReviewNavigation.previous(from:next,ids:session.ids,existing:Set(state.records.keys))
            XCTAssertEqual(session.ids[previous],"a")
        }
        XCTAssertEqual(ReviewSession(ids:["a","a","b"]).ids,["a","b"])
        XCTAssertFalse(ReviewNavigation.advanceAfterPreview(id:"a",current:"a",wasPending:true,pending:["a"]))
        XCTAssertFalse(ReviewNavigation.advanceAfterPreview(id:"a",current:"a",wasPending:false,pending:[]))
        XCTAssertTrue(ReviewNavigation.advanceAfterPreview(id:"a",current:"a",wasPending:false,pending:["a"]))
        XCTAssertFalse(ReviewNavigation.advanceAfterPreview(id:"a",current:"b",wasPending:false,pending:["a"]))
    }
    func testDiskMigratesLegacyJSONWithoutOverwritingItsBackup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("library-v1.json")
        var old = LibraryState(); var record = media("a"); record.tags = [.payment]; record.analyzed = true; record.text = "Saved OCR"
        old.records[record.id] = record; old.pending = ["a"]; old.lastStaged = "a"; old.customTagNames = ["Saved tag"]
        let backup = try JSONEncoder().encode(old); try backup.write(to:url)
        let disk = LibraryDisk(url:url)
        var loaded = try await disk.load()
        XCTAssertEqual(loaded.records["a"],record)
        XCTAssertEqual(loaded.pending,["a"])
        loaded.records["b"] = media("b")
        try await disk.write(loaded,revision:1)
        let reopenedDisk = LibraryDisk(url:url)
        let reopened = try await reopenedDisk.load()
        XCTAssertEqual(reopened.records.count,2)
        XCTAssertEqual(reopened.records["a"]?.text,"Saved OCR")
        XCTAssertEqual(reopened.customTagNames,["Saved tag"])
        XCTAssertEqual(try Data(contentsOf:url),backup)
        try await reopenedDisk.write(reopened,revision:2)
        let reopenedMetrics = await reopenedDisk.writeMetrics
        XCTAssertEqual(reopenedMetrics.transactions,0)
    }
    func testProgressSaveEncodesOnlyChangedRecordsAndSkipsIdenticalSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let disk = LibraryDisk(url:folder.appendingPathComponent("state.json"))
        var state = LibraryState()
        for i in 0..<1000 { var record = media("\(i)"); record.text = String(repeating:"x",count:4096); state.records[record.id] = record }
        try await disk.write(state,revision:1)
        let first = await disk.writeMetrics
        XCTAssertEqual(first.recordsWritten,1000)
        state.records["5"]?.text = String(repeating:"y",count:4096)
        try await disk.write(state,revision:2)
        let changed = await disk.writeMetrics
        XCTAssertEqual(changed.recordsWritten,1)
        XCTAssertLessThan(changed.encodedBytes,first.encodedBytes/100)
        try await disk.write(state,revision:3)
        let unchanged = await disk.writeMetrics
        XCTAssertEqual(unchanged.recordsWritten,0)
        XCTAssertEqual(unchanged.encodedBytes,0)
        XCTAssertEqual(unchanged.transactions,changed.transactions)
    }
    func testFailedRecordEncodingRollsBackWholeProgressTransaction() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("state.json"), disk = LibraryDisk(url:url)
        var original = LibraryState(); original.records["a"] = media("a"); original.records["b"] = media("b")
        try await disk.write(original,revision:1)
        var bad = original; bad.records["a"]?.text = "Must not partially save"
        bad.records["b"]?.date = Date(timeIntervalSinceReferenceDate:.infinity)
        do { try await disk.write(bad,revision:2); XCTFail("Expected encoding failure") } catch { }
        let restored = try await LibraryDisk(url:url).load()
        XCTAssertEqual(restored.records,original.records)
    }
    @MainActor
    func testPhotoReaderPrefetchesOneAheadAndCancellationDoesNotStartAnother() async {
        var starts: [String] = [], cancelled: [String] = []
        var waiting: [String:CheckedContinuation<UIImage?,Never>] = [:]
        let reader = ScanImagePrefetcher(records:[media("a"),media("b"),media("c")]) { record in
            starts.append(record.id)
            let result = await withCheckedContinuation { waiting[record.id] = $0 }
            if Task.isCancelled { cancelled.append(record.id) }
            return result
        }
        for _ in 0..<30 { if waiting["a"] != nil { break }; await Task.yield() }
        XCTAssertEqual(starts,["a"])
        waiting.removeValue(forKey:"a")?.resume(returning:UIImage())
        let first = await reader.next()
        XCTAssertNotNil(first)
        for _ in 0..<30 { if waiting["b"] != nil { break }; await Task.yield() }
        XCTAssertEqual(starts,["a","b"])
        reader.cancel()
        waiting.removeValue(forKey:"b")?.resume(returning:nil)
        for _ in 0..<30 { if cancelled.contains("b") { break }; await Task.yield() }
        let afterCancel = await reader.next()
        XCTAssertNil(afterCancel)
        XCTAssertEqual(starts,["a","b"])
        XCTAssertEqual(cancelled,["b"])
    }
    @MainActor
    func testReusedVisionRequestsDoNotLeakPreviousScreenshotText() async throws {
        let size = CGSize(width:1024,height:640)
        let invoice = UIGraphicsImageRenderer(size:size).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin:.zero,size:size))
            ("INVOICE 123" as NSString).draw(at:CGPoint(x:40,y:100),withAttributes:[.font:UIFont.systemFont(ofSize:64),.foregroundColor:UIColor.black])
        }
        let blank = UIGraphicsImageRenderer(size:size).image { context in UIColor.white.setFill(); context.fill(CGRect(origin:.zero,size:size)) }
        let first = try await LocalAnalyzer.analyze(invoice,screenshot:true,video:false,cpuOnly:true)
        XCTAssertTrue(first.text.uppercased().contains("INVOICE"))
        XCTAssertTrue(first.tags.contains(.documents))
        let second = try await LocalAnalyzer.analyze(blank,screenshot:true,video:false,cpuOnly:true)
        XCTAssertTrue(second.text.isEmpty)
        XCTAssertFalse(second.tags.contains(.documents))
    }


    func testReviewMovesInBothDirectionsAndCanRevisitStagedImages() {
        let ids = ["a", "b", "gone", "c"]
        let existing: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(ReviewNavigation.next(from: 0, ids: ids, existing: existing, pending: ["b"]), 3)
        XCTAssertEqual(ReviewNavigation.previous(from: 3, ids: ids, existing: existing), 1)
        XCTAssertEqual(ReviewNavigation.previous(from: 0, ids: ids, existing: existing), 0)
        XCTAssertEqual(ReviewNavigation.next(from: 3, ids: ids, existing: existing, pending: []), 4)
        XCTAssertEqual(ReviewNavigation.previous(from: 4, ids: ids, existing: existing), 3)
    }
    func testFoodClassificationUsesVisualContent() {
        let result = CategoryRules.classify(text: "", screenshot: false, faces: 0, labels: ["bread", "breakfast"], isVideo: false)
        XCTAssertTrue(result.0.contains(.food))
        XCTAssertFalse(CategoryRules.classify(text: "", screenshot: true, faces: 0, labels: ["document"], isVideo: false).0.contains(.food))
    }
    func testVectorPackingRejectsInvalidFeatures() throws {
        var vector = [Float](repeating: 0, count: 512); vector[0] = 3; vector[1] = 4
        let packed = try VectorMath.pack(vector)
        XCTAssertEqual(packed.count, 1024)
        let decoded = try VectorMath.unpack(packed)
        XCTAssertEqual(decoded[0], 0.6, accuracy: 0.001)
        XCTAssertEqual(VectorMath.score(decoded,decoded), 1, accuracy: 0.001)
        XCTAssertThrowsError(try VectorMath.pack([Float](repeating: 0,count: 512)))
        XCTAssertThrowsError(try VectorMath.unpack(Data([0,1])))
        vector[0] = .nan
        XCTAssertThrowsError(try VectorMath.pack(vector))
    }
    func testSearchIndexPersistsAndExcludesHiddenOrModifiedPhotos() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var vector = [Float](repeating: 0,count: 512); vector[0] = 1
        let index = LocalSemanticIndex(databaseURL: url)
        try await index.putBatch([SearchVector(id:"a",stamp:"old",vector:vector), SearchVector(id:"hidden",stamp:"1",vector:vector)])
        let existing = try await index.existing(eligible: ["a":"old"])
        XCTAssertEqual(existing, ["a"])
        let changed = try await index.rank(vector: vector, eligible: ["a":"new"])
        XCTAssertTrue(changed.isEmpty)
        let reopened = LocalSemanticIndex(databaseURL: url)
        let hits = try await reopened.rank(vector: vector, eligible: ["a":"old"])
        XCTAssertEqual(hits.map(\.id), ["a"])
        XCTAssertEqual(hits.first!.score,1,accuracy:0.001)
        do {
            try await index.putBatch([SearchVector(id:"rollback",stamp:"1",vector:vector), SearchVector(id:"bad",stamp:"1",vector:[])])
            XCTFail("Invalid batch must roll back")
        } catch { }
        let rolled = try await index.existing(eligible:["rollback":"1"])
        XCTAssertTrue(rolled.isEmpty)
    }
    func testBundledTokenizerMatchesOfficialOpenAITokensAndTruncatesSafely() throws {
        let folder = try XCTUnwrap(Bundle.main.url(forResource:"CLIPModels",withExtension:nil))
        let data = try Data(contentsOf:folder.appendingPathComponent("validation.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let fixtures = try XCTUnwrap(json["token_fixtures"] as? [String:[Int]])
        let tokenizer = try CLIPTokenizer(folder:folder)
        for (text,expected) in fixtures { XCTAssertEqual(try tokenizer.encode(text).map(Int.init),expected,text) }
    }
    func testCoreMLTextModelMatchesConversionReference() async throws {
        let folder = try XCTUnwrap(Bundle.main.url(forResource:"CLIPModels",withExtension:nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("validation.json"))) as? [String:Any])
        let reference = try VectorMath.normalized(try XCTUnwrap(json["text_reference"] as? [Double]).map(Float.init))
        let vector = try await LocalSemanticIndex.shared.encode(text:"a photo of a sliced baguette")
        XCTAssertGreaterThan(VectorMath.score(vector,reference),0.995)
        await LocalSemanticIndex.shared.unload()
    }
    @MainActor
    func testCoreMLImageModelRunsOffUIAndProducesNormalizedVector() async throws {
        let image = UIGraphicsImageRenderer(size:CGSize(width:300,height:180)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x:0,y:0,width:300,height:180))
        }
        let vector = try await LocalSemanticIndex.shared.encode(image:image)
        XCTAssertEqual(vector.count,512)
        XCTAssertEqual(VectorMath.score(vector,vector),1,accuracy:0.001)
        await LocalSemanticIndex.shared.unload()
    }

    @MainActor
    func testForegroundScanStartsBeforeNotificationPermissionOrBackgroundHandler() async throws {
        let suite = "ScanStartup-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "backgroundEnabled"); defaults.set(true, forKey: "completionNotice")
        var permission: CheckedContinuation<Void, Never>?
        var backgroundRequests = 0
        let scanner = StubScanDriver()
        let runtime = ScanRuntime(defaults: defaults, submitBackground: { backgroundRequests += 1 }, requestNotifications: {
            await withCheckedContinuation { permission = $0 }
        })
        runtime.store = scanner
        runtime.start()
        // The background callback intentionally never arrives, and permission
        // intentionally stays pending until after these assertions.
        XCTAssertEqual(scanner.scanCalls, 1)
        XCTAssertTrue(scanner.scanning)
        XCTAssertFalse(runtime.launching)
        XCTAssertEqual(backgroundRequests, 1)
        for _ in 0..<20 { if permission != nil { break }; await Task.yield() }
        XCTAssertNotNil(permission)
        permission?.resume()
        scanner.finish()
    }
    @MainActor
    func testRejectedBackgroundRequestKeepsForegroundScanRunningAndPreventsDoubleStart() async throws {
        let suite = "ScanRejection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "backgroundEnabled"); defaults.set(false, forKey: "completionNotice")
        let scanner = StubScanDriver()
        let runtime = ScanRuntime(defaults: defaults, submitBackground: { throw NSError(domain: "SchedulerTest", code: 1) })
        runtime.store = scanner; runtime.start(); runtime.start()
        XCTAssertEqual(scanner.scanCalls, 1)
        XCTAssertTrue(scanner.scanning)
        XCTAssertTrue(runtime.note.contains("前台整理已开始"))
        scanner.finish()
    }
    @MainActor
    func testEmptyAndRefreshingLibrariesGiveFeedbackInsteadOfWaitingForBackground() async throws {
        let suite = "ScanEmpty-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = StubScanDriver(); scanner.state.records = [:]
        var backgroundRequests = 0
        let runtime = ScanRuntime(defaults: defaults, submitBackground: { backgroundRequests += 1 })
        runtime.store = scanner; runtime.start()
        XCTAssertEqual(scanner.status, "暂无待整理图片")
        XCTAssertEqual(scanner.scanCalls, 0)
        scanner.refreshing = true; runtime.start()
        XCTAssertEqual(scanner.status, "正在读取相册，请稍后再试")
        XCTAssertEqual(backgroundRequests, 0)
    }
    func testCustomCategoriesExistBeforeAssignmentAndSurviveStorage() throws {
        var state = LibraryState(); state.customTagNames = [" 工作 ", "工作", "纪念"]
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        let index = LibraryIndex.build(state: decoded, visible: [])
        XCTAssertEqual(Set(index.keywords), ["工作", "纪念"])
        XCTAssertTrue(index.byKeyword.isEmpty)
    }
    func testVideoTitlesUseExplicitRecipientsAndDoNotInventNames() {
        XCTAssertEqual(VideoTitleRules.title(from: "桐桐你好，祝桐桐生日快乐！"), "桐桐 · 生日祝福")
        XCTAssertEqual(VideoTitleRules.title(from: "祝你生日快乐"), "生日祝福 · 对象待确认")
        XCTAssertEqual(VideoTitleRules.title(from: "祝大家新年快乐"), "新年祝福 · 对象待确认")
        XCTAssertEqual(VideoTitleRules.title(from: "祝愿小王新婚快乐"), "小王 · 新婚祝福")
        XCTAssertEqual(VideoTitleRules.title(from: "周末我们去了公园。拍了很多照片"), "周末我们去了公园")
    }
    func testTripNameUsesLunarHolidayAndKnownLocationWithoutGuessingUnknownCities() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-10-06T04:00:00Z"))
        var record = media("a", lat: 28.228, lon: 112.939); record.date = date
        XCTAssertEqual(TripNaming.name(for: [record]), "中秋 · 长沙")
        XCTAssertNil(TripNaming.city(latitude: 0, longitude: 0))
        record.latitude = 0; record.longitude = 0
        XCTAssertEqual(TripNaming.name(for: [record]), "中秋 · 出游候选")
    }
    func testVideoTranscriptAndTitleSurviveStorageAndAreSearchable() throws {
        var record = media("v"); record.isVideo = true
        record.voiceTranscript = "祝桐桐生日快乐"; record.videoTitle = "桐桐 · 生日祝福"
        let decoded = try JSONDecoder().decode(MediaRecord.self, from: JSONEncoder().encode(record))
        var state = LibraryState(); state.records = ["v": decoded]
        let index = LibraryIndex.build(state: state, visible: ["v"])
        XCTAssertTrue(index.search["v"]!.contains("生日快乐"))
        XCTAssertEqual(decoded.videoTitle, record.videoTitle)
        let suggestion = AISuggestion(tags: ["视频"], summary: "生日祝福", explanation: "来自转写", videoTitle: "桐桐 · 生日祝福")
        XCTAssertNoThrow(try suggestion.validated())
        let plan = AIPlan(tags: [], text: "生日快乐", person: "", trip: "", albumName: "祝福", explanation: "", unsupported: [])
        XCTAssertTrue(plan.matches(record, people: [], trips: []))
    }
    func testLightAndDarkTextRemainReadableOnCardsAndCanvas() {
        func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
            let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
            func linear(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            for fill in [Palette.accent, Palette.destructive] {
                let first = luminance(Palette.onAccent, style), second = luminance(fill, style)
                XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 4.5)
            }
            for text in [Palette.ink, Palette.secondary, Palette.accent] {
                for background in [Palette.surface, Palette.canvas] {
                    let first = luminance(text, style), second = luminance(background, style)
                    let contrast = (max(first, second) + 0.05) / (min(first, second) + 0.05)
                    XCTAssertGreaterThanOrEqual(contrast, 4.5, "Text contrast in \(style.rawValue)")
                }
            }
        }
    }
    func testLargeLibraryIndexPreparesCountsWithoutRepeatedViewSorting() {
        var state = LibraryState()
        let person = NamedPerson(name: "桐桐")
        state.people = [person]
        for i in 0..<12000 {
            var record = media("asset-\(i)", Double(i))
            record.tags = i % 2 == 0 ? [.screenshot, .chat] : [.portrait]
            if i % 3 == 0 { record.keywords = ["夜景"] }
            if i % 5 == 0 { record.people = [person.id] }
            state.records[record.id] = record
        }
        state.pending = ["asset-0"]
        let trip = Trip(name: "中秋长沙", members: ["asset-1", "asset-5"])
        state.trips = [trip]
        let index = LibraryIndex.build(state: state, visible: Set(state.records.keys).subtracting(["asset-2"]))
        XCTAssertEqual(index.records.count, 11999)
        XCTAssertEqual(index.active.count, 11998)
        XCTAssertEqual(index.pending.count, 1)
        XCTAssertEqual(index.byTag[.chat]?.count, 5998)
        XCTAssertEqual(index.byTrip[trip.id]?.count, 2)
        XCTAssertTrue(index.labels["asset-5"]?.contains("桐桐") == true)
        XCTAssertTrue(index.search["asset-5"]?.contains("中秋长沙") == true)
        XCTAssertEqual(index.records.first?.id, "asset-11999")
    }
    func testMetadataRefreshReusesAnalysisAndManualTags() {
        var record = media("a")
        record.analyzed = true; record.tags = [.chat]; record.text = "已识别文字"
        record.keywords = ["重要"]
        var state = LibraryState(); state.records = ["a": record]
        let merged = LibraryMetadata.merge([media("a")], into: state, fullAccess: true, retryUnavailable: false)
        XCTAssertTrue(merged.records["a"]!.analyzed)
        XCTAssertEqual(merged.records["a"]!.text, "已识别文字")
        XCTAssertEqual(merged.records["a"]!.customTags, ["重要"])
        XCTAssertTrue(ScanPolicy.candidates(Array(merged.records.values), screenshotsOnly: false).isEmpty)
        var edited = media("a"); edited.modified = Date()
        let changed = LibraryMetadata.merge([edited], into: state, fullAccess: true, retryUnavailable: false)
        XCTAssertFalse(changed.records["a"]!.analyzed)
        XCTAssertEqual(changed.records["a"]!.customTags, ["重要"])
    }
    func testLimitedPermissionRefreshDoesNotEraseHiddenRecords() {
        var state = LibraryState(); state.records = ["a": media("a"), "b": media("b")]
        let limited = LibraryMetadata.merge([media("a")], into: state, fullAccess: false, retryUnavailable: false)
        XCTAssertNotNil(limited.records["b"])
        XCTAssertEqual(LibraryIndex.build(state: limited, visible: ["a"]).records.map(\.id), ["a"])
    }
    func testScanIsBoundedAndDoesNotReanalyzeCompletedOrUnavailableItems() {
        var records = (0..<500).map { i -> MediaRecord in var record = media("\(i)"); record.isScreenshot = true; return record }
        records[0].analyzed = true; records[1].isVideo = true; records[2].unavailable = true
        records[3].isScreenshot = false
        let todo = ScanPolicy.candidates(records, screenshotsOnly: true)
        XCTAssertEqual(todo.count, 100)
        XCTAssertEqual(todo.first?.id, "4")
        XCTAssertEqual(ScanPolicy.candidates(records, screenshotsOnly: true, limit: 0).count, 0)
    }
    func testSimilarityComparisonBudgetStopsWork() {
        var a = media("a"), b = media("b")
        a.hash = 0xA55AA55AA55AA55A; b.hash = a.hash
        XCTAssertTrue(Similarity.pairs([a, b], comparisonLimit: 0).isEmpty)
        XCTAssertEqual(Similarity.pairs([a, b], comparisonLimit: 1), [["a", "b"]])
    }
    func testDiskDoesNotLetOlderSnapshotsOverwriteNewerEdits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = LibraryDisk(url: folder.appendingPathComponent("state.json"))
        _ = try await disk.load()
        var newer = LibraryState(); var record = media("a"); record.keywords = ["已修正"]
        newer.records["a"] = record
        try await disk.write(newer, revision: 2)
        try await disk.write(LibraryState(), revision: 1)
        let loaded = try await disk.load()
        XCTAssertEqual(loaded.records["a"]?.customTags, ["已修正"])
        try FileManager.default.removeItem(at: folder)
    }
    @MainActor
    func testPausePersistsCompletedItemsAndLateWorkerCannotEraseResumedRun() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("state.json")
        let blocked = expectation(description:"second item reached")
        let resumed = expectation(description:"resumed run finished")
        let gate = ScanTestGate()
        var calls = 0
        let store = LibraryStore(storageURL:url,images:{ _ in UIImage() },analyze:{ _,_ in
            calls += 1
            if calls == 2 { blocked.fulfill(); await gate.wait() }
            return AnalysisResult(tags:[.food],text:"saved",reasons:[],hash:nil,labels:["food"])
        })
        var initial = LibraryState()
        initial.records = ["a":media("a"),"b":media("b",1),"c":media("c",2)]
        store.seedForTesting(initial)
        store.scan(screenshotsOnly:false,limit:100)
        await fulfillment(of:[blocked],timeout:5)
        store.pause()
        XCTAssertFalse(store.scanning,"Pause must not await stalled Vision")
        let saved = await store.flushPendingSaves(); XCTAssertTrue(saved)
        let disk = LibraryDisk(url:url)
        let paused = try await disk.load()
        XCTAssertEqual(paused.records.values.filter(\.analyzed).count,1)
        store.scan(screenshotsOnly:false,limit:100) { done,_ in XCTAssertTrue(done); resumed.fulfill() }
        XCTAssertGreaterThan(store.progress,0,"Resume must display existing progress")
        await fulfillment(of:[resumed],timeout:5)
        gate.release()
        for _ in 0..<5 { await Task.yield() }
        let finalSave = await store.flushPendingSaves(); XCTAssertTrue(finalSave)
        let reopened = try await LibraryDisk(url:url).load()
        XCTAssertEqual(reopened.records.values.filter(\.analyzed).count,3)
        XCTAssertFalse(store.scanning)
    }
    @MainActor
    func testFailedSaveRetainsMemoryAndCorruptStorageDoesNotOpenAsEmptyLibrary() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let blockingFile = folder.appendingPathComponent("file")
        try Data([1]).write(to:blockingFile)
        let store = LibraryStore(storageURL:blockingFile.appendingPathComponent("state.json"))
        var initial = LibraryState(); var record = media("a"); record.analyzed = true
        initial.records["a"] = record; store.seedForTesting(initial)
        store.save(immediately:true)
        let saved = await store.flushPendingSaves(); XCTAssertFalse(saved)
        XCTAssertNotNil(store.saveError); XCTAssertTrue(store.state.records["a"]!.analyzed)
        let corrupt = folder.appendingPathComponent("corrupt.json")
        try Data("invalid json".utf8).write(to:corrupt)
        let reopened = LibraryStore(storageURL:corrupt)
        await reopened.start()
        XCTAssertFalse(reopened.loaded); XCTAssertNotNil(reopened.loadError)
        reopened.save(immediately:true)
        XCTAssertEqual(try Data(contentsOf:corrupt),Data("invalid json".utf8))
    }
    func testIncompleteFullAccessRefreshPreservesSavedAnalysisAndSelection() {
        var initial = LibraryState(); var a = media("a"), b = media("b")
        a.analyzed = true; b.analyzed = true; b.text = "keep"
        initial.records = ["a":a,"b":b]; initial.pending = ["a","b"]
        for snapshot in [[],[media("a")]] {
            let merged = LibraryMetadata.merge(snapshot,into:initial,fullAccess:true,retryUnavailable:false)
            XCTAssertEqual(merged.records["b"]?.text,"keep")
            XCTAssertEqual(merged.pending,["a","b"])
        }
        XCTAssertEqual(PendingSelection.valid(["a","b","missing"],pending:initial.pending,visible:["a"]),["a"])
        XCTAssertEqual(PendingSelection.valid(["b"],pending:initial.pending,visible:["a","b"]),["b"])
    }

    @MainActor
    func testDeletionCancellationRetainsQueueAndSuccessOnlyRemovesConfirmedSelectedIDs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var cancel = true, submitted: Set<String> = []
        let store = LibraryStore(storageURL:folder.appendingPathComponent("state.json"),delete:{ ids in
            submitted = ids
            if cancel { throw CancellationError() }
            return ["a"] // Simulate a second selected asset that cannot be deleted.
        })
        var initial = LibraryState()
        initial.records = ["a":media("a"),"b":media("b"),"c":media("c")]
        initial.pending = ["a","b","c"]; store.seedForTesting(initial)
        await store.deletePending(selected:["a","b","unknown"])
        XCTAssertEqual(submitted,["a","b"])
        XCTAssertEqual(store.state.pending,["a","b","c"])
        XCTAssertEqual(store.state.records.count,3)
        cancel = false
        await store.deletePending(selected:["a","b"])
        XCTAssertEqual(store.state.pending,["b","c"])
        XCTAssertNil(store.state.records["a"]); XCTAssertNotNil(store.state.records["b"])
        let reopened = try await LibraryDisk(url:folder.appendingPathComponent("state.json")).load()
        XCTAssertEqual(reopened.pending,["b","c"])
        store.restoreAllPending(ids:["b"])
        XCTAssertEqual(store.state.pending,["c"])
        XCTAssertNotNil(store.state.records["b"])
    }

    @MainActor
    func testConsecutiveReadFailuresStopWithoutErasingPreviouslyCompletedResults() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stopped = expectation(description:"failed reads checkpointed")
        let store = LibraryStore(storageURL:folder.appendingPathComponent("state.json"),images:{ _ in nil })
        var initial = LibraryState(); var done = media("done"); done.analyzed = true; done.text = "keep"
        initial.records["done"] = done
        for i in 0..<10 { initial.records["pending-\(i)"] = media("pending-\(i)",Double(i+1)) }
        store.seedForTesting(initial)
        store.scan(screenshotsOnly:false,limit:100) { success,count in
            XCTAssertFalse(success); XCTAssertEqual(count,3); stopped.fulfill()
        }
        await fulfillment(of:[stopped],timeout:5)
        XCTAssertFalse(store.scanning)
        XCTAssertEqual(store.state.records["done"]?.text,"keep")
        XCTAssertEqual(ScanPolicy.candidates(Array(store.state.records.values),screenshotsOnly:false).count,10)
        let reopened = try await LibraryDisk(url:folder.appendingPathComponent("state.json")).load()
        XCTAssertEqual(reopened.records.count,11); XCTAssertTrue(reopened.records["done"]!.analyzed)
    }

    private func media(_ id: String, _ seconds: TimeInterval = 0,
                       lat: Double? = nil, lon: Double? = nil) -> MediaRecord {
        MediaRecord(id: id, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            latitude: lat, longitude: lon, isVideo: false, isScreenshot: false, duration: 0)
    }

    func testScreenshotCanBeChatAndPaymentAndPortrait() {
        let result = CategoryRules.classify(text: "微信支付 支付成功 发送", screenshot: true,
            faces: 1, labels: [], isVideo: false).0
        XCTAssertTrue(result.isSuperset(of: [.screenshot, .documents, .chat, .portrait]))
        XCTAssertFalse(result.contains(.other))
    }
    func testUnknownStaysReviewable() {
        let result = CategoryRules.classify(text: "", screenshot: true, faces: 0, labels: [], isVideo: false).0
        XCTAssertEqual(result, [.screenshot, .other])
    }
    func testCallDoesNotBecomeVideoAsset() {
        let result = CategoryRules.classify(text: "视频通话 切换摄像头", screenshot: true, faces: 2, labels: [], isVideo: false).0
        XCTAssertTrue(result.contains(.videoCall))
        XCTAssertFalse(result.contains(.video))
    }
    func testManualCorrectionsOverrideAutomaticTagsAndRoundTrip() throws {
        var record = media("a")
        record.tags = [.portrait, .meme]
        record.removedTags = [.meme]
        record.addedTags = [.ticket]
        let decoded = try JSONDecoder().decode(MediaRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.effectiveTags, [.portrait, .documents])
    }
    func testStagingUndoAndDeleteDoNotLeaveDanglingReferences() throws {
        var state = LibraryState()
        state.records = ["a": media("a"), "b": media("b")]
        state.trips = [Trip(name: "长沙", members: ["a", "b"])]
        state.stage("a")
        state.stage("a")
        state.stage("missing")
        XCTAssertEqual(state.pending, ["a"])
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.pending, ["a"])
        state.undo()
        XCTAssertTrue(state.pending.isEmpty)
        state.stage("a")
        state.forget(["a"])
        XCTAssertEqual(state.trips[0].members, ["b"])
        XCTAssertNil(state.lastStaged)
        XCTAssertNil(state.records["a"])
    }
    func testTripsSeparateDistantLocationsAndMissingLocation() {
        let records = [media("a", 0, lat: 28.2, lon: 112.9),
            media("b", 100, lat: 28.2, lon: 112.9), media("c", 200, lat: 28.2, lon: 112.9),
            media("d", 300, lat: 39.9, lon: 116.4), media("no-location", 400)]
        let trips = TripBuilder.candidates(records)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].members, ["a", "b", "c"])
    }
    func testSimilarityFindsDifferentDateCandidatesWithoutDeleting() {
        var a = media("a")
        var b = media("b", 86400 * 100)
        var c = media("c")
        a.hash = 0xA55AA55AA55AA55A
        b.hash = a.hash! ^ 3
        c.hash = ~a.hash!
        XCTAssertEqual(Similarity.pairs([a, b, c]), [["a", "b"]])
    }

    func testAIRequestUsesOfficialHostAndExplicitImageParts() throws {
        let request = try DeepSeekClient.makeRequest(key: "dummy-test-key", model: "deepseek-flash",
            system: "JSON only", text: "分类这张图片", jpeg: Data([1, 2, 3]))
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dummy-test-key")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let textOnly = try DeepSeekClient.makeRequest(key: "dummy", model: "deepseek-flash", system: "JSON", text: "test")
        XCTAssertFalse(String(data: try XCTUnwrap(textOnly.httpBody), encoding: .utf8)!.contains("image_url"))
    }
    func testAIRejectsTruncatedAndEmptyOutput() throws {
        let truncated = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#.utf8)
        let blank = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"   "}}]}"#.utf8)
        XCTAssertThrowsError(try DeepSeekClient.decode(truncated, as: AIPlan.self))
        XCTAssertThrowsError(try DeepSeekClient.decode(blank, as: AIPlan.self))
        let invalid = AISuggestion(tags: ["直接删除"], summary: "x", explanation: "x")
        XCTAssertThrowsError(try invalid.validated())
    }
    func testAIValidResponseDecodesBeforeApproval() throws {
        let suggestion = AISuggestion(tags: ["支付记录"], summary: "付款记录", explanation: "支付成功文字")
        let content = String(data: try JSONEncoder().encode(suggestion), encoding: .utf8)!
        let data = try JSONSerialization.data(withJSONObject: ["choices": [
            ["finish_reason": "stop", "message": ["content": content]]]])
        let decoded = try DeepSeekClient.decode(data, as: AISuggestion.self).validated()
        XCTAssertEqual(decoded.tags, ["支付记录"])
        XCTAssertThrowsError(try DeepSeekClient.makeRequest(key: "dummy", model: "", system: "JSON", text: "test"))
        XCTAssertThrowsError(try DeepSeekClient.makeRequest(key: "dummy", model: "deepseek-flash", system: "JSON", text: "test", jpeg: Data(repeating: 0, count: 2_000_001)))
    }
    func testUnsupportedAIPlanCannotMatchAnything() {
        var record = media("a")
        record.tags = [.portrait]
        let plan = AIPlan(tags: ["人像"], text: "", person: "", trip: "", albumName: "测试",
            explanation: "", unsupported: ["排除条件"])
        XCTAssertFalse(plan.matches(record, people: [], trips: []))
        let empty = AIPlan(tags: [], text: "", person: "", trip: "", albumName: "测试", explanation: "", unsupported: [])
        XCTAssertFalse(empty.matches(record, people: [], trips: []))
    }
    func testAIPlanIntersectsTagsPersonAndTripLocally() {
        var record = media("a")
        record.tags = [.portrait]
        let person = NamedPerson(name: "桐桐")
        record.people = [person.id]
        let trip = Trip(name: "中秋 · 长沙", members: ["a"])
        let plan = AIPlan(tags: ["人像"], text: "", person: "桐桐", trip: "长沙", albumName: "长沙桐桐", explanation: "", unsupported: [])
        XCTAssertTrue(plan.matches(record, people: [person], trips: [trip]))
        XCTAssertFalse(plan.matches(record, people: [], trips: [trip]))
    }
    func testCustomTagsNormalizeAndSurviveStorage() throws {
        XCTAssertEqual(TagNames.normalized([" #夜景 ", "夜景", "Cat", "cat", "", "＃聚餐"]), ["夜景", "Cat", "聚餐"])
        var record = media("a")
        record.keywords = ["夜景", "聚餐"]
        let decoded = try JSONDecoder().decode(MediaRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.customTags, ["夜景", "聚餐"])
        XCTAssertEqual(media("unclassified").effectiveTags, [.other])
        let plan = AIPlan(tags: [], text: "", person: "", trip: "", albumName: "夜景", explanation: "", unsupported: [], keywords: ["夜景"])
        XCTAssertTrue(plan.matches(decoded, people: [], trips: []))
        XCTAssertFalse(plan.matches(media("b"), people: [], trips: []))
    }
}

@MainActor
private final class StubScanDriver: ScanDriver {
    var scanning = false
    var refreshing = false
    var busy = false
    var loaded = true
    var permitted = true
    var state = LibraryState()
    var status = ""
    var scanCalls = 0
    private var completion: ((Bool, Int) -> Void)?
    var records: [MediaRecord] { Array(state.records.values) }
    init() {
        let record = MediaRecord(id: "test-image", date: Date(), isVideo: false, isScreenshot: true, duration: 0)
        state.records[record.id] = record
    }
    func scan(screenshotsOnly: Bool, limit: Int, onFinish: ((Bool, Int) -> Void)?) {
        scanCalls += 1; scanning = true; status = "开始整理"; completion = onFinish
    }
    func finish() {
        scanning = false
        for id in state.records.keys { state.records[id]?.analyzed = true }
        let callback = completion; completion = nil; callback?(true, 0)
    }
    func pause() { scanning = false }
    func save(immediately: Bool) { }
    func prepareForBackgroundScan() async { }
}

@MainActor
private final class ScanTestGate {
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
