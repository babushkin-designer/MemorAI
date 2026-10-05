import Foundation
import AVFoundation
import ObjCTry

/// Native microphone capture. The tap hands owned PCM to a bounded writer;
/// encoding, disk IO and silence analysis never execute in the tap callback.
/// Main queue owns the engine; each generation owns its own pipeline.
class MicRecorder {
    struct Segment {
        let url: URL
        /// Host-clock seconds of this segment's first buffer — the stitcher
        /// derives the silence needed to bridge the engine restart from it.
        let firstBufferHostSeconds: Double?
        /// Frames written, or -1 for a part file picked up off disk after a
        /// crash — unknown length, which is not the same as no audio.
        let frameCount: AVAudioFramePosition
        let sampleRate: Double

        /// True for measured capture gaps and explicit pauses; never truncate them.
        var preservesGap: Bool = false

        var duration: Double {
            sampleRate > 0 && frameCount > 0 ? Double(frameCount) / sampleRate : 0
        }
        var isEmpty: Bool { frameCount == 0 }

        /// A segment the recorder never got to close (the process was killed
        /// mid-call). Nothing is known about it beyond where it is, so the
        /// stitcher joins it without trying to bridge a gap.
        static func recovered(url: URL) -> Segment {
            Segment(url: url, firstBufferHostSeconds: nil, frameCount: -1, sampleRate: 0)
        }
    }

    private let outputURL: URL
    private let lock = UnfairLock()
    private var _isRecording = false
    private var _isPaused = false
    private var _segments: [Segment] = []
    private var _firstHost: Double?
    private var engine: AVAudioEngine?
    private var pipeline: MicCapturePipeline?
    private var generation: UInt64 = 0
    private var watchdogTimer: Timer?
    private var configChangeObserver: NSObjectProtocol?
    private var restartPending = false
    private var preserveNextGap = false
    private var lastStartHost = 0.0
    private var consecutiveRecoveries = 0

