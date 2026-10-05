import AVFoundation
import Foundation

/// A bounded handoff. The tap only copies PCM into owned, reusable buffers.
/// File creation, encoding, RMS and logging belong to the serial writer queue.
/// The small metadata lock is never held while a sink writes or finalizes.
final class MicCapturePipeline {
    private static let callbackLimits = [0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01]
    struct Stats {
        var buffers: UInt64 = 0
        var writtenFrames: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var gaps = 0
        var gapSeconds = 0.0
        var maxGapSeconds = 0.0
        var callbackMaxSeconds = 0.0
        var callbackHistogram = [UInt64](repeating: 0, count: 8)
        var lastBufferHost = 0.0
    }
    private struct Item {
        let index: Int
        let host: Double?
        let epoch: UInt64
        let lostSeconds: Double
    }
    private let lock = UnfairLock()
    private let queue = DispatchQueue(label: "com.local.memorai.mic-writer", qos: .userInitiated)
    private var source: DispatchSourceUserDataAdd!
    private let format: AVAudioFormat
    private let buffers: [AVAudioPCMBuffer]
    private var free: [Int]
    private var ready: [Item?]
    private var head = 0
    private var tail = 0
    private var count = 0
    private var accepting = true
    private var paused = false
    private var epoch: UInt64 = 0
    private var pendingLoss = 0.0
    private var expectedHost: Double?
    private var stats = Stats()
    private var reportedFormatError = false

    // Writer queue only.
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var framesWritten: AVAudioFramePosition = 0
    private var firstHost: Double?
    private var lastEndHost: Double?
    private var lastEpoch: UInt64?
    private var preservesGap: Bool
    private var segments: [MicRecorder.Segment] = []
    private var writeErrors = 0
    private var recoverySent = false
    private var silenceStart: Double?
    private var silent = false
    private let urlForPart: (Int, Bool) -> URL
    private let write: (AVAudioFile, AVAudioPCMBuffer) throws -> Void
    var onRecovery: (() -> Void)?
    var onSilenceChanged: ((Bool) -> Void)?

