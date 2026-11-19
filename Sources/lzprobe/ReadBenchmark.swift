#if LAZYSPACE_PERF
import Foundation
import Darwin
import LayoutCore
import MacSupport
import Operations

/// Read-only: no window changes, Space switches, or setting changes.
enum ReadBenchmark {
    struct Sample: Codable {
        var mode: String
        var wallMs: Double
        var cpuMs: Double
        var calls: [String: Int]
        var windowCount: Int
    }
    struct Output: Codable {
        var iterations: Int
        var trusted: Bool
        var spaceStayedSame: Bool
        var selectedWindow: UInt32
        var samples: [Sample]
    }
    static func cpuMs() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }
    struct ArrangeSample: Codable {
        var wallMs: Double
        var cpuMs: Double
        var calls: [String: Int]
        var result: OperationResult
    }
    static func arrange(args: Args, outDir: String) {
        let system = MacWindowSystem()
        guard system.axTrusted, let raw = args["window"].flatMap(UInt32.init) else { exit(2) }
        let id = WindowID(raw)
        let snap = system.snapshot(limitingTo: [id])
        guard let target = TargetSelection.inspect(snap).targets.first(where: { $0.id == id }),
              target.app == "jp.lazyspace.probe" else {
            fputs("Arrange benchmark accepts only a LazySpaceProbe test window\n", stderr); exit(2)
        }
        let original = target.frame
        defer { _ = system.writeFrame(id, frame: original, timeout: 2) }
        var samples: [ArrangeSample] = []
        for _ in 0..<max(1, min(100, Int(exactly: args.double("iterations", 20).rounded()) ?? 20)) {
            guard system.currentSpaceID() == snap.spaceID else { break }
            _ = system.writeFrame(id, frame: original, timeout: 2)
            Thread.sleep(forTimeInterval: 0.15)
            let operation = ArrangeOperation(system: system, control: OperationControl(), knowledge: ConstraintKnowledge(),
                                             allowedWindows: [id], observedWindows: [id])
            ObservationMetrics.reset()
            let cpu = cpuMs()
            let result = operation.run()
            samples.append(ArrangeSample(wallMs: result.wallMs, cpuMs: cpuMs() - cpu,
                                         calls: ObservationMetrics.snapshot(), result: result))
        }
        _ = Report.write(samples, name: "arrange-benchmark", dir: outDir)
    }

    struct ListSample: Codable {
        var mode: String
        /// Count the reader returned (kept windows for census, list entries for the others).
        var resultCount: Int
        var medianCpuMs: Double
        var meanCpuMs: Double
        var medianWallMs: Double
        var meanWallMs: Double
    }
    /// CPU time per call of each window-list reader. Needs no Accessibility access and no windows.
    static func lists(args: Args, outDir: String) {
        let iterations = max(1, min(1000, Int(exactly: args.double("iterations", 300).rounded()) ?? 300))
        let modes: [(String, () -> Int)] = [
            ("census", { WindowCensus.take(spaceID: nil).windows.count }),
            ("all-records", { WindowList.allIfAvailable()?.count ?? -1 }),
            ("existing-ids", { WindowList.existingIDsIfAvailable()?.count ?? -1 }),
            ("on-screen-order", { WindowList.onScreenOrder().count }),
            ("listed-ids", { WindowList.listedIDsIfAvailable()?.count ?? -1 }),
        ]
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        var samples: [ListSample] = []
        for (mode, read) in modes {
            var cpu: [Double] = []
            var wall: [Double] = []
            var resultCount = 0
            for _ in 0..<iterations {
                autoreleasepool {
                    let before = cpuMs()
                    wall.append(ms { resultCount = read() })
                    cpu.append(cpuMs() - before)
                }
            }
            samples.append(ListSample(mode: mode, resultCount: resultCount,
                                      medianCpuMs: median(cpu), meanCpuMs: cpu.reduce(0, +) / Double(iterations),
                                      medianWallMs: median(wall), meanWallMs: wall.reduce(0, +) / Double(iterations)))
        }
        _ = Report.write(samples, name: "list-benchmark", dir: outDir)
        _ = Report.write(listParity(rounds: 50), name: "list-parity", dir: outDir)
    }

    struct ListParity: Codable {
        /// Whether `CGWindowListCreate` was found (false: the IDs come from the full list itself, and the comparison proves nothing).
        var idsOnlyRead: Bool
        var rounds: Int
        var unavailable: Int
        /// Rounds whose two IDs-only reads (before and after the full list) differ: a window opened or closed meanwhile, so nothing is compared.
        var listChanged: Int
        /// Rounds where both IDs-only reads agree and the full list's records between them differ: the readers disagree, or a window
        /// opened and closed between the reads. An upper bound on disagreement; zero is the conclusive result.
        var differing: Int
    }
    /// Same-moment comparison of the IDs-only read with the full list's records, outside the timed loop.
    static func listParity(rounds: Int) -> ListParity {
        var out = ListParity(idsOnlyRead: WindowList.readsIDsOnly, rounds: rounds, unavailable: 0, listChanged: 0, differing: 0)
        for _ in 0..<rounds {
            guard let before = WindowList.listedIDsIfAvailable(), let full = WindowList.allIfAvailable().map({ Set($0.keys) }),
                  let after = WindowList.listedIDsIfAvailable() else { out.unavailable += 1; continue }
            if before != after { out.listChanged += 1 } else if before != full { out.differing += 1 }
        }
        return out
    }

    static func run(args: Args, outDir: String) {
        let system = MacWindowSystem()
        guard system.axTrusted else { fputs("Accessibility unavailable; no benchmark run\n", stderr); exit(2) }
        let initial = system.snapshot()
        let candidates = TargetSelection.inspect(initial).targets
        let id = args["window"].flatMap(UInt32.init).map(WindowID.init) ?? candidates.first?.id
        guard let id, candidates.contains(where: { $0.id == id }) else {
            fputs("No eligible benchmark window\n", stderr); exit(2)
        }
        let iterations = max(1, min(100, Int(exactly: args.double("iterations", 20).rounded()) ?? 20))
        let modes = ["full", "limited", "space-preflight", "space-overview", "space-ids"]
        var samples: [Sample] = []
        var sameSpace = true
        for i in 0..<iterations {
            // Alternate the order to reduce order bias.
            for mode in (i.isMultiple(of: 2) ? modes : modes.reversed()) {
                guard system.currentSpaceID() == initial.spaceID else { sameSpace = false; break }
                ObservationMetrics.reset()
                var windows = 0
                let cpu = cpuMs()
                let wall = ms {
                    switch mode {
                    case "full": windows = system.snapshot().windows.count
                    case "limited": windows = system.snapshot(limitingTo: [id]).windows.count
                    case "space-preflight":
                        _ = Snapshot(trusted: system.axTrusted, spaceID: system.currentSpaceID(), workArea: .zero,
                                     windows: [], spaceObservationAvailable: system.spaceObservationAvailable)
                    case "space-overview": windows = SpaceOverview.take()?.spaces.reduce(0) { $0 + $1.windowIDs.count } ?? 0
                    case "space-ids": _ = SpaceObserver()?.managedDisplays().flatMap(\.spaces)
                    default: break
                    }
                }
                samples.append(Sample(mode: mode, wallMs: wall, cpuMs: cpuMs() - cpu,
                                      calls: ObservationMetrics.snapshot(), windowCount: windows))
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !sameSpace { break }
        }
        _ = Report.write(Output(iterations: iterations, trusted: system.axTrusted, spaceStayedSame: sameSpace,
                                selectedWindow: id.raw, samples: samples), name: "read-benchmark", dir: outDir)
    }
}
#endif
