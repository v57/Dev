import DevScreenshots
import DevScreenshotsCapture
import Foundation
import Testing

@testable import DevApp

struct ScreenshotUploadTests {
  private func shot(_ index: Int, on device: String, platform: ScreenshotConfig.Platform) -> ScreenshotLibrary.Shot {
    let name = String(format: "%02d", index)
    let url = URL(fileURLWithPath: "/p/.build/screenshots/framed/\(device)/en-US/\(name).png")
    return ScreenshotLibrary.Shot(
      name: name, locale: "en-US", platform: platform, device: device, appearance: .light, file: "\(name).png",
      captured: url, final: url, pixelWidth: 1320, pixelHeight: 2868, framedWidth: 1320, framedHeight: 2868,
      taken: .init(build: 1, commit: nil, dirty: false, date: .now, fingerprint: ""), state: .current)
  }

  @Test func appStoreConnectGetsTheFirstTenOfEachDisplayType() {
    let phone = "iPhone 18 Pro Max", pad = "iPad Pro 13-inch (M5)"
    let shots = (1...11).map { shot($0, on: phone, platform: .iphone) } + (1...3).map { shot($0, on: pad, platform: .ipad) }
    let config = ScreenshotConfig(ios: .init(devices: [phone, pad]))
    let library = ScreenshotLibrary(
      root: URL(fileURLWithPath: "/p"), config: config, configError: nil, status: nil, locales: ["en-US"],
      targets: [phone, pad], shots: shots)
    let files = library.uploadFiles(platform: "ios")["en-US"] ?? []
    #expect(files.count == 13)
    #expect(files.filter { $0.path.contains(phone) }.map(\.lastPathComponent).last == "10.png")
    #expect(files.filter { $0.path.contains(pad) }.count == 3)
  }
}
