import Foundation
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// The app's launch and quit, for what SwiftUI's scenes don't say: the work to finish before the app goes and the
/// question whether it may (unsaved edits). Install it in the `App` with `@DevAppDelegateAdaptor(DevAppDelegate.self)`
/// and set the hooks before the first scene appears:
///
/// ```swift
/// DevAppDelegate.shouldTerminate = { store.hasUnsavedChanges == false }
/// ```
///
/// The Mac's application delegate; elsewhere the hooks are kept but the system never asks (`willTerminate` runs at
/// exit).
public final class DevAppDelegate: NSObject {
  /// Called once the app has finished launching.
  @MainActor public static var didFinishLaunching: (@MainActor () -> Void)?
  /// Called as the app quits, for writes that must land.
  @MainActor public static var willTerminate: (@MainActor () -> Void)?
  /// Asked when the user quits: false keeps the app open.
  @MainActor public static var shouldTerminate: (@MainActor () -> Bool)?

  override public init() {
    super.init()
    #if !canImport(AppKit)
      atexit {
        MainActor.assumeIsolated { DevAppDelegate.willTerminate?() }
      }
    #endif
  }
}

#if canImport(AppKit)
  extension DevAppDelegate: NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
      MainActor.assumeIsolated { Self.didFinishLaunching?() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
      MainActor.assumeIsolated { Self.willTerminate?() }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      MainActor.assumeIsolated { (Self.shouldTerminate?() ?? true) ? .terminateNow : .terminateCancel }
    }
  }

  /// Installs `DevAppDelegate` as the app's delegate: SwiftUI's own adaptor.
  public typealias DevAppDelegateAdaptor = NSApplicationDelegateAdaptor<DevAppDelegate>
#else
  /// Keeps `DevAppDelegate` for the app's life where SwiftUI has no application delegate.
  @propertyWrapper public struct DevAppDelegateAdaptor: DynamicProperty {
    private let delegate: DevAppDelegate

    public init(_ type: DevAppDelegate.Type = DevAppDelegate.self) { delegate = type.init() }

    public var wrappedValue: DevAppDelegate { delegate }
  }
#endif