    init(format: AVAudioFormat, capacity: Int = 32, frameCapacity: AVAudioFrameCount = 8192,
         preservesGap: Bool = false, urlForPart: @escaping (Int, Bool) -> URL,
         write: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> Void = { try $0.write(from: $1) }) throws {
        guard capacity > 0, frameCapacity > 0, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              format.sampleRate > 0, format.channelCount > 0 else { throw MicRecorderError.noMicAvailable }
        self.format = format
        self.preservesGap = preservesGap
        self.urlForPart = urlForPart
        self.write = write
        self.buffers = try (0..<capacity).map { _ in
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                throw MicRecorderError.noMicAvailable
            }
            return b
        }
        self.free = Array((0..<capacity).reversed())
        self.ready = [Item?](repeating: nil, count: capacity)
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
    }

    func setPaused(_ value: Bool) {
        lock.withLock {
            guard value != paused else { return }
            paused = value
            epoch &+= 1
            expectedHost = nil // Intentional pauses are not capture dropouts.
            stats.lastBufferHost = ProcessInfo.processInfo.systemUptime
        }
    }

    /// `bufferSize` is a hint, so bounds and actual format are checked before copy.
    @discardableResult
    func submit(_ input: AVAudioPCMBuffer, host: Double?) -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let accepted = lock.withLock { () -> Bool in
            guard accepting, !paused else { return false }
            stats.lastBufferHost = started
            stats.buffers &+= 1
            let seconds = Double(input.frameLength) / input.format.sampleRate
            if let host, host.isFinite {
                if let expectedHost {
                    let gap = host - expectedHost
                    if gap > max(seconds, 0.005) {
                        stats.gaps += 1
                        stats.gapSeconds += gap
                        stats.maxGapSeconds = max(stats.maxGapSeconds, gap)
                    }
                }
                expectedHost = host + seconds
            }
            guard input.format == format, input.floatChannelData != nil else {
                stats.droppedFrames &+= UInt64(input.frameLength)
                pendingLoss += seconds
                if !reportedFormatError {
                    reportedFormatError = true
                    // Coalesced notification; recovery never tears down an engine here.
                    source.add(data: 1)
                }
                return false
            }
            var offset: AVAudioFrameCount = 0
            while offset < input.frameLength {
                let frames = min(input.frameLength - offset, buffers[0].frameCapacity)
                guard let index = free.popLast() else {
                    let remaining = input.frameLength - offset
                    stats.droppedFrames &+= UInt64(remaining)
                    pendingLoss += Double(remaining) / format.sampleRate
                    return false
                }
                let owned = buffers[index]
                owned.frameLength = frames
                for channel in 0..<Int(format.channelCount) {
                    memcpy(owned.floatChannelData![channel], input.floatChannelData![channel].advanced(by: Int(offset)),
                           Int(frames) * MemoryLayout<Float>.size)
                }
                ready[tail] = Item(index: index,
                    host: host.map { $0 + Double(offset) / format.sampleRate }, epoch: epoch, lostSeconds: pendingLoss)
                pendingLoss = 0
                tail = (tail + 1) % ready.count
                count += 1
                offset += frames
            }
            return true
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        lock.withLock {
            stats.callbackMaxSeconds = max(stats.callbackMaxSeconds, elapsed)
            stats.callbackHistogram[Self.callbackLimits.firstIndex(where: { elapsed <= $0 }) ?? 7] &+= 1
        }
        source.add(data: 1) // A partially accepted large buffer must also drain.
        return accepted
    }

    private func drain() {
        let badFormat = lock.withLock { reportedFormatError }
        if badFormat { requestRecovery() }
        while let item = lock.withLock({ () -> Item? in
            guard count > 0 else { return nil }
            let item = ready[head]
            ready[head] = nil
            head = (head + 1) % ready.count
            count -= 1
            return item
        }) {
            consume(item)
            lock.withLock { free.append(item.index) }
        }
    }

    private func consume(_ item: Item) {
        let buffer = buffers[item.index]
        let expectedEnd = firstHost.map { $0 + Double(framesWritten) / format.sampleRate } ?? lastEndHost
        let gap = max(0, item.host.flatMap { host in expectedEnd.map { host - $0 } } ?? item.lostSeconds)
        let split = lastEpoch != item.epoch || gap >= MicStitcher.minGapSeconds
        if file != nil, split {
            closeFile()
            preservesGap = true
        }
        do {
            if file == nil {
                let aac = format.channelCount <= 2
                let url = urlForPart(segments.count, aac)
                let settings: [String: Any] = aac ? [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVEncoderBitRateKey: 32000 * Int(format.channelCount),
                ] : [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
                fileURL = url
                framesWritten = 0
                firstHost = item.host
            }
            // Missing host times cannot describe a gap to the stitcher; retain
            // explicitly counted overflow silence in the file in that rare case.
            if !split, gap > 0.005 || item.lostSeconds > 0 { try writeSilence(max(gap, item.lostSeconds)) }
            if split, item.lostSeconds > 0, item.host == nil { try writeSilence(item.lostSeconds) }
            if let file {
                try write(file, buffer)
                framesWritten += Int64(buffer.frameLength)
                lock.withLock { stats.writtenFrames &+= UInt64(buffer.frameLength) }
            }
            writeErrors = 0
            lastEpoch = item.epoch
            lastEndHost = item.host.map { $0 + Double(buffer.frameLength) / format.sampleRate }
            updateSilence(buffer)
        } catch {
            writeErrors += 1
            log("[MicRecorder] Write error (\(writeErrors)/5): \(error.localizedDescription)")
            if writeErrors >= 5 { requestRecovery() }
        }
    }

    private func requestRecovery() {
        guard !recoverySent else { return }
        recoverySent = true
        onRecovery?() // Caller posts a generation-checked main-queue event.
    }

    private func writeSilence(_ seconds: Double) throws {
        guard seconds.isFinite, seconds > 0, let file,
              let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return }
        var remaining = Int64((seconds * format.sampleRate).rounded())
        while remaining > 0 {
            zeros.frameLength = AVAudioFrameCount(min(remaining, 8192))
            try write(file, zeros)
            framesWritten += Int64(zeros.frameLength)
            remaining -= Int64(zeros.frameLength)
        }
    }

    private func closeFile() {
        guard let current = file, let url = fileURL else { return }
        // AAC length before close omits a pending encoder packet. Source
        // frame accounting preserves the segment origin/duration exactly.
        let frames = framesWritten
        _ = current
        file = nil
        if frames > 0 {
            segments.append(.init(url: url, firstBufferHostSeconds: firstHost,
                                  frameCount: frames, sampleRate: format.sampleRate,
                                  preservesGap: preservesGap))
        } else { try? FileManager.default.removeItem(at: url) }
        firstHost = nil
    }

    /// Producer is disabled before draining. No tap owns a sink or waits for IO.
    /// Stop while paused deliberately does not append the trailing pause.
    func finish() -> (segments: [MicRecorder.Segment], stats: Stats) {
        lock.withLock { accepting = false }
        source.cancel()
        return queue.sync {
            drain()
            let trailingLoss = lock.withLock { () -> Double in
                defer { pendingLoss = 0 }
                return pendingLoss
            }
            do { try writeSilence(trailingLoss) } catch { log("[MicRecorder] Could not retain dropped tail: \(error.localizedDescription)") }
            closeFile()
            return (segments, lock.withLock { stats })
        }
    }

    private func updateSilence(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { sum += data[channel][frame] * data[channel][frame] }
        }
        let rms = sqrtf(sum / Float(buffer.frameLength * format.channelCount))
        let now = ProcessInfo.processInfo.systemUptime
        if rms < 0.001 {
            if silenceStart == nil { silenceStart = now }
            if !silent, now - (silenceStart ?? now) >= 90 {
                silent = true
                onSilenceChanged?(true)
            }
        } else {
            silenceStart = nil
            if silent { silent = false; onSilenceChanged?(false) }
        }
    }

    var snapshot: Stats { lock.withLock { stats } }
}
