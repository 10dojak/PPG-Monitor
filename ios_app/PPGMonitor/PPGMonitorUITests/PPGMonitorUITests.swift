//
//  PPGMonitorUITests.swift
//  PPGMonitorUITests
//
//  Created by Phoebe Lo on 8/18/26.
//

import XCTest

final class PPGMonitorUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testRecordingFlowScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        func snap(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        snap("01-participant-entry-empty")

        let field = app.textFields["Participant ID"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("phoebeTest")

        snap("02-participant-entry-filled")

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 5))

        snap("03-recording-screen-ready")

        app.buttons["Hide Metrics"].tap()
        sleep(1)
        snap("03b-metrics-hidden")

        app.buttons["Show Metrics"].tap()
        sleep(1)
        snap("03c-metrics-shown-again")

        app.buttons["Start Recording"].tap()
        sleep(3)

        snap("04-recording-in-progress")

        app.buttons["Stop & Save"].tap()
        sleep(1)

        snap("05-recording-stopped")

        app.staticTexts["All 24 Channels"].tap()
        sleep(2)
        snap("06-heatmap-tab")

        app.staticTexts["Acceleration"].tap()
        sleep(2)
        snap("07-accel-tab")

        app.staticTexts["Waveforms"].tap()
        sleep(1)
        snap("08-waveform-chips-fixed")
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
