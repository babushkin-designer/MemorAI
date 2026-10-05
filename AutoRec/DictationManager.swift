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
        for path in ["/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            where FileManager.default.fileExists(atPath: path) {
            return path
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

    private let callGate = CallWorkGate()
    private let pendingStore: DictationPendingStore

    init(pendingStore: DictationPendingStore? = nil) {
        self.pendingStore = pendingStore ?? DictationPendingStore(directory:
            URL(fileURLWithPath: SettingsManager.shared.outputPath).appendingPathComponent("dictation-pending"))
    }
    // Only workQueue touches deferred work and the server language/model.
    private var pendingDictations: [(URL, String)] = []
    private var serverLang: String?
    private var serverModel: String?
    private var idleShutdownWork: DispatchWorkItem?

    /// Set while a call is being recorded. Dictation is a THIRD audio engine on
    /// the same input device plus a resident whisper model, and a call already
    /// has two recorders and a hard real-time deadline. Its fn-tap is ignored
    /// for the duration and the warm server is released.
    private var workBlocked: Bool { callGate.isBlocked }

    private let workQueue = DispatchQueue(label: "com.local.memorai.dictation", qos: .userInitiated)

    /// Persistent dictation history (menu re-copy; never lose text if paste misses).
    let history = DictationHistory(outputPath: SettingsManager.shared.outputPath)

    private var language: String { SettingsManager.shared.whisperLanguage }

    // MARK: - fn-key monitoring

    func enable() {
        guard eventMonitors.isEmpty else { return }
        callGate.setEnabled(true)

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
        let restored = pendingStore.pending()
        if !restored.isEmpty, state == .idle { state = .processing }
        workQueue.async { [weak self] in
            guard let self else { return }
            for job in restored where !self.pendingDictations.contains(where: { $0.0 == job.0 }) {
                self.pendingDictations.append(job)
            }
            self.resumePendingDictations()
        }
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
        callGate.setEnabled(false) // Refuse warmups until explicitly enabled again.
        disable()
        stopServer()
    }

    // MARK: - Toggle flow

    /// Called when a call recording starts and stops.
    func setCallActive(_ active: Bool) {
        guard callGate.isActive != active else { return }
        callGate.setActive(active) // Refuse queued warmups BEFORE flushing the mic.
        if active {
            if state == .listening { stopListeningAndTranscribe() }
            stopServer()
            log("[Dictation] Disabled while a call records (pending speech deferred)")
        } else {
            log("[Dictation] Enabled again (call ended)")
            workQueue.async { [weak self] in self?.resumePendingDictations() }
        }
    }

    func toggle() {
        if workBlocked, state == .idle {
            log("[Dictation] Ignored — a call is being recorded")
            NSSound(named: "Basso")?.play()
            return
        }
        switch state {
        case .idle: startListening()
        case .listening: stopListeningAndTranscribe()
        case .processing: break // ignore presses while transcribing
        }
    }

    private func startListening() {
        let url: URL
        do {
            url = try pendingStore.recordingURL()
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
        let retainedURL: URL
        do { retainedURL = try pendingStore.persist(url, language: lang) } catch {
            retainedURL = url
            log("[Dictation] Could not persist pending speech; original retained: \(error.localizedDescription)")
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            self.pendingDictations.append((retainedURL, lang))
            self.resumePendingDictations()
        }
    }

    /// Keep the source audio until recognition succeeds or fails independently
    /// of a call. A recording gate interruption must not discard spoken words.
    private func resumePendingDictations() {
        while !workBlocked, let (url, lang) = pendingDictations.first {
            switch transcribe(m4aURL: url, lang: lang) {
            case .done(let text):
                pendingDictations.removeFirst()
                history.add(text)
                pendingStore.remove(url)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.workBlocked else { return }
                    self.paste(text)
                }
            case .paused:
                // A call can end before the cancelled child returns. Ensure
                // pending work is retried even without another gate transition.
                if !workBlocked {
                    workQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.resumePendingDictations() }
                }
                return
            case .failed:
                guard !workBlocked else { return }
                pendingDictations.removeFirst()
                log("[Dictation] Recognition failed — source retained for retry")
            }
        }
        if pendingDictations.isEmpty {
            DispatchQueue.main.async { [weak self] in
                if self?.state == .processing { self?.state = .idle }
            }
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

    private func transcribe(m4aURL: URL, lang: String) -> Transcriber.StageOutcome<String> {
        guard !workBlocked else { return .paused }
        let wavURL = m4aURL.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let convert = runProcess(ffmpegPath, args: [
            "-y", "-nostats", "-loglevel", "error", "-i", m4aURL.path,
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path,
        ], timeout: 60)
        guard !convert.wasCancelled, !workBlocked else { return .paused }
        guard convert.exitCode == 0 else {
            log("[Dictation] ❌ ffmpeg convert failed (exit \(convert.exitCode)): \(convert.stderr.suffix(300))")
            return .failed
        }

        var text: String?
        if ensureServer(lang: lang) {
            text = serverInference(wavURL: wavURL)
            scheduleIdleShutdown()
        }
        if let text, !text.isEmpty { return Self.recognitionOutcome(text) }
        if workBlocked { return .paused }
        if text == nil {
            log("[Dictation] Server path unavailable — falling back to whisper-cli")
            return cliInference(wavURL: wavURL, lang: lang)
        }
        return Self.recognitionOutcome(text)
    }

    private static func recognitionOutcome(_ text: String?) -> Transcriber.StageOutcome<String> {
        guard let text else { return .failed }
        let cleaned = cleanDictationText(text)
        return cleaned.isEmpty ? .failed : .done(cleaned)
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
        guard !workBlocked else { return false }
        let modelFile = Transcriber.shared.resolvedModelPath
        guard FileManager.default.fileExists(atPath: modelFile) else { return false }

        if let p = callGate.server, p.isRunning, serverLang == lang, serverModel == modelFile {
            return pingServer(timeout: 2)
        }
        callGate.stopServer()

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
            guard try callGate.launch({ try proc.run(); return proc }) != nil else { return false }
        } catch {
            log("[Dictation] ❌ whisper-server launch failed: \(error.localizedDescription)")
            return false
        }
        serverLang = lang
        serverModel = modelFile
        log("[Dictation] whisper-server starting (model: \((modelFile as NSString).lastPathComponent))…")

        // Model load takes a few seconds; poll until the port answers.
        for _ in 0..<120 {
            if workBlocked || callGate.server !== proc { return false }
            if !proc.isRunning {
                log("[Dictation] ❌ whisper-server exited during startup")
                callGate.stopServer()
                return false
            }
            if pingServer(timeout: 1) {
                log("[Dictation] whisper-server ready on :\(serverPort)")
                return true
            }
            usleep(500_000)
        }
        log("[Dictation] ❌ whisper-server did not become ready in 60s")
        callGate.stopServer()
        return false
    }

    private func stopServer() {
        // Main-queue lifecycle, process ownership synchronized with launch.
        idleShutdownWork?.cancel()
        idleShutdownWork = nil
        callGate.stopServer()
    }

    private func scheduleIdleShutdown() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.workBlocked else { return }
            self.idleShutdownWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .idle else { return }
                self.callGate.stopServer()
            }
            self.idleShutdownWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.serverIdleShutdown, execute: work)
        }
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
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("temperature", "0.0")
        let fileHeader = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n"
        body.append(Data(fileHeader.utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

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

    private func cliInference(wavURL: URL, lang: String) -> Transcriber.StageOutcome<String> {
        guard let whisperExec = Transcriber.shared.resolvedWhisperPath else { return .failed }
        let modelFile = Transcriber.shared.resolvedModelPath
        let outBase = wavURL.deletingPathExtension()
        let txtURL = outBase.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: txtURL) }

        let result = runProcess(whisperExec, args: [
            "-m", modelFile, "-l", lang, "-sns",
            "-et", "2.2", "-lpt", "-0.5",
            "-otxt", "-of", outBase.path, wavURL.path,
        ], timeout: 300)
        guard !result.wasCancelled, !workBlocked else { return .paused }
        guard result.exitCode == 0 else {
            log("[Dictation] ❌ whisper-cli failed (exit \(result.exitCode)): \(result.stderr.suffix(300))")
            return .failed
        }
        return Self.recognitionOutcome(try? String(contentsOf: txtURL, encoding: .utf8))
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

    // MARK: - Subprocess helper

    /// Dictation conversion/inference shares the recording gate. Interrupted
    /// work keeps its source file and is retried after the call.
    private func runProcess(_ path: String, args: [String], timeout: TimeInterval) -> ProcessRunner.Result {
        ProcessRunner.run(path, args: args, timeout: timeout, role: .postProcessing)
    }
}