    var onSilenceChanged: ((Bool) -> Void)?
    /// Called when the microphone cannot recover. Other tracks may continue.
    var onFatalError: (() -> Void)?
    var segments: [Segment] { lock.withLock { _segments } }
    var firstBufferHostSeconds: Double? { lock.withLock { _firstHost } }
    var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set {
            lock.withLock {
                guard _isPaused != newValue else { return }
                _isPaused = newValue
                preserveNextGap = true
                pipeline?.setPaused(newValue)
                if !newValue { lastStartHost = ProcessInfo.processInfo.systemUptime }
            }
        }
    }

    init(outputURL: URL) { self.outputURL = outputURL }

    func start() throws {
        guard !lock.withLock({ _isRecording }) else { return }
        lock.withLock { _isRecording = true }
        do { try startEngine() } catch {
            lock.withLock { _isRecording = false }
            closeEngine()
            throw error
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkWatchdog() }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
        log("[MicRecorder] Recording started → \(outputURL.lastPathComponent)")
    }

    func stop() {
        let running = lock.withLock { () -> Bool in
            defer { _isRecording = false }
            return _isRecording
        }
        guard running else { return }
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        closeEngine()
        log("[MicRecorder] Recording stopped (\(segments.count) segment(s))")
    }

    private func startEngine() throws {
        generation &+= 1
        let currentGeneration = generation
        var swiftError: Error?
        var raised: NSError?
        let completed = MEMRunCatchingExceptions({
            do {
                let engine = AVAudioEngine()
                self.engine = engine // Retain even if installation/start raises.
                let format = engine.inputNode.outputFormat(forBus: 0)
                let baseIndex = self.segments.count + 1
                let writer = try MicCapturePipeline(format: format,
                    preservesGap: self.preserveNextGap || !self.segments.isEmpty,
                    urlForPart: { [outputURL = self.outputURL] offset, aac in
                        outputURL.deletingPathExtension()
                            .appendingPathExtension("part\(baseIndex + offset)")
                            .appendingPathExtension(aac ? "m4a" : "caf")
                    })
                writer.setPaused(self.isPaused)
                writer.onRecovery = { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.generation == currentGeneration,
                              self.lock.withLock({ self._isRecording }) else { return }
                        self.recoverMicrophone()
                    }
                }
                writer.onSilenceChanged = { [weak self] silent in
                    DispatchQueue.main.async {
                        guard let self, self.generation == currentGeneration,
                              self.lock.withLock({ self._isRecording }) else { return }
                        self.onSilenceChanged?(silent)
                    }
                }
                self.pipeline = writer
                // nil avoids applying a stale probed format to a reconfigured bus.
                // Actual buffers are checked against the pool before any copy.
                engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, when in
                    writer.submit(buffer, host: when.isHostTimeValid
                                  ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil)
                }
                try engine.start()
                self.lastStartHost = ProcessInfo.processInfo.systemUptime
                self.installConfigChangeObserver(for: engine)
                // Silence flags from the previous generation must not survive
                // after its analysis state has been discarded.
                self.onSilenceChanged?(false)
                log("[MicRecorder] Engine started: \(Int(format.sampleRate))Hz/\(format.channelCount)ch, bounded writer")
            } catch { swiftError = error }
        }, &raised)
        if let swiftError { throw swiftError }
        if !completed { throw raised ?? MicRecorderError.noMicAvailable as NSError }
    }

    private func closeEngine() {
        generation &+= 1 // Invalidate every pending callback/recovery notification.
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let engine {
            var raised: NSError?
            _ = MEMRunCatchingExceptions({
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }, &raised)
            if let raised { log("[MicRecorder] Engine teardown: \(raised.localizedDescription)") }
        }
        engine = nil
        if let writer = pipeline {
            let result = writer.finish()
            lock.withLock {
                if _firstHost == nil { _firstHost = result.segments.first?.firstBufferHostSeconds }
                _segments.append(contentsOf: result.segments)
            }
            let s = result.stats
            log(String(format: "[MicRecorder] Tap health — %llu buffers, %d capture gap(s), %.3fs missing, max %.3fs;"
                       + " %llu dropped frames; callback max %.3fms, histogram %@",
                       s.buffers, s.gaps, s.gapSeconds, s.maxGapSeconds, s.droppedFrames,
                       s.callbackMaxSeconds * 1000, s.callbackHistogram.description))
            pipeline = nil
        }
    }

    private func recoverMicrophone() {
        if (pipeline?.snapshot.writtenFrames ?? 0) > 0 { consecutiveRecoveries = 0 }
        consecutiveRecoveries += 1
        guard consecutiveRecoveries <= 3, restartEngine() else {
            log("[MicRecorder] Persistent capture/write failure — retaining closed mic parts")
            stop()
            onFatalError?()
            return
        }
    }

    @discardableResult
    private func restartEngine() -> Bool {
        closeEngine()
        do { try startEngine(); return true } catch {
            closeEngine()
            lastStartHost = ProcessInfo.processInfo.systemUptime
            log("[MicRecorder] Engine restart failed: \(error.localizedDescription)")
            return false
        }
    }

    private func installConfigChangeObserver(for engine: AVAudioEngine) {
        // Return immediately: teardown in AVFAudio's notification queue deadlocked
        // real recordings. Only our own engine's notifications are relevant.
        let currentGeneration = generation
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.scheduleConfigChangeRestart()
            }
        }
    }

    private func scheduleConfigChangeRestart() {
        guard lock.withLock({ _isRecording }), !restartPending else { return }
        restartPending = true
        let currentGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.generation == currentGeneration,
                  self.lock.withLock({ self._isRecording }) else { return }
            _ = self.restartEngine()
        }
    }

    private func checkWatchdog() {
        guard lock.withLock({ _isRecording && !_isPaused }), !restartPending else { return }
        let last = max(lastStartHost, pipeline?.snapshot.lastBufferHost ?? 0)
        guard ProcessInfo.processInfo.systemUptime - last > 10 else { return }
        log("[MicRecorder] No buffers for >10s — restarting engine")
        recoverMicrophone()
    }
}

enum MicRecorderError: Error, LocalizedError {
    case noMicAvailable
    var errorDescription: String? { "No microphone available or native PCM format invalid" }
}
