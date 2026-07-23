import AVFoundation
import Carbon.HIToolbox
import Cocoa

enum DictationState {
    case idle
    case listening
    case processing
}

/// System-wide voice dictation (SuperWhisper replacement):
/// tapping the fn key toggles mic recording; on stop the audio is
/// transcribed with whisper and the text is pasted into the frontmost app
/// via the clipboard + synthetic Cmd-V (requires Accessibility permission).
/// A "tap" is fn pressed and released with no other key in between, so
/// fn-combos (fn+arrows etc.) don't trigger dictation. The system's own
/// fn-key action (emoji/dictation) must be set to "Do Nothing".
///
/// Transcription goes through a lazily-started whisper-server that keeps the
/// model loaded between dictations (fast repeat use); the server is shut down
/// after 15 minutes of inactivity to release RAM. Falls back to one-shot
/// whisper-cli if the server can't be started.
class DictationManager {
    var onStateChange: ((DictationState) -> Void)?
    private(set) var state: DictationState = .idle {
        didSet {
            let s = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
        }
    }

    private let ffmpegPath: String = {
        for path in ["/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "ffmpeg"
    }()

    private static let serverCandidates = [
        "/opt/homebrew/bin/whisper-server",
        "/usr/local/bin/whisper-server",
        "/opt/local/bin/whisper-server",
    ]

    private let serverPort = 12384
    private let serverIdleShutdown: TimeInterval = 15 * 60
    private let maxRecordingSeconds: TimeInterval = 600

    private var eventMonitors: [Any] = []
    private var fnDown = false
    private var fnUsedAsCombo = false

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var maxDurationTimer: Timer?

    private var serverProcess: Process?
    private var serverLang: String?
    private var serverModel: String?
    private var idleShutdownWork: DispatchWorkItem?

    private let workQueue = DispatchQueue(label: "com.local.memorai.dictation", qos: .userInitiated)

    /// Persistent dictation history (menu re-copy; never lose text if paste misses).
    let history = DictationHistory(outputPath: SettingsManager.shared.outputPath)

    private var language: String { SettingsManager.shared.whisperLanguage }

    // MARK: - fn-key monitoring

    func enable() {
        guard eventMonitors.isEmpty else { return }

        if !AXIsProcessTrusted() {
            log("[Dictation] ⚠️ Accessibility permission missing — global fn monitoring will not receive events")
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown],
                                                           handler: { [weak self] event in
            self?.handleKeyEvent(event)
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown],
                                                          handler: { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }) {
            eventMonitors.append(monitor)
        }
        log("[Dictation] fn-key monitor installed (\(eventMonitors.count) monitors)")
    }

