import Foundation

/// One place to run a subprocess correctly.
///
/// Both pipes are drained as data arrives: a child that fills the 64 KB pipe
/// buffer while the parent sits in `waitUntilExit()` blocks forever, and
/// ffmpeg's stderr does exceed that on long inputs. Every subprocess also gets
/// a deadline — post-processing now runs on the path that finishes a recording,
/// so a wedged child would strand the session (and, on quit, the app).
enum ProcessRunner {

    /// What the child is for, which decides how it competes with the rest of
    /// the machine. `.postProcessing` children are the heavy ones — whisper,
    /// ffmpeg, the AEC sidecar — and they are the load a live call must never
    /// have to share a Mac with: they run at background priority and are
    /// cancellable as a group the moment a recording starts.
    enum Role {
        case foreground
        case postProcessing
    }

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        /// Timed-out runs report this instead of a real exit status.
        static let timedOutCode: Int32 = -2
        var timedOut: Bool { exitCode == Self.timedOutCode }

        /// Cancelled to get out of a live call's way — NOT a failure of the
        /// work, and the caller must not record the stage as done on it.
        static let cancelledCode: Int32 = -3
        var wasCancelled: Bool { exitCode == Self.cancelledCode }

        /// Last part of stderr — enough to diagnose, bounded for the log.
        var stderrTail: String {
            String(stderr.suffix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Cancellable post-processing children

    /// A running child we may have to get rid of, and whether we did.
    private final class Entry {
        let process: Process
        var cancelled = false
        init(_ process: Process) { self.process = process }
    }

    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: Entry] = [:]
    /// Set when a cancellation actually hit something, cleared by the pipeline
    /// when it reads it. Without this a cancelled stage looks exactly like a
    /// stage that failed on its own, and gets recorded as done.
    private static var sawCancellation = false

    /// Terminate every running post-processing child. Called when a recording
    /// starts: whisper on the GPU and two ffmpegs are precisely the load that
    /// makes the speakers crackle during a call, and the pipeline is resumable
    /// by design, so stopping it costs only the stage in flight.
    static func cancelPostProcessing(reason: String) {
        registryLock.lock()
        let entries = Array(registry.values)
        for entry in entries { entry.cancelled = true }
        if !entries.isEmpty { sawCancellation = true }
        registryLock.unlock()

        guard !entries.isEmpty else { return }
        log("[ProcessRunner] Cancelling \(entries.count) post-processing child(ren): \(reason)")
        for entry in entries where entry.process.isRunning {
            entry.process.terminate()
            let pid = entry.process.processIdentifier
            // SIGTERM is a request; whisper mid-inference can sit on it, and
            // the whole point is to free the machine NOW.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if entry.process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// True if a cancellation has happened since this was last asked. Reading
    /// it clears it.
    static func consumeCancellation() -> Bool {
        registryLock.lock()
        defer { sawCancellation = false; registryLock.unlock() }
        return sawCancellation
    }

    @discardableResult
    static func run(_ path: String, args: [String], timeout: TimeInterval = 300,
                    role: Role = .foreground) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if role == .postProcessing {
            // Utility, not background: the same AEC run measured 6.9 s here and
            // 18.2 s at `.background` (2.6x), and with the recording gate this
            // load no longer overlaps a call at all — paying 2.6x on every
            // transcript to slow down work that already waits its turn is a bad
            // trade. `nice` below keeps it from preempting the user's own work.
            // Neither touches the audio path, which runs above both.
            process.qualityOfService = .utility
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outData = Data()
        var errData = Data()
        let ioQueue = DispatchQueue(label: "com.local.memorai.process-runner-io")
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            ioQueue.async { outData.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            ioQueue.async { errData.append(chunk) }
        }

        let entry = Entry(process)
        do {
            if role == .postProcessing {
                registryLock.lock()
                registry[ObjectIdentifier(entry)] = entry
                registryLock.unlock()
            }
            try process.run()
            if role == .postProcessing {
                setpriority(PRIO_PROCESS, id_t(process.processIdentifier), 10)
            }
        } catch {
            if role == .postProcessing {
                registryLock.lock()
                registry[ObjectIdentifier(entry)] = nil
                registryLock.unlock()
            }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Set on the timer queue, read here — behind a lock, or the caller can
        // see a stale value and report the child's status as a clean exit.
        let stateLock = NSLock()
        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            guard process.isRunning else { return }
            stateLock.lock()
            timedOut = true
            stateLock.unlock()
            process.terminate()
            // SIGTERM is a request. Escalate so the deadline is a real one:
            // this runs on the path that finishes a recording, and on quit a
            // child that ignores SIGTERM would hold the whole app open.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()
        stateLock.lock()
        let didTimeOut = timedOut
        stateLock.unlock()

        var wasCancelled = false
        if role == .postProcessing {
            registryLock.lock()
            wasCancelled = entry.cancelled
            registry[ObjectIdentifier(entry)] = nil
            registryLock.unlock()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let finalOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        let finalErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        let (collectedOut, collectedErr): (Data, Data) = ioQueue.sync {
            (outData + finalOut, errData + finalErr)
        }

        if didTimeOut {
            log("[ProcessRunner] ⏱ Timed out after \(Int(timeout))s: \((path as NSString).lastPathComponent)")
        }
        // Cancellation outranks the timeout in the report: the caller must be
        // able to tell "we stopped this on purpose" from "this wedged".
        let code: Int32
        if wasCancelled {
            code = Result.cancelledCode
        } else if didTimeOut {
            code = Result.timedOutCode
        } else {
            code = process.terminationStatus
        }
        return Result(exitCode: code,
                      stdout: String(data: collectedOut, encoding: .utf8) ?? "",
                      stderr: String(data: collectedErr, encoding: .utf8) ?? "")
    }
}
