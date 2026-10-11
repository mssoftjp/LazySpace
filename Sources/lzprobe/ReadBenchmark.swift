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
