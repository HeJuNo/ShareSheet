import Foundation

/// Runs `operation` and returns its result, or nil once `seconds` have passed. The operation is
/// cancelled on timeout but not awaited, so work that ignores cancellation cannot hold up the caller.
func bounded<T: Sendable>(
    _ seconds: Double, _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let gate = ResumeOnce<T?>()
    return await withCheckedContinuation { continuation in
        gate.set(continuation)
        let work = Task {
            gate.resume(with: await operation())
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
            gate.resume(with: nil)
        }
    }
}

/// Resumes a continuation exactly once, whichever side gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func set(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