    func disable() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
        fnDown = false
        if state == .listening { cancelRecording() }
        log("[Dictation] fn-key monitor removed")
    }

    /// Toggle on a clean fn tap: fn down → fn up with no other key pressed
    /// in between. Any keyDown or other modifier while fn is held marks it
    /// as a combo and suppresses the toggle.
    private func handleKeyEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard event.keyCode == UInt16(kVK_Function) else {
                if fnDown { fnUsedAsCombo = true }
                return
            }
            if event.modifierFlags.contains(.function) {
                fnDown = true
                fnUsedAsCombo = false
            } else if fnDown {
                fnDown = false
                if !fnUsedAsCombo {
                    DispatchQueue.main.async { [weak self] in self?.toggle() }
                }
            }
        case .keyDown:
            if fnDown { fnUsedAsCombo = true }
        default:
            break
        }
    }

    /// Full teardown for app quit: hotkey, recording, warm server.
    func shutdown() {
        disable()
        stopServer()
    }

    // MARK: - Toggle flow

    func toggle() {
        switch state {
        case .idle: startListening()
        case .listening: stopListeningAndTranscribe()
        case .processing: break // ignore presses while transcribing
        }
    }

    private func startListening() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_dictation_\(UUID().uuidString).m4a")
        do {
            try startEngine(outputURL: url)
        } catch {
            log("[Dictation] ❌ Mic start failed: \(error.localizedDescription)")
            NSSound(named: "Basso")?.play()
            return
        }
        recordingURL = url
        state = .listening
        NSSound(named: "Pop")?.play()
        log("[Dictation] Listening…")

        // Warm up the server in parallel with the user speaking.
        let lang = language
        workQueue.async { [weak self] in _ = self?.ensureServer(lang: lang) }

        let timer = Timer(timeInterval: maxRecordingSeconds, repeats: false) { [weak self] _ in
            log("[Dictation] ⚠️ Max recording length reached — stopping")
            self?.stopListeningAndTranscribe()
        }
        RunLoop.main.add(timer, forMode: .common)
        maxDurationTimer = timer
    }

    private func stopListeningAndTranscribe() {
        guard state == .listening, let url = recordingURL else { return }
        stopEngine()
        state = .processing
        NSSound(named: "Pop")?.play()

        let lang = language
        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                try? FileManager.default.removeItem(at: url)
                self.state = .idle
            }
            guard let text = self.transcribe(m4aURL: url, lang: lang), !text.isEmpty else {
                log("[Dictation] No speech recognized")
                DispatchQueue.main.async { NSSound(named: "Basso")?.play() }
                return
            }
            log("[Dictation] Recognized \(text.count) chars")
            self.history.add(text)
            DispatchQueue.main.async { self.paste(text) }
        }
    }

    private func cancelRecording() {
        stopEngine()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        state = .idle
    }

    // MARK: - Recording (native-format AAC, same approach as MicRecorder)

    private func startEngine(outputURL: URL) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicRecorderError.noMicAvailable
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32000 * Int(format.channelCount),
        ]
        let file = try AVAudioFile(forWriting: outputURL, settings: fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            try? self.audioFile?.write(from: buffer)
        }

        try engine.start()
        self.engine = engine
        self.audioFile = file
    }

    private func stopEngine() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil
    }

    // MARK: - Transcription

    private func transcribe(m4aURL: URL, lang: String) -> String? {
        let wavURL = m4aURL.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let convert = runProcess(ffmpegPath, args: [
            "-y", "-nostats", "-loglevel", "error", "-i", m4aURL.path,
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path,
        ], timeout: 60)
        guard convert.exitCode == 0 else {
            log("[Dictation] ❌ ffmpeg convert failed (exit \(convert.exitCode)): \(convert.stderr.suffix(300))")
            return nil
        }

        var text: String?
        if ensureServer(lang: lang) {
            text = serverInference(wavURL: wavURL)
            scheduleIdleShutdown()
        }
        if text == nil {
            log("[Dictation] Server path unavailable — falling back to whisper-cli")
            text = cliInference(wavURL: wavURL, lang: lang)
        }
        return text.map(Self.cleanDictationText)
    }

    /// Flatten whisper output into paste-ready text: strip non-speech
    /// annotations and hallucinated subtitle outros, join lines into a
    /// single space-separated string.
    static func cleanDictationText(_ raw: String) -> String {
        let parts = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !Transcriber.isNonSpeechAnnotation($0)
                      && !Transcriber.isHallucinatedSegment($0) }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcriber.stripTrailingHallucinations(joined)
    }

    // MARK: - whisper-server lifecycle

    private var resolvedServerPath: String? {
        Self.serverCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Start (or reuse) a warm whisper-server with the current model/language.
    /// Returns true when the server answers on its port.
    private func ensureServer(lang: String) -> Bool {
        let modelFile = Transcriber.shared.resolvedModelPath
        guard FileManager.default.fileExists(atPath: modelFile) else { return false }

        if let p = serverProcess, p.isRunning, serverLang == lang, serverModel == modelFile {
            return pingServer(timeout: 2)
        }
        stopServer()

        guard let serverPath = resolvedServerPath else {
            log("[Dictation] whisper-server not found")
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: serverPath)
        proc.arguments = [
            "-m", modelFile, "-l", lang,
            "--host", "127.0.0.1", "--port", String(serverPort),
            "-t", "4", "-sns",
            // Same anti-hallucination decoder thresholds as the call path.
            "-et", "2.2", "-lpt", "-0.5",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            log("[Dictation] ❌ whisper-server launch failed: \(error.localizedDescription)")
            return false
        }
        serverProcess = proc
        serverLang = lang
        serverModel = modelFile
        log("[Dictation] whisper-server starting (model: \((modelFile as NSString).lastPathComponent))…")

        // Model load takes a few seconds; poll until the port answers.
        for _ in 0..<120 {
            if !proc.isRunning {
                log("[Dictation] ❌ whisper-server exited during startup")
                serverProcess = nil
                return false
            }
            if pingServer(timeout: 1) {
                log("[Dictation] whisper-server ready on :\(serverPort)")
                return true
            }
            usleep(500_000)
        }
        log("[Dictation] ❌ whisper-server did not become ready in 60s")
        stopServer()
        return false
    }

    private func stopServer() {
        idleShutdownWork?.cancel()
        idleShutdownWork = nil
        if let p = serverProcess, p.isRunning {
            p.terminate()
            log("[Dictation] whisper-server stopped")
        }
        serverProcess = nil
        serverLang = nil
        serverModel = nil
    }

    private func scheduleIdleShutdown() {
        idleShutdownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .idle else { return }
            log("[Dictation] Idle for \(Int(self.serverIdleShutdown / 60)) min — releasing whisper-server")
            self.stopServer()
        }
        idleShutdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + serverIdleShutdown, execute: work)
    }

    /// Any HTTP response on the port means the server finished loading the model.
    private func pingServer(timeout: TimeInterval) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/") else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        var ok = false
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = response is HTTPURLResponse
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + timeout + 1)
        return ok
    }

    private func serverInference(wavURL: URL) -> String? {
        guard let audioData = try? Data(contentsOf: wavURL),
              let url = URL(string: "http://127.0.0.1:\(serverPort)/inference") else { return nil }

        let boundary = "memorai-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("temperature", "0.0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        var text: String?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error = error {
                log("[Dictation] ❌ Server inference failed: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                log("[Dictation] ❌ Server inference HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let t = obj["text"] as? String {
                text = t
            }
        }.resume()
        _ = sema.wait(timeout: .now() + 310)
        return text
    }

    private func cliInference(wavURL: URL, lang: String) -> String? {
        guard let whisperExec = Transcriber.shared.resolvedWhisperPath else { return nil }
        let modelFile = Transcriber.shared.resolvedModelPath
        let outBase = wavURL.deletingPathExtension()
        let txtURL = outBase.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: txtURL) }

        let result = runProcess(whisperExec, args: [
            "-m", modelFile, "-l", lang, "-sns",
            "-et", "2.2", "-lpt", "-0.5",
            "-otxt", "-of", outBase.path, wavURL.path,
        ], timeout: 300)
        guard result.exitCode == 0 else {
            log("[Dictation] ❌ whisper-cli failed (exit \(result.exitCode)): \(result.stderr.suffix(300))")
            return nil
        }
        return try? String(contentsOf: txtURL, encoding: .utf8)
    }

    // MARK: - Paste

    /// Put text on the clipboard and synthesize Cmd-V into the frontmost app.
    /// The previous clipboard string is restored shortly after.
    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        if let previous = previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let pb = NSPasteboard.general
                if pb.string(forType: .string) == text {
                    pb.clearContents()
                    pb.setString(previous, forType: .string)
                }
            }
        }
    }

    // MARK: - Subprocess helper (drains pipes; see Transcriber.runProcess)

    private struct ProcessResult {
        let exitCode: Int32
        let stderr: String
    }

    private func runProcess(_ path: String, args: [String], timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        var stderrData = Data()
        let ioQueue = DispatchQueue(label: "com.local.memorai.dictation-io")
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            ioQueue.async { stderrData.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(exitCode: -1, stderr: error.localizedDescription)
        }

        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let finalErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errData: Data = ioQueue.sync { stderrData + finalErr }

        return ProcessResult(
            exitCode: timedOut ? -2 : process.terminationStatus,
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
