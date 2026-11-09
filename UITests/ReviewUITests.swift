import XCTest
import CoreGraphics

final class ReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 120 }
    @MainActor
    func testHomePortraitReviewUsesTheSameControlsAndGestures() { checkRoute(tab:"整理",entry:"collection.tag.人像",prefix:false) }
    @MainActor
    func testPeopleAllReviewUsesTheSameControlsAndGestures() { checkRoute(tab:"人物",entry:"collection.people.all",prefix:false) }
    @MainActor
    func testNamedPersonReviewUsesTheSameControlsAndGestures() { checkRoute(tab:"人物",entry:"collection.person.",prefix:true) }
    @MainActor
    func testTripReviewUsesTheSameControlsAndGestures() { checkRoute(tab:"出游",entry:"collection.trip.",prefix:true) }

    @MainActor
    func testPendingSelectionSurvivesTabChangesAndRestoreOnlyAffectsSelectedItems() {
        let app = XCUIApplication()
        app.launchEnvironment["SHIGUANG_DESIGN_PREVIEW"] = "1"
        app.launchEnvironment["SHIGUANG_PREVIEW_LANGUAGE"] = "zh-Hans"
        app.launch()
        app.tabBars.buttons["待删"].tap()
        let delete = app.buttons["pending.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout:10)); XCTAssertTrue(delete.isHittable)
        XCTAssertFalse(delete.isEnabled)
        let selections = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","pending.select."))
        XCTAssertGreaterThan(selections.count,1)
        let before = selections.count
        selections.element(boundBy:0).tap()
        XCTAssertEqual(app.buttons["pending.delete"].label,"删除所选 1 项")
        XCTAssertTrue(delete.isEnabled); XCTAssertTrue(delete.isHittable)
        app.tabBars.buttons["整理"].tap(); app.tabBars.buttons["待删"].tap()
        XCTAssertEqual(app.buttons["pending.delete"].label,"删除所选 1 项")
        app.buttons["恢复所选 1 项"].tap()
        let restored = NSPredicate { _,_ in selections.count == before-1 }
        expectation(for:restored,evaluatedWith:app); waitForExpectations(timeout:8)
        XCTAssertFalse(app.buttons["pending.delete"].isEnabled)
        app.terminate()
    }

    @MainActor
    func testEveryHomeCategoryPhotoOpensTheSameReviewAtTheTappedPosition() {
        executionTimeAllowance = 600
        let app = XCUIApplication()
        app.launchEnvironment["SHIGUANG_DESIGN_PREVIEW"] = "1"
        app.launchEnvironment["SHIGUANG_PREVIEW_LANGUAGE"] = "zh-Hans"
        app.launch()
        let categories = ["人像","城市风光","自然风光","截图","美食","聊天记录","视频通话","商品购物","票据","表情与梗图","视频","待确认"]
        for name in categories {
            let link = app.descendants(matching:.any).matching(identifier:"collection.tag."+name).firstMatch
            for _ in 0..<8 { if link.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(link.isHittable,"Missing category: "+name); link.tap()
            let tiles = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","media.open."))
            XCTAssertTrue(tiles.element(boundBy:1).waitForExistence(timeout:8)); tiles.element(boundBy:1).tap()
            let counter = app.staticTexts["review.counter"]
            XCTAssertTrue(counter.waitForExistence(timeout:8)); assertPosition(2,counter:counter)
            checkControls(app)
            drag(app,dx:-0.6,dy:0); assertPosition(3,counter:counter)
            drag(app,dx:0.6,dy:0); assertPosition(2,counter:counter)
            app.buttons["review.done"].tap()
            app.navigationBars.buttons.element(boundBy:0).tap()
            // Return to the top so each category starts from the same Home state.
            for _ in 0..<5 { app.swipeDown() }
        }
        app.terminate()
    }

    @MainActor
    func testSystemPhotoLibraryLoadsClearImageAndCancellationKeepsSelectedPendingPhoto() {
        executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","-appLanguage","zh-Hans","-onboardingComplete","YES","-onboardingInProgress","NO"]
        app.launch()
        let all = app.buttons["collection.all"]
        XCTAssertTrue(all.waitForExistence(timeout:25)); all.tap()
        let photos = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","media.open."))
        XCTAssertTrue(photos.element(boundBy:0).waitForExistence(timeout:15)); photos.element(boundBy:0).tap()
        let photo = app.descendants(matching:.any).matching(identifier:"review.photo").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout:15))
        expectation(for:NSPredicate(format:"value == %@","清晰照片已就绪"),evaluatedWith:photo)
        waitForExpectations(timeout:20)
        drag(app,dx:0,dy:-0.6)
        app.buttons["review.done"].tap()
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.tabBars.buttons["待删"].tap()
        let choices = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","pending.select."))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout:12)); choices.firstMatch.tap()
        let delete = app.buttons["pending.delete"]
        XCTAssertTrue(delete.isEnabled); XCTAssertTrue(delete.isHittable); delete.tap()
        let springboard = XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let systemAlert = springboard.alerts.firstMatch
        let alert = systemAlert.waitForExistence(timeout:6) ? systemAlert : app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout:9),"Expected actual PhotoKit deletion confirmation")
        let cancel = alert.buttons.matching(NSPredicate(format:"label IN %@",["Don’t Allow","Don't Allow","不允许","Cancel","取消"])).firstMatch
        XCTAssertTrue(cancel.exists); cancel.tap()
        if app.alerts.firstMatch.waitForExistence(timeout:5) { app.alerts.firstMatch.buttons.element(boundBy:0).tap() }
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["pending.delete"].label,"删除所选 1 项")
        app.buttons["恢复所选 1 项"].tap()
        app.terminate()
    }

    @MainActor
    private func checkRoute(tab: String, entry: String, prefix: Bool) {
        let app = XCUIApplication()
        app.launchEnvironment["SHIGUANG_DESIGN_PREVIEW"] = "1"
        app.launchEnvironment["SHIGUANG_PREVIEW_LANGUAGE"] = "zh-Hans"
        app.launchEnvironment["SHIGUANG_PREVIEW_TAB"] = "0"
        app.launch()
        let tabButton = app.tabBars.buttons[tab]
        XCTAssertTrue(tabButton.waitForExistence(timeout:15)); tabButton.tap()
        let elements = app.descendants(matching:.any)
        let link = prefix ? elements.matching(NSPredicate(format:"identifier BEGINSWITH %@",entry)).firstMatch : elements.matching(identifier:entry).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout:10)); link.tap()
        let start = app.buttons["collection.review"]
        XCTAssertTrue(start.waitForExistence(timeout:10)); start.tap()
        let counter = app.staticTexts["review.counter"]
        XCTAssertTrue(counter.waitForExistence(timeout:10))
        assertPosition(1,counter:counter)
        checkControls(app)
        // Every route begins with a video. Its clear-preview button must remain.
        app.buttons["review.clear"].tap()
        let close = app.buttons["review.preview.close"]
        XCTAssertTrue(close.waitForExistence(timeout:10)); close.tap()
        assertPosition(1,counter:counter)
        drag(app,dx:-0.6,dy:0); assertPosition(2,counter:counter)
        checkControls(app) // Next page is a still image: same buttons/positions.
        app.buttons["review.clear"].tap()
        XCTAssertTrue(close.waitForExistence(timeout:10)); close.tap()
        assertPosition(2,counter:counter)
        drag(app,dx:0.6,dy:0); assertPosition(1,counter:counter)
        for _ in 0..<3 {
            drag(app,dx:-0.6,dy:0); assertPosition(2,counter:counter)
            drag(app,dx:0.6,dy:0); assertPosition(1,counter:counter)
        }
        drag(app,dx:0,dy:-0.6); assertPosition(2,counter:counter)
        app.buttons["review.undo"].tap(); assertPosition(1,counter:counter)
        let attachment = XCTAttachment(screenshot:app.screenshot())
        attachment.name = entry; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["review.done"].tap()
        XCTAssertTrue(start.waitForExistence(timeout:10))
        app.terminate()
    }
    @MainActor
    private func checkControls(_ app: XCUIApplication) {
        let clear = app.buttons["review.clear"], next = app.buttons["review.next"], stage = app.buttons["review.stage"]
        XCTAssertTrue(clear.isHittable); XCTAssertTrue(next.isHittable); XCTAssertTrue(stage.isHittable)
        XCTAssertLessThan(clear.frame.midX,next.frame.midX)
        XCTAssertLessThan(next.frame.midX,stage.frame.midX)
        XCTAssertEqual(clear.frame.midY,next.frame.midY,accuracy:2)
        XCTAssertEqual(next.frame.midY,stage.frame.midY,accuracy:2)
        XCTAssertLessThan(stage.frame.maxY,app.frame.maxY-15)
    }
    @MainActor
    private func assertPosition(_ position: Int,counter: XCUIElement) {
        let predicate = NSPredicate(format:"label BEGINSWITH %@","\(position) /")
        expectation(for:predicate,evaluatedWith:counter)
        waitForExpectations(timeout:8)
    }
    @MainActor
    private func drag(_ app: XCUIApplication,dx: CGFloat,dy: CGFloat) {
        let photo = app.descendants(matching:.any).matching(identifier:"review.photo").firstMatch
        XCTAssertTrue(photo.isHittable)
        let from = photo.coordinate(withNormalizedOffset:CGVector(dx:dx>0 ? 0.2 : 0.8,dy:dy<0 ? 0.8 : 0.5))
        let to = photo.coordinate(withNormalizedOffset:CGVector(dx:dx>0 ? 0.8 : (dx<0 ? 0.2 : 0.8),dy:dy<0 ? 0.2 : 0.5))
        from.press(forDuration:0.05,thenDragTo:to)
    }
}
