import Foundation
import Testing

@testable import DevApp

@Suite struct SidebarListingTests {
  private let repo = URL(fileURLWithPath: "/Users/me/Developer/Repo", isDirectory: true)
  private let link = URL(fileURLWithPath: "/Users/me/Workspaces/Reference/Repo", isDirectory: true)

  /// As in Git: a folder the vault doesn't have (gone, a link to a listed repository, removed in Git) isn't listed.
  @Test func personalListsTheVaultsFoldersAndCatalogs() {
    let listing = VaultProjects.Listing(isPersonal: true, own: [repo.path], others: [])
    #expect(listing.lists(repo))
    #expect(!listing.lists(link))
    #expect(listing.lists(nil))
  }

  @Test func anAccountListsItsOwnFoldersOnly() {
    let listing = VaultProjects.Listing(isPersonal: false, own: [link.path], others: [repo.path])
    #expect(listing.lists(link))
    #expect(!listing.lists(repo))
    #expect(!listing.lists(nil))
  }

  /// No vault lists a folder here yet: Dev's own list stands.
  @Test func withoutAVaultEverythingIsListed() {
    let listing = VaultProjects.Listing(isPersonal: true, own: [], others: [])
    #expect(listing.lists(repo))
    #expect(listing.lists(link))
  }
}
