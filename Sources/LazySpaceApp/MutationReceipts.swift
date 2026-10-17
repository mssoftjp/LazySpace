import Foundation
import LayoutCore
import Operations

/// In-memory, session-scoped receipts for agent mutations.
///
/// A reservation changes no window, layout, focus, or configuration. Only a live
/// reserved identity can start a mutation, and it can do so once. Expiry, eviction,
/// and a new process session reject the identity instead of dispatching again.
/// Completion may record its result before the caller binds the operation ID;
/// the registry lock is the only lock this type takes, and it must not call back
/// into Coordinator while that lock is held.
final class MutationReceiptRegistry {
    struct Payload: Equatable {
        var cmd: String
        var edit: EditCommand?
        var windowID: WindowID?
        var expectedSpaceID: UInt64?
        var expectedPID: Int32?
        var desiredState: Bool?
    }

    struct Outcome: Equatable {
        var ok: Bool
        var code: String
        var message: String
        var operationID: String?
        var result: OperationResult?

        func response(requestID: String?) -> ControlPort.Response {
            ControlPort.Response(ok: ok, message: message, operationID: operationID, code: code, requestID: requestID, result: result)
        }
    }

    enum Decision: Equatable {
        case dispatch
        case outcome(Outcome)
    }

    enum Reservation: Equatable {
        case reserved(String)
        case refused(Outcome)
    }

    enum Product {
        case started(operationID: String, message: String)
        case refused(Outcome)
    }

    private struct Token: Equatable {
        var session: UUID
        var sequence: UInt64
        var text: String
    }

    private enum Phase {
        case reserved(at: TimeInterval)
        case dispatching(Payload)
        case pending(Payload, Outcome)
    }

    private struct Record {
        var token: String
        var payload: Payload
        var outcome: Outcome
    }

    private enum Located {
        case malformed
        case sessionMismatch
        case unknown
        case expired
        case live(Token, Phase)
        case retained(Record)
    }

    let session: UUID
    private let now: () -> TimeInterval
    private let activeLimit: Int
    private let terminalLimit: Int
    private let reservationTTL: TimeInterval
    private let lock = NSLock()
    private var nextSequence: UInt64?
    private var highestIssued: UInt64 = 0
    private var active: [String: Phase] = [:]
    private var terminal: [Record] = []
    /// Token awaiting its operation ID on the thread that is inside coordinator startup.
    private var armed: [UInt64: String] = [:]
    private var dispatchCountStorage = 0

    init(session: UUID = UUID(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         activeLimit: Int = 64, terminalLimit: Int = 32, reservationTTL: TimeInterval = 60, nextSequence: UInt64 = 1) {
        self.session = session
        self.now = now
        self.activeLimit = activeLimit
        self.terminalLimit = terminalLimit
        self.reservationTTL = reservationTTL
        self.nextSequence = nextSequence == 0 ? nil : nextSequence
    }

    var dispatchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dispatchCountStorage
    }

    var counts: (active: Int, terminal: Int) {
        lock.lock(); defer { lock.unlock() }
        return (active.count, terminal.count)
    }

    static func isCanonicalToken(_ raw: String) -> Bool { parse(raw) != nil }

