import XCTest

final class FileExplorerSidebarUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTitlebarButtonTogglesFileExplorerSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()

        let toggleButton = app.buttons["titlebarControl.toggleFileExplorer"]
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 6.0))

        let sidebar = app.descendants(matching: .any).matching(identifier: "FileExplorerSidebar").firstMatch
        XCTAssertFalse(sidebar.exists)

        toggleButton.click()

        XCTAssertTrue(sidebar.waitForExistence(timeout: 6.0))
        XCTAssertTrue(waitForElementHittable(sidebar, timeout: 6.0), "Expected file explorer sidebar to become hittable")

        toggleButton.click()

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: sidebar
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 6.0), .completed)
    }

    func testFileExplorerSidebarResizerTracksDrag() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()

        let toggleButton = app.buttons["titlebarControl.toggleFileExplorer"]
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 6.0))
        toggleButton.click()

        let resizer = app.descendants(matching: .any).matching(identifier: "FileExplorerSidebarResizer").firstMatch
        XCTAssertTrue(resizer.waitForExistence(timeout: 6.0))
        XCTAssertTrue(waitForElementHittable(resizer, timeout: 6.0), "Expected file explorer resizer to become hittable")

        let initialX = resizer.frame.minX

        let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let expandLeft = start.withOffset(CGVector(dx: -80, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: expandLeft)

        let expandedX = resizer.frame.minX
        let leftDelta = expandedX - initialX
        XCTAssertLessThanOrEqual(leftDelta, -40, "Expected dragging left to widen the file explorer")
        XCTAssertGreaterThanOrEqual(leftDelta, -82, "Resizer moved farther left than requested")

        let startBack = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let collapseRight = startBack.withOffset(CGVector(dx: 120, dy: 0))
        startBack.press(forDuration: 0.1, thenDragTo: collapseRight)

        let collapsedX = resizer.frame.minX
        let rightDelta = collapsedX - expandedX
        XCTAssertGreaterThanOrEqual(rightDelta, 40, "Expected dragging right to narrow the file explorer")
        XCTAssertLessThanOrEqual(rightDelta, 122, "Resizer moved farther right than requested")
    }

    private func waitForElementHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard element.exists, element.isHittable else { return false }
                let frame = element.frame
                return frame.width > 1 && frame.height > 1
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
