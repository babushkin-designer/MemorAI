import Foundation

/// Launch and call-start share a lock: no queued warmup can launch a server
/// after the call gate closes. The gate also owns the process reference.
final class CallWorkGate {
    private let lock = NSLock()
    private var active = false
    private var enabled = true
    private var process: Process?
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return active || !enabled }
    var server: Process? { lock.lock(); defer { lock.unlock() }; return process }

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        let old = value ? process : nil
        if value { process = nil }
        lock.unlock()
        if let old, old.isRunning { old.terminate() }
    }

    func launch(_ make: () throws -> Process) rethrows -> Process? {
        lock.lock()
        defer { lock.unlock() }
        guard !active, enabled else { return nil }
        let child = try make()
        process = child
        return child
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        let old = value ? nil : process
        if !value { process = nil }
        lock.unlock()
        if let old, old.isRunning { old.terminate() }
    }

    func stopServer() {
        lock.lock()
        let old = process
        process = nil
        lock.unlock()
        if let old, old.isRunning { old.terminate() }
    }
}
