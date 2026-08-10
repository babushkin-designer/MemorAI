import Foundation

/// One place to run a subprocess correctly.
///
/// Both pipes are drained as data arrives: a child that fills the 64 KB pipe
/// buffer while the parent sits in `waitUntilExit()` blocks forever, and
/// ffmpeg's stderr does exceed that on long inputs. Every subprocess also gets
/// a deadline — post-processing now runs on the path that finishes a recording,
/// so a wedged child would strand the session (and, on quit, the app).
enum ProcessRunner {

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        /// Timed-out runs report this instead of a real exit status.
        static let timedOutCode: Int32 = -2
        var timedOut: Bool { exitCode == Self.timedOutCode }

        /// Last part of stderr — enough to diagnose, bounded for the log.
        var stderrTail: String {
            String(stderr.suffix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    static func run(_ path: String, args: [String], timeout: TimeInterval = 300) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

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

        do {
            try process.run()
        } catch {
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
        return Result(exitCode: didTimeOut ? Result.timedOutCode : process.terminationStatus,
                      stdout: String(data: collectedOut, encoding: .utf8) ?? "",
                      stderr: String(data: collectedErr, encoding: .utf8) ?? "")
    }
}
