import Foundation
import Testing
import VaultKit

@testable import DevApp

/// Two checkouts of one project on one store: two devices that have already synced their vaults.
struct StoreVaultMirrorTests {
  private let keys = MemoryKeyProvider()
  private let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vault-mirror-\(UUID().uuidString)", isDirectory: true)

  private func store() throws -> VaultStore {
    try VaultStore(directory: temp.appendingPathComponent("vault"), keys: keys, deviceID: "mac", notifier: nil)
  }

  private func device(_ name: String, _ store: VaultStore, project: String = "P1") throws -> StoreVaultMirror {
    let root = temp.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return StoreVaultMirror(texts: StoreTexts(root: root), store: store, project: project)
  }

  private func file(_ mirror: StoreVaultMirror, _ path: String) -> String? {
    try? String(contentsOf: mirror.texts.privateFolder.appendingPathComponent(path), encoding: .utf8)
  }

  private let testers = StoreAddress(field: .testers, version: "1.0")
  private let testersPath = "en-US/versions/1.0/testers.txt"
  private let notes = StoreAddress(field: .reviewNotes)
  private let notesPath = "en-US/review-notes.txt"

  @Test func aDraftReachesTheOtherDeviceBehindTheIgnoreRule() throws {
    let store = try store()
    let mac = try device("mac", store)
    let other = try device("other", store)
    try mac.texts.write("Try this", at: testers)

    #expect(try mac.reconcile().sent == 1)
    let record = try #require(try store.records(StoreTextRecord.self).first)
    #expect(record.text == "Try this\n")
    #expect(record.path == testersPath)
    #expect(!record.id.contains("testers"))

    #expect(try other.reconcile().written == 1)
    #expect(other.texts.entry(testers)?.text == "Try this")
    #expect(other.texts.entry(testers)?.isPrivate == true)
    let ignore = try String(contentsOf: other.texts.folder.appendingPathComponent(".gitignore"), encoding: .utf8)
    #expect(ignore.contains("/private/"))

    #expect(try mac.reconcile() == .init())
    #expect(try other.reconcile() == .init())
  }

  @Test func theStateFileStaysOutOfTheVaultAndTheCounts() throws {
    let store = try store()
    let mac = try device("mac", store)
    try mac.texts.write("Try this", at: testers)
    _ = try mac.reconcile()
    #expect(file(mac, StoreVaultMirror.stateFile) != nil)
    #expect(mac.texts.privateFileCount() == 1)
    #expect(try store.records(StoreTextRecord.self).count == 1)
  }

  @Test func anEditOnOneSideFollowsOnTheOther() throws {
    let store = try store()
    let mac = try device("mac", store)
    let other = try device("other", store)
    try mac.texts.write("First", at: notes)
    _ = try mac.reconcile()
    _ = try other.reconcile()

    try other.texts.write("Second", at: notes)
    #expect(try other.reconcile().sent == 1)
    #expect(try mac.reconcile().written == 1)
    #expect(mac.texts.entry(notes)?.text == "Second")
  }

  @Test func editsOnBothSidesMergeAndAClashKeepsBoth() throws {
    let store = try store()
    let mac = try device("mac", store)
    let other = try device("other", store)
    let base = "one\ntwo\nthree\nfour\nfive"
    try mac.texts.write(base, at: notes)
    _ = try mac.reconcile()
    _ = try other.reconcile()

    try mac.texts.write("ONE\ntwo\nthree\nfour\nfive", at: notes)
    try other.texts.write("one\ntwo\nthree\nfour\nFIVE", at: notes)
    _ = try mac.reconcile()
    let clean = try other.reconcile()
    #expect(clean.merged == 1)
    #expect(clean.conflicts == 0)
    #expect(other.texts.entry(notes)?.text == "ONE\ntwo\nthree\nfour\nFIVE")
    _ = try mac.reconcile()
    #expect(mac.texts.entry(notes)?.text == "ONE\ntwo\nthree\nfour\nFIVE")

    try mac.texts.write("mac's\ntwo\nthree\nfour\nFIVE", at: notes)
    try other.texts.write("other's\ntwo\nthree\nfour\nFIVE", at: notes)
    _ = try mac.reconcile()
    #expect(try other.reconcile().conflicts == 1)
    let both = try #require(other.texts.entry(notes)?.text)
    #expect(both.contains("mac's"))
    #expect(both.contains("other's"))
  }