    /// `SESSION-UUID:sequence`, uppercase UUID, no leading zeroes, sequence ≥ 1.
    static func parse(_ raw: String) -> (session: UUID, sequence: UInt64, text: String)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let uuidPart = parts[0]
        let sequencePart = parts[1]
        guard let uuid = UUID(uuidString: uuidPart), uuid.uuidString == uuidPart else { return nil }
        guard let first = sequencePart.first, ("1"..."9").contains(String(first)),
              sequencePart.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              let sequence = UInt64(sequencePart), String(sequence) == sequencePart else { return nil }
        let text = "\(uuid.uuidString):\(sequence)"
        guard text == raw else { return nil }
        return (uuid, sequence, text)
    }

    func reserve() -> Reservation {
        lock.lock(); defer { lock.unlock() }
        sweep(now())
        if active.count >= activeLimit {
            return .refused(Self.outcome(ok: false, code: "request-capacity", message: "Too many reserved or in-flight requests."))
        }
        guard let sequence = nextSequence else {
            return .refused(Self.outcome(ok: false, code: "request-sequence-exhausted", message: "The session cannot allocate another request ID."))
        }
        let text = "\(session.uuidString):\(sequence)"
        highestIssued = sequence
        nextSequence = sequence == UInt64.max ? nil : sequence + 1
        active[text] = .reserved(at: now())
        return .reserved(text)
    }

    /// Mark `token` as the receipt whose operation ID will be claimed on this thread before enqueue.
    func arm(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        armed[Self.threadKey()] = token
    }

    func disarm() {
        lock.lock(); defer { lock.unlock() }
        armed.removeValue(forKey: Self.threadKey())
    }

    /// Bind the armed receipt to `operationID` before the operation body can run.
    func claim(_ operationID: String) {
        lock.lock(); defer { lock.unlock() }
        guard let token = armed[Self.threadKey()], case .dispatching(let payload)? = active[token] else { return }
        active[token] = .pending(payload, Self.pending("Accepted.", operationID: operationID))
    }

    func begin(_ raw: String, payload: Payload) -> Decision {
        lock.lock(); defer { lock.unlock() }
        switch locate(raw, at: now()) {
        case .malformed:
            return .outcome(Self.outcome(ok: false, code: "usage", message: "The request ID is malformed."))
        case .sessionMismatch:
            return .outcome(Self.outcome(ok: false, code: "session-mismatch", message: "The request ID belongs to a different LazySpace session. An earlier effect may have occurred, and its outcome is unavailable."))
        case .unknown:
            return .outcome(Self.outcome(ok: false, code: "unknown-request", message: "The request ID has not been allocated in this session."))
        case .expired:
            return .outcome(Self.expired)
        case .live(let token, .reserved):
            active[token.text] = .dispatching(payload)
            dispatchCountStorage += 1
            return .dispatch
        case .live(_, .dispatching(let bound)):
            if bound != payload { return .outcome(Self.conflict) }
            return .outcome(Self.pending("Accepted.", operationID: nil))
        case .live(_, .pending(let bound, let outcome)):
            if bound != payload { return .outcome(Self.conflict) }
            return .outcome(outcome)
        case .retained(let record):
            if record.payload != payload { return .outcome(Self.conflict) }
            return .outcome(record.outcome)
        }
    }

    func query(_ raw: String) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        switch locate(raw, at: now()) {
        case .malformed:
            return Self.outcome(ok: false, code: "usage", message: "The request ID is malformed.")
        case .sessionMismatch:
            return Self.outcome(ok: false, code: "session-mismatch", message: "The request ID belongs to a different LazySpace session. An earlier effect may have occurred, and its outcome is unavailable.")
        case .unknown:
            return Self.outcome(ok: false, code: "unknown-request", message: "The request ID has not been allocated in this session.")
        case .expired:
            return Self.expired
        case .live(_, .reserved):
            return Self.outcome(ok: false, code: "request-not-submitted", message: "No mutation has been dispatched for this request ID.")
        case .live(_, .dispatching):
            return Self.pending("Accepted.", operationID: nil)
        case .live(_, .pending(_, let outcome)):
            return outcome
        case .retained(let record):
            return record.outcome
        }
    }

    /// Bind the single dispatch to its acceptance, or return a result already stored for it.
    func finish(_ raw: String, _ product: Product) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if let record = terminal.first(where: { $0.token == raw }) { return record.outcome }
        switch active[raw] {
        case .dispatching(let payload):
            switch product {
            case .refused(let outcome):
                retain(raw, payload, outcome)
                return outcome
            case .started(let operationID, let message):
                let outcome = Self.pending(message, operationID: operationID)
                active[raw] = .pending(payload, outcome)
                return outcome
            }
        case .pending(let payload, var outcome):
            switch product {
            case .started(let operationID, let message):
                guard outcome.operationID == operationID else {
                    return Self.outcome(ok: false, code: "internal-error", message: "The operation ID did not match the receipt.")
                }
                outcome.message = message
                active[raw] = .pending(payload, outcome)
                return outcome
            case .refused(let outcome):
                retain(raw, payload, outcome)
                return outcome
            }
        default:
            return Self.outcome(ok: false, code: "internal-error", message: "The request is not awaiting dispatch.")
        }
    }

    /// Copy a terminal operation result onto the receipt already bound to its operation ID.
    func absorb(_ result: OperationResult) {
        lock.lock(); defer { lock.unlock() }
        guard let (token, payload) = pendingIdentity(for: result.id) else { return }
        retain(token, payload, Self.finished(result))
    }

    // MARK: - Classification

    private func locate(_ raw: String, at time: TimeInterval) -> Located {
        sweep(time)
        guard let token = Self.token(raw) else { return .malformed }
        if token.session != session { return .sessionMismatch }
        if token.sequence > highestIssued { return .unknown }
        if let phase = active[token.text] { return .live(token, phase) }
        if let record = terminal.first(where: { $0.token == token.text }) { return .retained(record) }
        return .expired
    }

    private func sweep(_ time: TimeInterval) {
        let expired = active.compactMap { token, phase -> String? in
            guard case .reserved(let at) = phase, time >= at + reservationTTL else { return nil }
            return token
        }
        for token in expired { active.removeValue(forKey: token) }
    }

    private func retain(_ token: String, _ payload: Payload, _ outcome: Outcome) {
        active.removeValue(forKey: token)
        terminal.append(Record(token: token, payload: payload, outcome: outcome))
        if terminal.count > terminalLimit { terminal.removeFirst(terminal.count - terminalLimit) }
    }

    private static func threadKey() -> UInt64 { UInt64(pthread_mach_thread_np(pthread_self())) }

    private func pendingIdentity(for operationID: String) -> (String, Payload)? {
        for (token, phase) in active {
            if case .pending(let payload, let outcome) = phase, outcome.operationID == operationID {
                return (token, payload)
            }
        }
        return nil
    }

    private static func token(_ raw: String) -> Token? {
        guard let parsed = parse(raw) else { return nil }
        return Token(session: parsed.session, sequence: parsed.sequence, text: parsed.text)
    }

    private static func outcome(ok: Bool, code: String, message: String, operationID: String? = nil, result: OperationResult? = nil) -> Outcome {
        Outcome(ok: ok, code: code, message: message, operationID: operationID, result: result)
    }

    private static func pending(_ message: String, operationID: String?) -> Outcome {
        outcome(ok: true, code: "pending", message: message, operationID: operationID)
    }

    private static func finished(_ result: OperationResult) -> Outcome {
        outcome(ok: result.outcome == .complete, code: "finished", message: result.message, operationID: result.id, result: result)
    }

    private static let expired = outcome(ok: false, code: "request-expired", message: "The request ID is expired or no longer retained. It will not dispatch again.")
    private static let conflict = outcome(ok: false, code: "request-conflict", message: "The request ID is bound to a different mutation.")
}
