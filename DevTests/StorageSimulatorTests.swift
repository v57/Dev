import Foundation
import Testing

@testable import Dev

/// A simulator runtime and the simulators on it are one uninstall.
@MainActor @Suite struct StorageSimulatorTests {
  private func item(
    _ id: String, parent: String? = nil, cleanup: StorageCleanup = .command(
      executable: "/usr/bin/true", arguments: [], verb: "Erase content"),
    withParent: StorageCleanup? = nil, bytes: Int64 = 10
  ) -> StorageItem {
    var item = StorageItem(
      id: id, category: .xcode, group: "Simulators", title: id, paths: [], safety: .data,
      cleanup: cleanup, bytes: bytes, reportedSize: true)
    item.parent = parent
    item.cleanupWithParent = parent == nil ? nil
      : withParent ?? .command(executable: "/usr/bin/true", arguments: [], verb: "Delete")
    return item
  }

  private var family: [StorageItem] {
    [item("runtime:a", cleanup: .command(executable: "/usr/bin/true", arguments: [], verb: "Delete"), bytes: 100),
     item("sim:1", parent: "runtime:a"), item("sim:2", parent: "runtime:a"), item("sim:3")]
  }

  @Test func pickingARuntimePicksItsSimulatorsToDelete() {
    let store = StorageStore(items: family)
    store.setSelected(true, [family[0]])
    #expect(store.selection == ["runtime:a", "sim:1", "sim:2"])
    let verbs = Dictionary(uniqueKeysWithValues: store.selectedItems.map { ($0.id, $0.cleanup.verb) })
    #expect(verbs == ["runtime:a": "Delete", "sim:1": "Delete", "sim:2": "Delete"])
    #expect(store.selectedBytes == 120)
  }

  @Test func keepingOneSimulatorKeepsTheRuntimeAndTheRest() {
    let store = StorageStore(items: family)
    store.setSelected(true, [family[0]])
    store.setSelected(false, [family[1]])
    #expect(store.selection.isEmpty)
  }

  @Test func aSimulatorAloneIsErasedAndUnpickedAlone() {
    let store = StorageStore(items: family)
    store.setSelected(true, [family[1], family[2]])
    #expect(store.selectedItems.allSatisfy { $0.cleanup.verb == "Erase content" })
    store.setSelected(false, [family[1]])
    #expect(store.selection == ["sim:2"])
  }

  @Test func aRuntimeStaysWhenOneOfItsSimulatorsCannotBeDeleted() {
    let failing = StorageCleanup.command(executable: "/usr/bin/false", arguments: [], verb: "Delete")
    // The runtime comes first, as it may in a scan: simulators still go before it.
    let items = [family[0], item("sim:1", parent: "runtime:a", cleanup: failing), family[2]]
    let report = StorageCleaner.clean(items, deleteImmediately: false)
    #expect(report.cleanedIDs == ["sim:2"])
    #expect(Set(report.failures.map(\.title)) == ["sim:1", "runtime:a"])
  }

  /// The real simctl lists: every simulator on a runtime that is the only
  /// build of its version is listed under it, in one Simulators group.
  @Test func discoveryNestsSimulatorsUnderTheirRuntime() throws {
    var discovery = StorageDiscovery()
    discovery.addSwift()
    let simulators = discovery.items.filter { $0.category == .xcode && $0.group == "Simulators" }
    let runtimes = Set(simulators.filter { $0.id.hasPrefix("runtime:") }.map(\.id))
    try #require(!runtimes.isEmpty, "no simulator runtime installed")
    #expect(!discovery.items.contains { $0.group == "Simulator Runtimes" })
    for simulator in simulators where simulator.parent != nil {
      #expect(runtimes.contains(simulator.parent ?? ""))
      #expect(simulator.cleanupWithParent?.verb == "Delete")
    }
    #expect(simulators.contains { $0.parent != nil })
  }
}
