//
//  VirtualMachines.swift
//  Dev
//

import Foundation
import ComponentKit
import Observation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - VirtualMachine

/// One UTM virtual machine, as `utmctl list` and its `.utm` bundle describe it.
nonisolated struct VirtualMachine: Identifiable, Hashable, Sendable {
  enum Status: String, Sendable {
    case stopped, starting, started, pausing, paused, resuming, stopping, unknown

    var isRunning: Bool { self == .started }
    var isBusy: Bool { [.starting, .pausing, .resuming, .stopping].contains(self) }
  }

  enum System: String, Sendable, CaseIterable {
    case linux, windows

    var title: String { self == .linux ? "Linux" : "Windows" }
  }

  let id: String
  let name: String
  var status: Status
  /// The VM's bundle, found through Spotlight; nil when it is not indexed.
  var bundleURL: URL?
  /// The network card's MAC address from the bundle's config, for the ARP lookup.
  var macAddress: String?

  /// A guess from the name, until the user says otherwise in the pane.
  var guessedSystem: System {
    name.localizedCaseInsensitiveContains("windows") ? .windows : .linux
  }
}

// MARK: - VMSettings

/// How Dev reaches one VM over SSH, remembered per VM.
nonisolated struct VMSettings: Codable, Equatable, Sendable {
  var user = ""
  /// Overrides the discovered address (a hostname or IP that resolves from this Mac).
  var host = ""
  var system: VirtualMachine.System?
  /// The VM's own name on this Mac's network (`<hostname>.local`, answered over Bonjour: Windows does it itself,
  /// Ubuntu through Avahi), learned the first time Dev reaches it and tried before looking for its address. It stays
  /// when vmnet moves the VM to another subnet: after a restart, whichever VM or colima starts first gets
  /// 192.168.64.x.
  var localName: String?

  static func load(_ id: String) -> VMSettings {
    guard let data = UserDefaults.standard.data(forKey: "vm.\(id)"),
          let settings = try? JSONDecoder().decode(VMSettings.self, from: data)
    else { return VMSettings() }
    return settings
  }

  func save(_ id: String) {
    if let data = try? JSONEncoder().encode(self) {
      UserDefaults.standard.set(data, forKey: "vm.\(id)")
    }
  }
}

extension VirtualMachine.System: Codable {}

// MARK: - VMStore

/// The UTM VMs on this Mac: their state, their address, and the commands that
/// start and stop them. Everything goes through `utmctl`, which ships with UTM.
/// `utmctl` opens UTM, so while UTM is closed the list comes from the `.utm`
/// bundles (every machine stopped) and only starting one opens it.
@Observable
final class VMStore {
  private(set) var machines: [VirtualMachine] = []
  private(set) var addresses: [String: String] = [:]
  private(set) var error: String?
  private(set) var isRefreshing = false
  /// VMs with a start, stop or suspend in flight.
  private(set) var pending: Set<String> = []
  /// Each VM's Run on VM, kept while the app is open. Filled lazily while a view
  /// asks, so it must not be observed.
  @ObservationIgnored private var runners: [String: VMRunner] = [:]

  func runner(for vm: VirtualMachine) -> VMRunner {
    if let runner = runners[vm.id] { return runner }
    let runner = VMRunner()
    runners[vm.id] = runner
    return runner
  }

