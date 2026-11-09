import XCTest

final class ReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testHomePortraitReviewUsesTheSameControlsAndGestures() { checkRoute(tab:"整理",entry:"collection.tag.人像",prefix:false) }
    func testPeopleAllReviewUsesTheSameControlsAndGestures() { checkRoute(tab:"人物",entry:"collection.people.all",prefix:false) }
    func testNamedPersonReviewUsesTheSameControlsAndGestures() { checkRoute(tab:"人物",entry:"collection.person.",prefix:true) }
    func testTripReviewUsesTheSameControlsAndGestures() { checkRoute(tab:"出游",entry:"collection.trip.",prefix:true) }

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
        drag(app,dx:0.6,dy:0); assertPosition(1,counter:counter)
        drag(app,dx:0,dy:-0.6); assertPosition(2,counter:counter)
        app.buttons["review.undo"].tap(); assertPosition(1,counter:counter)
        let attachment = XCTAttachment(screenshot:app.screenshot())
        attachment.name = entry; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["review.done"].tap()
        XCTAssertTrue(start.waitForExistence(timeout:10))
        app.terminate()
    }
    private func checkControls(_ app: XCUIApplication) {
        let clear = app.buttons["review.clear"], next = app.buttons["review.next"], stage = app.buttons["review.stage"]
        XCTAssertTrue(clear.isHittable); XCTAssertTrue(next.isHittable); XCTAssertTrue(stage.isHittable)
        XCTAssertLessThan(clear.frame.midX,next.frame.midX)
        XCTAssertLessThan(next.frame.midX,stage.frame.midX)
        XCTAssertEqual(clear.frame.midY,next.frame.midY,accuracy:2)
        XCTAssertEqual(next.frame.midY,stage.frame.midY,accuracy:2)
        XCTAssertLessThan(stage.frame.maxY,app.frame.maxY-15)
    }
    private func assertPosition(_ position: Int,counter: XCUIElement) {
        let predicate = NSPredicate(format:"label BEGINSWITH %@","\(position) /")
        expectation(for:predicate,evaluatedWith:counter)
        waitForExpectations(timeout:8)
    }
    private func drag(_ app: XCUIApplication,dx: CGFloat,dy: CGFloat) {
        let photo = app.descendants(matching:.any).matching(identifier:"review.photo").firstMatch
        XCTAssertTrue(photo.isHittable)
        let from = photo.coordinate(withNormalizedOffset:CGVector(dx:dx>0 ? 0.2 : 0.8,dy:dy<0 ? 0.8 : 0.5))
        let to = photo.coordinate(withNormalizedOffset:CGVector(dx:dx>0 ? 0.8 : (dx<0 ? 0.2 : 0.8),dy:dy<0 ? 0.2 : 0.5))
        from.press(forDuration:0.05,thenDragTo:to)
    }
}
