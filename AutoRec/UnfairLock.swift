import Foundation
import os

/// A plain mutex that is safe to take from an audio render thread.
///
/// `os_unfair_lock` is the one lock on this platform that hands the holder the
/// waiter's priority, so a background thread cannot stall the audio thread
/// indefinitely while holding it. `NSLock`/`pthread_mutex` have no such
/// donation and invert priorities instead.
///
/// It is NOT recursive: a `withLock` body must never call another method that
/// takes the same lock. Keep the locked regions small and free of blocking
/// calls (no engine teardown, no logging that could block).
final class UnfairLock {
    private let unfairLock: os_unfair_lock_t

    init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }
        return try body()
    }
}
