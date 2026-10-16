//
//  DiskUsage.swift
//  Dev
//

import Darwin
import Foundation

/// File-tree walks over `fts(3)`: the same traversal `du` uses — allocated
/// blocks rather than logical length (sparse VM disks read as what they take),
/// never crossing onto another volume — made aware of shared blocks: a hard
/// link, and the part of an APFS clone shared with its other copies, count
/// once per scan instead of once per path. `du` and Finder count every clone
/// in full, so a disk full of clones (uv, pnpm and Bun clone from their caches
/// into projects) adds up to more than the disk holds.
nonisolated enum DiskUsage {
  /// What a measurement found: the bytes the item takes (its own blocks, plus
  /// shared blocks no earlier item counted), and the shared bytes another
  /// item already counted.
  struct Measurement {
    var bytes: Int64 = 0
    var sharedElsewhere: Int64 = 0
    /// The latest modification time of anything measured, in seconds since 1970.
    var newest = 0
  }

  /// Bytes under `paths`, skipping the `excluded` subtrees (they are another
  /// item's bytes). Shared blocks are counted by whichever item reaches them
  /// first in `ledger`. Missing paths count as zero. Checks for task
  /// cancellation as it goes and returns what it had counted when cancelled.
  static func measure(
    _ paths: [String], excluding excluded: [String] = [], ledger: SharedBlockLedger = SharedBlockLedger()
  ) -> Measurement {
    let skipped = Set(excluded)
    var measurement = Measurement()
    var accounting = SharedAccounting(ledger: ledger)
    walk(paths) { entry in
      // Excluded items can be folders or single files (a model file inside
      // a project folder): either way their bytes are someone else's.
      if !skipped.isEmpty, skipped.contains(entry.path) {
        return .skip
      }
      measurement.newest = max(measurement.newest, entry.modified.tv_sec)
      if entry.isDirectory {
        measurement.bytes += entry.allocatedBytes
      } else {
        let counted = accounting.count(entry)
        measurement.bytes += counted.bytes
        measurement.sharedElsewhere += counted.sharedElsewhere
      }
      return .descend
    }
    return measurement
  }

  /// Files below this are not asked about clones: one more system call per
  /// file, for blocks that barely add up (measured: files under 64 KB hold
  /// about a tenth of a percent of the shared bytes in a developer's home).
  static let cloneCheckThreshold: Int64 = 64 * 1024

  /// Per-walk bookkeeping over a scan-wide ledger: a file's hard link or
  /// clone group counts once within the walk, and once across the scan.
  struct SharedAccounting {
    let ledger: SharedBlockLedger
    private var links = Set<FileKey>()
    private var clones = Set<UInt64>()

    init(ledger: SharedBlockLedger) { self.ledger = ledger }

    mutating func count(_ entry: Entry) -> Measurement {
      let bytes = entry.allocatedBytes
      if entry.linkCount > 1 {
        let key = FileKey(device: entry.device, inode: entry.inode)
        guard links.insert(key).inserted else { return Measurement() }
        return ledger.claim(link: key)
          ? Measurement(bytes: bytes) : Measurement(sharedElsewhere: bytes)
      }
      guard bytes >= cloneCheckThreshold, let clone = entry.cloneInfo,
        clone.flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
      else { return Measurement(bytes: bytes) }
      // The private part is this file's alone; the rest is shared with its
      // clones (or held by a snapshot) and counts once per clone group.
      let own = min(bytes, max(0, clone.privateSize))
      let shared = bytes - own
      guard shared > 0, clones.insert(clone.id).inserted else { return Measurement(bytes: own) }
      return ledger.claim(clone: clone.id)
        ? Measurement(bytes: bytes) : Measurement(bytes: own, sharedElsewhere: shared)
    }
  }

  /// The size of every folder under `root` whose path has at most `maxDepth`
  /// components and holds at least `minBytes` — what `du -d` prints — plus the
  /// folders it was not allowed to read. One post-order pass: each folder's
  /// total is its files plus its subfolders' totals.
  static func directorySizes(
    of root: String, maxDepth: Int, minBytes: Int64, progress: ((Int64) -> Void)? = nil
  ) -> (sizes: [String: Int64], denied: [String]) {
    withoutDownloading { directorySizesWalk(of: root, maxDepth: maxDepth, minBytes: minBytes, progress: progress) }
  }

  private static func directorySizesWalk(
    of root: String, maxDepth: Int, minBytes: Int64, progress: ((Int64) -> Void)?
  ) -> (sizes: [String: Int64], denied: [String]) {
    let arguments: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
    defer { arguments.forEach { free($0) } }
    let stream = arguments.withUnsafeBufferPointer { buffer in
      fts_open(buffer.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
    }
    guard let stream else { return ([:], [root]) }
    defer { fts_close(stream) }

    let rootDepth = root.split(separator: "/").count
    var sizes: [String: Int64] = [:]
    var denied: [String] = []
    var accounting = SharedAccounting(ledger: SharedBlockLedger())
    // The running total of each open folder, indexed by its fts level.
    var totals: [Int64] = []
    var visited = 0
    var counted: Int64 = 0

    func close(_ entry: Entry) {
      let level = entry.level
      guard level < totals.count else { return }
      let total = totals[level]
      totals.removeSubrange(level...)
      if level > 0 { totals[level - 1] += total }
      if level == 0 || (rootDepth + level <= maxDepth && total >= minBytes) {
        sizes[entry.path] = total
      }
    }

    while let pointer = fts_read(stream) {
      visited += 1
      if visited & 0xFFF == 0 {
        if Task.isCancelled { break }
        progress?(counted)
      }
      let entry = Entry(pointer: pointer)
      switch Int32(pointer.pointee.fts_info) {
      case FTS_D:
        // Skipped folders get no post-order visit, so nothing is pushed.
        if entry.isDataless {
          fts_set(stream, pointer, FTS_SKIP)
          continue
        }
        totals.removeSubrange(min(entry.level, totals.count)...)
        totals.append(entry.allocatedBytes)
      case FTS_DP:
        close(entry)
      case FTS_DNR:
        // fts hands back an unreadable folder in place of its post-order visit.
        let error = pointer.pointee.fts_errno
        if error == EPERM || error == EACCES { denied.append(entry.path) }
        close(entry)
      case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
        let bytes = accounting.count(entry).bytes
        counted += bytes
        if entry.level > 0, entry.level - 1 < totals.count {
          totals[entry.level - 1] += bytes
        }
      default:
        continue
      }
    }
    return (sizes, denied)
  }

  /// What a visitor decides for a directory. Ignored for files.
  enum Decision {
    case descend
    case skip
  }

  /// One visited file-system entry, read straight off the `FTSENT`.
  struct Entry {
    let pointer: UnsafeMutablePointer<FTSENT>

    var isDirectory: Bool { Int32(pointer.pointee.fts_info) == FTS_D }

    /// The full path. Allocates a String, so visitors that only need the name
    /// or the size should not ask for it on every file.
    var path: String { String(cString: pointer.pointee.fts_path) }

    /// The last path component.
    var name: String {
      let entry = pointer.pointee
      return String(cString: entry.fts_path + Int(entry.fts_pathlen) - Int(entry.fts_namelen))
    }

    /// Depth below the walk's root (the root itself is 0).
    var level: Int { Int(pointer.pointee.fts_level) }

    var allocatedBytes: Int64 {
      guard let stat = pointer.pointee.fts_statp else { return 0 }
      return Int64(stat.pointee.st_blocks) * 512
    }

    var logicalBytes: Int64 {
      guard let stat = pointer.pointee.fts_statp else { return 0 }
      return Int64(stat.pointee.st_size)
    }

    var linkCount: Int {
      guard let stat = pointer.pointee.fts_statp else { return 1 }
      return Int(stat.pointee.st_nlink)
    }

    /// A file or folder that lives only in the cloud (iCloud Drive, other
    /// File Providers, "Optimize Mac Storage"). It takes no space here, and
    /// listing such a folder makes macOS download it first — a scan that
    /// waits on the network for as long as that takes.
    var isDataless: Bool {
      guard let stat = pointer.pointee.fts_statp else { return false }
      return stat.pointee.st_flags & UInt32(SF_DATALESS) != 0
    }

    var device: Int32 { pointer.pointee.fts_statp?.pointee.st_dev ?? 0 }
    var inode: UInt64 { pointer.pointee.fts_statp?.pointee.st_ino ?? 0 }

    var isRegularFile: Bool {
      guard let stat = pointer.pointee.fts_statp else { return false }
      return stat.pointee.st_mode & S_IFMT == S_IFREG
    }

    var ownerID: uid_t { pointer.pointee.fts_statp?.pointee.st_uid ?? 0 }

    /// The BSD flags (`chflags`): locked, compressed, dataless…
    var flags: UInt32 { pointer.pointee.fts_statp?.pointee.st_flags ?? 0 }

    var modified: timespec { pointer.pointee.fts_statp?.pointee.st_mtimespec ?? timespec() }

    /// APFS's clone bookkeeping for this file, or nil where the volume does
    /// not keep it: whether it may share blocks, how many are its own, and the
    /// id its pure clones share.
    var cloneInfo: CloneInfo? { DiskUsage.cloneInfo(atPath: pointer.pointee.fts_path) }
  }

  /// APFS's clone bookkeeping for the file at `path` (not following a
  /// symlink), or nil where the volume does not keep it.
  static func cloneInfo(atPath path: UnsafePointer<CChar>) -> CloneInfo? {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    // Extended common attributes ride in `forkattr` with FSOPT_ATTR_CMN_EXTENDED.
    list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)
      | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
    var buffer = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS)
    return withUnsafeMutableBytes(of: &buffer) { raw -> CloneInfo? in
      guard getattrlist(path, &list, raw.baseAddress, raw.count, options) == 0 else {
        return nil
      }
      // u_int32 length, attribute_set_t (five u_int32), then the requested
      // attributes in bit order: PRIVATESIZE, CLONEID, EXT_FLAGS.
      let start = 4 + 20
      return CloneInfo(
        privateSize: raw.loadUnaligned(fromByteOffset: start, as: Int64.self),
        id: raw.loadUnaligned(fromByteOffset: start + 8, as: UInt64.self),
        flags: raw.loadUnaligned(fromByteOffset: start + 16, as: UInt64.self))
    }
  }

  /// Runs `body` with this thread told never to download cloud-only files:
  /// touching one fails at once instead of fetching it. Walks are
  /// synchronous, so the thread that sets the policy is the one that walks.
  static func withoutDownloading<T>(_ body: () -> T) -> T {
    let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
    let scope = Int32(IOPOL_SCOPE_THREAD)
    let previous = getiopolicy_np(type, scope)
    setiopolicy_np(type, scope, Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF))
    defer { setiopolicy_np(type, scope, previous >= 0 ? previous : Int32(IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)) }
    return body()
  }

  struct CloneInfo {
    let privateSize: Int64
    let id: UInt64
    let flags: UInt64
  }

  /// Walks `roots` depth-first, physically (symlinks are not followed) and on
  /// one volume. Each directory is offered to `visit` once, before its
  /// children; `.skip` prunes it. Entries that cannot be read are passed over.
  static func walk(_ roots: [String], visit: (Entry) -> Decision) {
    withoutDownloading { walkTree(roots, visit: visit) }
  }

  private static func walkTree(_ roots: [String], visit: (Entry) -> Decision) {
    let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
    guard !existing.isEmpty else { return }
    let arguments: [UnsafeMutablePointer<CChar>?] = existing.map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }

    let stream = arguments.withUnsafeBufferPointer { buffer in
      fts_open(buffer.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
    }
    guard let stream else { return }
    defer { fts_close(stream) }

    var visited = 0
    while let pointer = fts_read(stream) {
      visited += 1
      if visited & 0xFFF == 0, Task.isCancelled { return }
      switch Int32(pointer.pointee.fts_info) {
      case FTS_D:
        let entry = Entry(pointer: pointer)
        if entry.isDataless || visit(entry) == .skip {
          fts_set(stream, pointer, FTS_SKIP)
        }
      case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
        _ = visit(Entry(pointer: pointer))
      default:
        // FTS_DP (the post-order visit of a directory already counted), and
        // the unreadable kinds: FTS_DNR, FTS_ERR, FTS_NS, FTS_DC.
        continue
      }
    }
  }

  struct FileKey: Hashable {
    let device: Int32
    let inode: UInt64
  }
}

/// The shared blocks one scan has already counted, across the items it
/// measures in parallel: a hard link or clone group goes to the first item
/// that reaches it, and every later one reports it as shared instead.
nonisolated final class SharedBlockLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var links = Set<DiskUsage.FileKey>()
  private var clones = Set<UInt64>()

  /// True the first time a hard-linked file is seen in this scan.
  func claim(link: DiskUsage.FileKey) -> Bool { lock.withLock { links.insert(link).inserted } }

  /// True the first time a clone group is seen in this scan.
  func claim(clone: UInt64) -> Bool { lock.withLock { clones.insert(clone).inserted } }
}

nonisolated extension String {
  /// True when `self` is `ancestor` or lies inside it, comparing whole path
  /// components (`/a/bc` is not inside `/a/b`).
  func isInside(_ ancestor: String) -> Bool {
    guard hasPrefix(ancestor) else { return false }
    if count == ancestor.count { return true }
    return ancestor.hasSuffix("/") || self[index(startIndex, offsetBy: ancestor.count)] == "/"
  }

  /// `~/…` for paths in the home folder: shorter on screen, same meaning.
  var abbreviatingHome: String {
    (self as NSString).abbreviatingWithTildeInPath
  }
}
