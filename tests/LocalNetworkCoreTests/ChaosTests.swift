import XCTest

@testable import LocalNetworkCore

/// Randomised runs combining every kind of misbehaviour the fake can produce.
@MainActor
final class ChaosTests: XCTestCase {
  func testInvariantsHoldUnderRandomisedChaos() throws {
    var successes = 0
    var failures = 0
    let only = ProcessInfo.processInfo.environment["CHAOS_SEED"].flatMap(Int.init)
    let seedCount = ProcessInfo.processInfo.environment["CHAOS_SEEDS"].flatMap(Int.init) ?? 500
    for seed in 1...seedCount where only == nil || only == seed {
      var random = SeededRandom(seed: UInt64(seed))
      let clock = FakeClock()
      let count = Int(random.nextDouble() * 12)
      let generated = (0..<count).map { index -> (String, ToggleState) in
        // Some names repeat, as with several "node" or "Python" entries.
        let name = random.nextDouble() < 0.2 ? "node" : "App \(index)"
        return (name, random.nextDouble() < 0.6 ? .on : .off)
      }
      // Same-named apps are sometimes linked, as System Settings does. A
      // linked group always shows one shared state.
      let linked = random.nextDouble() < 0.5
      var apps = generated
      if linked, let first = apps.firstIndex(where: { $0.0 == "node" }) {
        for index in apps.indices where apps[index].0 == "node" { apps[index].1 = apps[first].1 }
      }
      let settings = FakeSystemSettings(clock: clock, apps: apps)
      if linked { settings.linkedNames = ["node"] }
      settings.pressLatency = random.nextDouble() * 2
      settings.droppedPresses = random.nextDouble() < 0.3 ? 1 : 0
      settings.ambiguousPressErrors = random.nextDouble() < 0.3 ? 1 : 0
      settings.transientErrorRate = random.nextDouble() * 0.3
      settings.flapAfterOn = random.nextDouble() < 0.3
      let reorderAt = Int(random.nextDouble() * 6)
      let insertAt = Int(random.nextDouble() * 6)
      let duplicateInsert = random.nextDouble() < 0.3
      let crashAt = random.nextDouble() < 0.15 ? Int(random.nextDouble() * 4) + 1 : -1
      var crashed = false
      settings.afterPress = { press in
        if press == reorderAt { settings.shuffleKeepingSameNamesInOrder(&random) }
        if press == insertAt {
          // Sometimes the newcomer shares a name with an existing app.
          let name = duplicateInsert ? "node" : "Inserted \(press)"
          settings.append(name, .off, at: Int(random.nextDouble() * Double(settings.apps.count)))
        }
        if press == crashAt && !crashed {
          crashed = true
          settings.crash()
        }
      }

      let initiallyOn = Set(
        apps.enumerated().filter { $0.element.1 == .on }.map { settings.ids[$0.offset] })
      let initiallyOff = Set(
        apps.enumerated().filter { $0.element.1 == .off }.map { settings.ids[$0.offset] })

      let store = MemoryRecoveryStore()
      let runner = ResetRunner(
        session: settings, store: store,
        log: { if only != nil { print(String(format: "log t=%.2f ", clock.now.timeIntervalSinceReferenceDate) + $0) } },
        now: { clock.now }, sleep: { clock.sleep($0) })
      runner.traceEnabled = only != nil
      let started = clock.now
      let outcome = Result { try runner.run() }
      XCTAssertLessThan(clock.now.timeIntervalSince(started), 600, "seed \(seed) unbounded")

      _ = settings.states()  // apply pending changes
      if only != nil {
        print("apps", apps, "latency", settings.pressLatency, "reorderAt", reorderAt, "insertAt", insertAt, "crashAt", crashAt)
        print("presses", settings.pressLog)
        print("final", settings.apps.map { "\($0.label)=\($0.state)" }, "ids", settings.ids)
        print("outcome", outcome)
        print(settings.trace.joined(separator: "\n"))
      }
      let stateByID = Dictionary(uniqueKeysWithValues: zip(settings.ids, settings.apps.map(\.state)))
      for id in initiallyOff {
        XCTAssertEqual(stateByID[id], .off, "seed \(seed): a disabled app was enabled")
      }
      switch outcome {
      case .success(let result):
        successes += 1
        for id in initiallyOn {
          // Only same-named apps explicitly reported as ambiguous may be off.
          let label = settings.apps[settings.ids.firstIndex(of: id)!].label
          if result.report.ambiguous.contains(label) { continue }
          XCTAssertEqual(stateByID[id], .on, "seed \(seed): an enabled app was left off")
        }
        XCTAssertTrue(store.keys.isEmpty, "seed \(seed): recovery state not cleared")
      case .failure(let error):
        // A failure is acceptable only if it names every app it left off,
        // and only after a same-named app appeared mid-run, which makes it
        // impossible to know which one was switched off.
        failures += 1
        XCTAssertTrue(duplicateInsert, "seed \(seed) failed: \(error.localizedDescription)")
        let reported = (error as? ResetFailure)?.possiblyDisabled ?? []
        for id in initiallyOn where stateByID[id] != .on {
          let label = settings.apps[settings.ids.firstIndex(of: id)!].label
          XCTAssertTrue(
            reported.contains { $0 == label || $0.hasPrefix(label + " (") },
            "seed \(seed): \(label) left off but not reported (\(reported))")
        }
      }
    }
    if only == nil {
      XCTAssertEqual(successes + failures, seedCount)
      XCTAssertLessThan(Double(failures) / Double(seedCount), 0.005, "failures must stay rare")
      print("chaos: \(successes) succeeded, \(failures) failed safely")
    }
  }
}
