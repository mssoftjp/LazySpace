import Foundation
import LayoutCore

/// Delayed OS work belongs to one operation, even if that operation finishes without cancellation.
/// The main thread can read this after the operations queue has returned its result.
final class OperationLifetime {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func finish() { lock.lock(); active = false; lock.unlock() }
}

/// Stop requests such as Pause. Read across threads.
public final class OperationControl {
    private let lock = NSLock()
    private var _paused = false
    private var _hurrySettle = false
    private var generation: UInt64 = 0
    /// The generation last advanced by `invalidate()`, kept apart from Pause's so the stop reason is "cancelled".
    private var invalidatedGeneration: UInt64 = 0

    public init(paused: Bool = false) { _paused = paused }

    public var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); if newValue { generation &+= 1 }; _paused = newValue; lock.unlock() }
    }

    /// Resuming after Pause does not revive the authorization of operations already started.
    public var cancellationGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }; return generation
    }

    /// Stops in-flight automatic operations so the next one can start over from the latest observation.
    /// Uses a generation separate from Pause, so the stop reason is not "paused".
    public func invalidate() {
        lock.lock(); generation &+= 1; invalidatedGeneration = generation; lock.unlock()
    }

    /// When the generation captured at acceptance differs from now: Pause or cancellation.
    func mismatchReason(captured: UInt64) -> StopReason? {
        lock.lock(); defer { lock.unlock() }
        guard generation != captured else { return nil }
        return generation == invalidatedGeneration ? .cancelled : .paused
    }

    /// A user command is waiting. Cuts only the settle wait short, never the writes.
    public var hurrySettle: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hurrySettle }
        set { lock.lock(); _hurrySettle = newValue; lock.unlock() }
    }
}

/// Authorization at acceptance. Also expires on Pause, input, or a Space change while waiting in the queue.
public struct OperationAuthorization {
    public let spaceID: UInt64?
    private let generation: UInt64
    private let inputCount: UInt64
    private let paused: Bool
    private let allowPaused: Bool
    public var expectedWindow: ObservedWindow?
    public var expectedSpaceID: UInt64?

    public init(system: WindowSystem, control: OperationControl, allowPaused: Bool = false) {
        generation = control.cancellationGeneration
        paused = control.paused
        inputCount = system.inputActivityCount
        spaceID = system.currentSpaceID()
        self.allowPaused = allowPaused
    }

    /// The same baseline (input, pause, cancellation) for an operation on another Space, such as one another display shows.
    public func retargeted(to spaceID: UInt64?) -> OperationAuthorization {
        OperationAuthorization(spaceID: spaceID, generation: generation, inputCount: inputCount, paused: paused, allowPaused: allowPaused)
    }

    private init(spaceID: UInt64?, generation: UInt64, inputCount: UInt64, paused: Bool, allowPaused: Bool) {
        self.spaceID = spaceID; self.generation = generation; self.inputCount = inputCount; self.paused = paused; self.allowPaused = allowPaused
    }

    /// Also used by operations that switch Spaces on purpose. A new Pause always expires it.
    public func interruptionReason(system: WindowSystem, control: OperationControl) -> StopReason? {
        if !allowPaused && (paused || control.paused) { return .paused }
        if let reason = control.mismatchReason(captured: generation) { return reason }
        if system.inputActivityCount != inputCount { return .userInput }
        return nil
    }

    public func stopReason(system: WindowSystem, control: OperationControl, snapshot: Snapshot) -> StopReason? {
        if let reason = interruptionReason(system: system, control: control) { return reason }
        if let expectedSpaceID, spaceID != expectedSpaceID { return .spaceChanged }
        guard let spaceID, snapshot.spaceObservationAvailable, snapshot.spaceID == spaceID,
              system.currentSpaceID() == spaceID else { return .spaceChanged }
        if let expectedWindow, !snapshot.windows.contains(where: {
            $0.id == expectedWindow.id && $0.pid == expectedWindow.pid && $0.app == expectedWindow.app && $0.membership == .current
        }) { return .targetsChanged }
        return nil
    }
}

/// Operation limits.
public struct OperationLimits: Equatable {
    /// Recalculations after a size mismatch.
    public var maxRetries: Int
    /// Deadline for AX requests to one app.
    public var perAppTimeout: TimeInterval
    /// Wait after writing before reading back.
    public var settleDelay: TimeInterval
    /// Geometry tolerance (logical points, per edge).
    public var tolerance: Double

    public init(maxRetries: Int = 1, perAppTimeout: TimeInterval = 2.0, settleDelay: TimeInterval = 0.08, tolerance: Double = 1.0) {
        self.maxRetries = maxRetries
        self.perAppTimeout = perAppTimeout
        self.settleDelay = settleDelay
        self.tolerance = tolerance
    }
}
