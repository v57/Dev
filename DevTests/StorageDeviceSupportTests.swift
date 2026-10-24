import Foundation
import Testing

@testable import Dev

/// Smart Scan leaves the Device Support of the OS a recent device runs.
@Suite struct StorageDeviceSupportTests {
  private typealias Paired = StorageDiscovery.PairedDevices

  private let paired = Paired(devices: [
    .init(name: "v57", productType: "iPhone17,2", build: "24A446", lastConnection: Date()),
    .init(name: "iPad Pro", productType: "iPad13,11", build: "23G90", lastConnection: nil),
  ])

  @Test func aFolderIsUsedByTheDeviceOfItsModelAndBuild() {
    #expect(paired.users(ofDeviceSupport: "iPhone17,2 27.0.1 (24A446)")?.hasPrefix("v57 runs it · connected") == true)
    #expect(paired.users(ofDeviceSupport: "iPad13,11 26.6.2 (23G90)") == "iPad Pro runs it")
    // Another model on the same build, or an older build, is not in use.
    #expect(paired.users(ofDeviceSupport: "iPhone19,2 27.0.1 (24A446)") == nil)
    #expect(paired.users(ofDeviceSupport: "iPhone17,2 26.6 (23G80)") == nil)
  }

  @Test func anOldStyleFolderMatchesByBuildAlone() {
    #expect(paired.users(ofDeviceSupport: "26.6.2 (23G90) arm64e") == "iPad Pro runs it")
    #expect(paired.users(ofDeviceSupport: "no build here") == nil)
  }

  @Test func smartScanLeavesAFolderInUse() {
    var item = StorageItem(
      id: "/ds", category: .xcode, group: "Device Support", title: "ds", paths: ["/ds"],
      safety: .cache, cleanup: .trash)
    #expect(item.isRecommended)
    item.inUse = "v57 runs it"
    #expect(!item.isRecommended)
  }

  /// The real devicectl: every device it returns connected within the window.
  @Test func recentDevicesConnectedLately() {
    let since = Date().addingTimeInterval(-90 * 86_400)
    for device in Paired.recent().devices {
      #expect((device.lastConnection ?? .distantFuture) > since)
      #expect(!device.build.isEmpty)
    }
  }
}
