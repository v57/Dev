#if os(macOS)
  import DevScreenshots
  import Foundation

  /// The project's commit, as the screenshots record it.
  public struct ProjectVersion: Hashable, Sendable {
    /// `git rev-list --count HEAD`: the build number `release.sh` and Dev's workflows stamp on builds.
    public var build: Int?
    public var commit: String?
    /// Changes under the watched paths that aren't committed.
    public var dirty: Bool

    /// nil fields outside a git repository.
    public static func current(in root: URL, watch: [String]? = nil) -> ProjectVersion {
      let count = Shell.run("git", ["rev-list", "--count", "HEAD"], in: root)
      let head = Shell.run("git", ["rev-parse", "HEAD"], in: root)
      let status = Shell.run("git", ["status", "--porcelain", "--"] + (watch ?? []), in: root)
      return ProjectVersion(
        build: count.succeeded ? Int(count.trimmed) : nil,
        commit: head.succeeded ? head.trimmed : nil,
        dirty: status.succeeded && !status.trimmed.isEmpty)
    }

    /// Commits after `commit` that touch the watched paths; nil when git doesn't know the commit (rebased away).
    static func commits(since commit: String, in root: URL, watch: [String]?) -> Int? {
      let result = Shell.run("git", ["rev-list", "--count", "\(commit)..HEAD", "--"] + (watch ?? []), in: root)
      return result.succeeded ? Int(result.trimmed) : nil
    }
  }
#endif
