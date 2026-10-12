//
//  ScreenshotTests.swift
//  DevUITests
//

import XCTest

/// The website's screenshots: Dev with a demo project (`Tools/screenshots/DemoApp`)
/// and an in-memory store, so no real project of the user's is ever in a picture.
/// Run through `Tools/release/release.sh screenshots`; each picture is a test
/// attachment the script exports as a PNG.
final class ScreenshotTests: XCTestCase {
  private var app: XCUIApplication!

  /// `Tools/screenshots/DemoApp`, found from this file's place in the repo.
  private var demoProject: String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Tools/screenshots/DemoApp").path
  }

  override func setUp() {
    continueAfterFailure = true
    app = XCUIApplication()
    app.launchArguments += ["-DevScreenshotMode", "-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["DEV_DEMO_PROJECTS"] = demoProject
    app.launch()
  }

  override func tearDown() {
    app.terminate()
  }

  func testScreenshots() {
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))

    let project = window.staticTexts["DemoApp"].firstMatch
    XCTAssertTrue(project.waitForExistence(timeout: 10), "the demo project did not appear")

    // A project opens on its Overview.
    snapshot("01-overview")

    pick("Localization")
    _ = window.staticTexts["Save changes"].firstMatch.waitForExistence(timeout: 15)
    snapshot("02-localization")

    pick("App Icon")
    snapshot("03-app-icon")

    pick("Screenshots")
    snapshot("04-screenshots")

    pick("Workflows")
    snapshot("05-workflows")

    let storage = window.descendants(matching: .any)["sidebar.storage"].firstMatch
    if storage.waitForExistence(timeout: 5) {
      storage.click()
      _ = window.staticTexts["Smart Scan"].firstMatch.waitForExistence(timeout: 5)
      Thread.sleep(forTimeInterval: 1)  // the project's tabs leave the toolbar
      snapshot("06-storage")
    }

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["Translation"].firstMatch
    if settings.waitForExistence(timeout: 5) {
      snapshot("07-settings", of: settings)
      app.typeKey("w", modifierFlags: .command)
    }
  }

  /// The toolbar's tool picker, whichever control macOS exposes it as.
  private func pick(_ tool: String) {
    for candidate in [app.radioButtons[tool], app.buttons[tool], app.segmentedControls.buttons[tool]]
    where candidate.firstMatch.exists {
      candidate.firstMatch.click()
      Thread.sleep(forTimeInterval: 1)  // the toolbar crossfades to the tool's buttons
      return
    }
    XCTFail("no tool picker entry \(tool)")
  }

  private func snapshot(_ name: String, of element: XCUIElement? = nil) {
    let shot = (element ?? app.windows.firstMatch).screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
