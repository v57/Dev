//
//  ReleaseSettingsTests.swift
//  DevUITests
//

import XCTest

/// Release Settings' App Store Connect key setup on the demo project, opened
/// without saving a release.env. Not part of the website's screenshots.
final class ReleaseSettingsTests: XCTestCase {
  func testAppStoreConnectKeySection() {
    let app = XCUIApplication()
    app.launchArguments += ["-DevScreenshotMode", "-ApplePersistenceIgnoreState", "YES",
                            "-DevTab", "workflows", "-DevOpen", "releaseSettings"]
    app.launchEnvironment["DEV_DEMO_PROJECTS"] = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Tools/screenshots/DemoApp").path
    app.launch()
    defer { app.terminate() }

    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 20), "Release Settings did not open")
    let check = sheet.buttons["Check with Apple"].firstMatch
    sheet.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -2000)
    XCTAssertTrue(check.waitForExistence(timeout: 5))
    XCTAssertTrue(sheet.buttons["Choose…"].firstMatch.exists)
    XCTAssertTrue(sheet.buttons["Use for Notarization"].firstMatch.exists)
    // Without a key file and ID there is nothing to check yet.
    XCTAssertFalse(check.isEnabled)

    let attachment = XCTAttachment(screenshot: sheet.screenshot())
    attachment.name = "release-settings"
    attachment.lifetime = .keepAlways
    add(attachment)
    sheet.buttons["Cancel"].firstMatch.click()
  }
}