  nonisolated static let utmctlPaths = ["/opt/homebrew/bin/utmctl", "/usr/local/bin/utmctl",
                            "/Applications/UTM.app/Contents/MacOS/utmctl"]
  static var utmctl: String? {
    utmctlPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// Whether UTM is open: only then may `utmctl` ask it anything.
  nonisolated static var isUTMRunning: Bool {
    KitDesktop.isAppRunning("com.utmapp.UTM")
  }

  func refresh() async {
    guard let utmctl = Self.utmctl else {
      error = String(localized: "UTM is not installed (utmctl not found).")
      machines = []
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }
    guard Self.isUTMRunning else {
      error = nil
      addresses = [:]
      machines = await Self.bundles()
        .map { id, bundle in
          VirtualMachine(id: id, name: bundle.name, status: .stopped, bundleURL: bundle.url, macAddress: bundle.mac)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      return
    }
    let result = await LineProcess.run(utmctl, ["list"])
    guard result.status == 0 else {
      error = result.output.isEmpty ? "utmctl list failed." : result.output
      return
    }
    error = nil
    let bundles = machines.isEmpty ? await Self.bundles() : [:]
    machines = Self.parseList(result.output).map { listed in
      var vm = listed
      if let known = machines.first(where: { $0.id == vm.id }) {
        vm.bundleURL = known.bundleURL
        vm.macAddress = known.macAddress
      } else if let bundle = bundles[vm.id] {
        vm.bundleURL = bundle.url
        vm.macAddress = bundle.mac
      }
      return vm
    }
    for vm in machines where vm.status.isRunning && addresses[vm.id] == nil {
      _ = await address(of: vm)
    }
  }

  /// `UUID  Status  Name` rows; the name may contain spaces.
  nonisolated static func parseList(_ output: String) -> [VirtualMachine] {
    let row = #/^(\S+)\s+(\S+)\s+(.+)$/#
    return output.split(separator: "\n").dropFirst().compactMap { line in
      guard let match = String(line).wholeMatch(of: row), UUID(uuidString: String(match.1)) != nil
      else { return nil }
      return VirtualMachine(
        id: String(match.1), name: match.3.trimmingCharacters(in: .whitespaces),
        status: VirtualMachine.Status(rawValue: String(match.2)) ?? .unknown)
    }
  }

  // MARK: - control

  func start(_ vm: VirtualMachine) async { await control(vm, "start") }
  func stop(_ vm: VirtualMachine) async { await control(vm, "stop") }
  func suspend(_ vm: VirtualMachine) async { await control(vm, "suspend") }

  private func control(_ vm: VirtualMachine, _ verb: String) async {
    guard let utmctl = Self.utmctl else { return }
    pending.insert(vm.id)
    defer { pending.remove(vm.id) }
    let result = await LineProcess.run(utmctl, [verb, vm.id])
    if result.status != 0 { error = "\(verb) \(vm.name): \(result.output)" }
    if verb != "start" { addresses[vm.id] = nil }
    await refresh()
  }

  // MARK: - address

  /// Where to SSH: the user's host, the VM's `.local` name when it answers, else the guest agent's answer or the
  /// address the VM's MAC has in this Mac's ARP table or DHCP leases (UTM's shared network), whose `.local` name is
  /// then learned for next time.
  func address(of vm: VirtualMachine) async -> String? {
    var settings = VMSettings.load(vm.id)
    if !settings.host.isEmpty { return settings.host }
    if let known = addresses[vm.id] { return known }
    if let name = settings.localName, await Self.resolves(name) {
      addresses[vm.id] = name
      return name
    }
    guard let found = await findAddress(vm) else { return nil }
    let user = settings.user.isEmpty ? Self.sshUser(for: vm) : settings.user
    if let name = await Self.localName(at: found, user: user) {
      settings.localName = name
      settings.save(vm.id)
      addresses[vm.id] = name
      return name
    }
    addresses[vm.id] = found
    return found
  }

  /// The `.local` name the machine at `address` answers to: its `hostname` over SSH (a Linux shell and Windows'
  /// OpenSSH both have it), kept only when the name resolves from this Mac. Nil while SSH isn't up yet.
  nonisolated static func localName(at address: String, user: String) async -> String? {
    let result = await LineProcess.run("/usr/bin/ssh", [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
      "-o", "LogLevel=ERROR", "\(user)@\(address)", "hostname",
    ])
    guard result.status == 0,
          let host = result.output.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
          let name = localName(forHostname: host)
    else { return nil }
    return await resolves(name) ? name : nil
  }

  /// `WINUI-VM` → `WINUI-VM.local`; nil for anything that isn't a plain host label.
  nonisolated static func localName(forHostname host: String) -> String? {
    guard (1...63).contains(host.count), host.first != "-",
          host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else { return nil }
    return host + ".local"
  }

  /// Whether `name` resolves to an IPv4 address within `seconds` (a `.local` name goes out over Bonjour; a VM that
  /// is off never answers, so the wait is bounded).
  nonisolated static func resolves(_ name: String, within seconds: Double = 3) async -> Bool {
    await withCheckedContinuation { continuation in
      let answer = ResumeOnce(continuation)
      DispatchQueue.global().async {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(name, nil, &hints, &result)
        if let result { freeaddrinfo(result) }
        answer.resume(status == 0)
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { answer.resume(false) }
    }
  }

  func forgetAddress(of vm: VirtualMachine) { addresses[vm.id] = nil }

  private func findAddress(_ vm: VirtualMachine) async -> String? {
    if let utmctl = Self.utmctl {
      let agent = await LineProcess.run(utmctl, ["ip-address", vm.id])
      if agent.status == 0,
         let ipv4 = agent.output.split(separator: "\n").map(String.init)
           .first(where: { $0.split(separator: ".").count == 4 }) {
        return ipv4
      }
    }
    guard let mac = vm.macAddress.map(Self.normalizedMAC) else { return nil }
    // A VM that has not talked to the host yet has no ARP entry: a broadcast ping
    // on UTM's shared network fills the table.
    _ = await LineProcess.run("/sbin/ping", ["-c", "1", "-t", "1", "192.168.64.255"])
    let arp = await LineProcess.run("/usr/sbin/arp", ["-an"])
    for line in arp.output.split(separator: "\n") {
      let words = line.split(separator: " ")
      guard let at = words.firstIndex(of: "at"), at + 1 < words.count,
            Self.normalizedMAC(String(words[at + 1])) == mac,
            let ip = words.first(where: { $0.hasPrefix("(") })
      else { continue }
      return String(ip.dropFirst().dropLast())
    }
    // An Apple Virtualization guest on its own bridge (192.168.65.x) ignores the broadcast, and its ARP entry
    // expires while it's idle; the address vmnet's DHCP server last leased to the card still finds it.
    let leases = (try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8)) ?? ""
    return Self.leasedAddress(of: mac, in: leases)
  }

  /// The address of the newest lease for a MAC in `/var/db/dhcpd_leases` (`hw_address=1,<mac>`; `lease` is the
  /// expiry in hex seconds).
  nonisolated static func leasedAddress(of mac: String, in leases: String) -> String? {
    var best: (ip: String, expiry: Int)?
    for entry in leases.components(separatedBy: "}") {
      var fields: [String: String] = [:]
      for line in entry.split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
      }
      guard let hardware = fields["hw_address"]?.split(separator: ",").last,
            normalizedMAC(String(hardware)) == mac, let ip = fields["ip_address"]
      else { continue }
      let expiry = Int(fields["lease"]?.replacingOccurrences(of: "0x", with: "") ?? "", radix: 16) ?? 0
      if best == nil || expiry > best!.expiry { best = (ip, expiry) }
    }
    return best?.ip
  }

  /// `2:57:80:a8:46:a5` and `02:57:80:A8:46:A5` are the same card.
  nonisolated static func normalizedMAC(_ mac: String) -> String {
    mac.lowercased().split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }
      .joined(separator: ":")
  }