  @Test func goingReadyLeavesTheVaultAndTheOtherDevicesPrivateFolder() throws {
    let store = try store()
    let mac = try device("mac", store)
    let other = try device("other", store)
    let name = StoreAddress(field: .name)
    try mac.texts.write("Dev", at: name)
    _ = try mac.reconcile()
    _ = try other.reconcile()

    try mac.texts.setReady(true, field: .name)
    #expect(try mac.reconcile().removedRecords == 1)
    #expect(try store.records(StoreTextRecord.self).isEmpty)
    #expect(try other.reconcile().removedFiles == 1)
    #expect(other.texts.entry(name) == nil)
  }

  @Test func anEditBeatsADelete() throws {
    let store = try store()
    let mac = try device("mac", store)
    let other = try device("other", store)
    try mac.texts.write("First", at: notes)
    _ = try mac.reconcile()
    _ = try other.reconcile()

    try mac.texts.write("", at: notes)
    _ = try mac.reconcile()
    try other.texts.write("Changed", at: notes)
    #expect(try other.reconcile().sent == 1)
    #expect(try mac.reconcile().written == 1)
    #expect(mac.texts.entry(notes)?.text == "Changed")
  }

  @Test func aWipedVaultGetsItsTextsBackInsteadOfEmptyingTheFolder() throws {
    let store = try store()
    let mac = try device("mac", store)
    try mac.texts.write("Only copy", at: notes)
    _ = try mac.reconcile()
    try store.deleteAll()

    #expect(try mac.reconcile().sent == 1)
    #expect(mac.texts.entry(notes)?.text == "Only copy")
    #expect(try store.records(StoreTextRecord.self).count == 1)
  }

  @Test func aFreshCheckoutFetchesInsteadOfDeleting() throws {
    let store = try store()
    let mac = try device("mac", store)
    try mac.texts.write("Only copy", at: notes)
    _ = try mac.reconcile()
    try FileManager.default.removeItem(at: mac.texts.privateFolder)

    #expect(try mac.reconcile().written == 1)
    #expect(mac.texts.entry(notes)?.text == "Only copy")
  }

  @Test func aRecordCantWriteOutsideTheFolder() throws {
    let store = try store()
    let mac = try device("mac", store)
    for path in ["../../escaped.txt", "/tmp/escaped.txt", "en-US/../../escaped.txt", ".hidden.txt", "en-US/.hidden.txt", "script.sh", ""] {
      #expect(!StoreVaultMirror.isMirrored(path), "\(path)")
      try store.save(StoreTextRecord(id: "bad-\(path.hashValue)", project: "P1", path: path, text: "x"))
    }
    #expect(try mac.reconcile() == .init())
    #expect(!FileManager.default.fileExists(atPath: mac.texts.folder.appendingPathComponent("escaped.txt").path))
    #expect(!FileManager.default.fileExists(atPath: mac.texts.privateFolder.path))
    #expect(StoreVaultMirror.isMirrored(testersPath))
    #expect(StoreVaultMirror.isMirrored("translations.json"))
  }

  @Test func anotherProjectsTextsStayApart() throws {
    let store = try store()
    let one = try device("one", store, project: "P1")
    let two = try device("two", store, project: "P2")
    try one.texts.write("For one", at: notes)
    _ = try one.reconcile()
    #expect(try two.reconcile() == .init())
    #expect(two.texts.entry(notes) == nil)

    try two.texts.write("For two", at: notes)
    _ = try two.reconcile()
    _ = try one.reconcile()
    #expect(one.texts.entry(notes)?.text == "For one")
    #expect(try store.records(StoreTextRecord.self).count == 2)
  }
}
