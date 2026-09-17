//
//  StoreWork.swift
//  Dev
//
//  Created by Dmitry on 17.09.26.
//

import Foundation

/// The ONE queue the app's bulk store work runs on: created the first time something asks
/// for it, then reused by every later caller.
///
/// The problem it exists for: the work that makes a catalog usable is not the work that
/// makes it OPEN. Reading a project's records is a fetch; mirroring a whole `.xcstrings`
/// into them is tens of thousands of inserts and seconds of work (48,420 slots measured at
/// ~6 s in Debug). The pane, a run and a Save must not stand behind the second kind — an
/// open that waits for it is a window that reads "Opening catalog…" while the user is
/// looking at a table the file already describes.
///
/// So the heavy half is SUBMITTED here instead of awaited: the caller keeps going, the work
/// runs in order behind whatever was submitted before it, and the queue tells the app how
/// much is still in flight (`isBusy`) so the surfaces that need a settled store — the clear
/// (7.5), a run's own reads — can say so.
///
/// Why a QUEUE and not a set of detached tasks: these passes all create and adopt the same
/// slots, so two of them at once can insert the same record twice (SwiftData has no unique
/// constraint to stop it) and last-writer-wins between them decides a slot's provenance by
/// timing. Serial is the property that makes them safe, and one shared queue is what makes
/// every caller serial with every other caller (`LocalizationStore`'s mirror, the plural
/// skeleton, the add-languages seeding), not just with its own earlier self.
///
/// `@MainActor` for its own state (`queued`, `tail`) only: the jobs themselves are
/// `@Sendable` closures that do their real work off the main actor, exactly as they did
/// before (`Reconcile.mirrorOffMainActor` is a `Task.detached` inside).
@Observable
@MainActor
final class StoreWork {
  /// The app's one queue. `static let` is the lazy creation: built on first use, one
  /// instance for the process, reused by every caller after that.
  static let shared = StoreWork()

  /// The last submitted job. A new job awaits this one's `value` before it starts, which
  /// is what makes the order submission order.
  private var tail: Task<Void, Never>?

  /// Jobs submitted and not finished yet. The reading the surfaces that need a settled
  /// store gate on.
  private(set) var queued = 0

  /// True while any bulk store work is still to run.
  var isBusy: Bool { queued > 0 }

  /// For the log lines that name what is going on: "2 jobs" / "idle".
  var summary: String {
    queued == 0 ? "idle" : "\(queued) job\(queued == 1 ? "" : "s")"
  }

  /// Submits work to run after everything already submitted, and returns its result. The
  /// caller waits for THIS job (not for the queue to drain).
  ///
  /// The closure is `@MainActor` on purpose: the jobs this queue carries are app-side
  /// operations that must touch `@MainActor` state between their own off-actor hops (a
  /// store refresh, a row rebuild), and the heavy half of each one does its own hop
  /// (`Reconcile.mirrorOffMainActor` is a `Task.detached` inside). What the queue adds is
  /// ORDER, never a thread.
  @discardableResult
  func enqueue<T>(_ work: @escaping @MainActor () async -> T) async -> T {
    await schedule(work).value
  }

  /// Submits work nobody waits for — the shape the load path wants: the pane is already
  /// open and the store catches up behind it.
  ///
  /// The count and the tail are updated SYNCHRONOUSLY (inside `schedule`), so a caller that
  /// submits and immediately asks `isBusy` is told the truth: the job is planned, whether
  /// or not the main actor has had a turn to start it.
  func submit(_ work: @escaping @MainActor () async -> Void) {
    _ = schedule(work)
  }

  /// Places one job behind the current tail and returns it. The ONE place the order, the
  /// count and the tail are written, so `enqueue` and `submit` cannot drift apart.
  private func schedule<T>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
    let previous = tail
    queued += 1
    let job = Task { () -> T in
      await previous?.value
      return await work()
    }
    // The bookkeeping runs on the job's own completion — the count is the number of jobs
    // still to run, so a job that threw (none do: these return Results) still decrements.
    let ticket = Task { () -> T in
      let value = await job.value
      queued -= 1
      return value
    }
    tail = Task { _ = await ticket.value }
    return job
  }

  /// Waits for everything submitted SO FAR. A barrier, not a lock: work submitted while
  /// this waits is not waited for (the next `drain` is its barrier).
  func drain() async {
    await tail?.value
  }
}