  // MARK: - bundles

  /// Every `.utm` bundle in UTM's container or known to Spotlight, by VM UUID,
  /// with its name and first network MAC.
  private static func bundles() async -> [String: (url: URL, name: String, mac: String?)] {
    let found = await LineProcess.run("/usr/bin/mdfind", ["kMDItemFSName == '*.utm'"])
    let container = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Containers/com.utmapp.UTM/Data/Documents")
    let stored = (try? FileManager.default.contentsOfDirectory(atPath: container.path))?
      .map { container.appendingPathComponent($0).path } ?? []
    var out: [String: (URL, String, String?)] = [:]
    for path in Set(stored + found.output.split(separator: "\n").map(String.init)) where path.hasSuffix(".utm") {
      let url = URL(fileURLWithPath: path)
      guard let data = try? Data(contentsOf: url.appendingPathComponent("config.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let info = plist["Information"] as? [String: Any],
            let uuid = info["UUID"] as? String
      else { continue }
      let mac = (plist["Network"] as? [[String: Any]])?.first?["MacAddress"] as? String
      let name = info["Name"] as? String ?? url.deletingPathExtension().lastPathComponent
      out[uuid] = (url, name, mac)
    }
    return out
  }

  // MARK: - SSH defaults

  /// A `Host` in ~/.ssh/config named like the VM gives its user.
  nonisolated static func sshUser(for vm: VirtualMachine) -> String {
    let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    guard let text = try? String(contentsOf: config, encoding: .utf8) else { return NSUserName() }
    var inHost = false
    for raw in text.split(separator: "\n") {
      let words = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard let key = words.first?.lowercased(), words.count > 1 else { continue }
      if key == "host" {
        inHost = words.dropFirst().contains { $0.lowercased() == vm.name.lowercased() }
      } else if inHost, key == "user" {
        return words[1]
      }
    }
    return NSUserName()
  }
}

/// Resumes a continuation with the first answer only (a lookup racing its timeout).
private nonisolated final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

  func resume(_ value: Bool) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: value)
  }
}
