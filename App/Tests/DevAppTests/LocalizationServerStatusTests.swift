import Foundation
import Testing

@testable import DevApp

/// The Localization Servers section before and after a check: launch contacts no server, so a row nobody checked says
/// "not checked", never offline or "0 online".
@Suite struct LocalizationServerStatusTests {
  @Test func aServerNobodyCheckedIsNotCheckedRatherThanOffline() {
    #expect(ServerStatus.unknown.isOnline == false)
    #expect(ServerStatus.unknown.short == "not checked")
    #expect(ServerStore().statuses.isEmpty)
    #expect(ServerStore.meta(serverIDs: ["a", "b"], statuses: [:]) == ["2 servers", "not checked"])
    #expect(ServerStore.meta(serverIDs: ["a"], statuses: ["a": .unknown]) == ["1 server", "not checked"])
  }

  @Test func theMetaCountsOnlineAmongTheCheckedAndNamesTheRest() {
    #expect(ServerStore.meta(serverIDs: [], statuses: [:]) == ["None connected"])
    let online = ServerStatus.online(messages: 3, commented: 1)
    #expect(ServerStore.meta(serverIDs: ["a", "b"], statuses: ["a": online]) == ["2 servers", "1 online", "1 not checked"])
    #expect(
      ServerStore.meta(serverIDs: ["a", "b"], statuses: ["a": online, "b": .offline("refused")]) == ["2 servers", "1 online"])
    // A check under way is a check: the meta doesn't flicker back to "not checked".
    #expect(ServerStore.meta(serverIDs: ["a"], statuses: ["a": .checking]) == ["1 server", "0 online"])
  }
}
