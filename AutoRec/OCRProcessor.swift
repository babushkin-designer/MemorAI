import Foundation

/// OCR via a persistent RapidOCR (ONNX) Python sidecar.
///
/// Apple Vision (`VNRecognizeTextRequest`) hangs indefinitely on macOS 27 beta,
/// so text recognition is delegated to an out-of-process daemon that loads the
/// recognition model once and answers one image path per line. The serial
/// `queue` guarantees one in-flight request at a time, matching the sidecar's
/// request/response protocol.
class OCRProcessor {
    private let queue = DispatchQueue(label: "com.memorai.ocr", qos: .background)

    // Candidate interpreters that may have rapidocr_onnxruntime installed.
    private static let pythonCandidates = [
        "/opt/homebrew/bin/python3",  // Apple Silicon Homebrew
        "/usr/local/bin/python3",     // Intel Homebrew
    ]

    private var sidecar: Process?
    private var sidecarIn: FileHandle?
    private var sidecarOut: FileHandle?
    private var sidecarFailed = false
    private var outBuffer = Data()

    func process(imageURL: URL, jsonlURL: URL, baseMeta: [String: Any]) {
        queue.async {
            var record = baseMeta

            if let text = self.recognize(imageURL: imageURL), !text.isEmpty {
                record["ocr_text"] = text

                let extracted = Self.extractStructuredData(from: text)
                if !extracted.urls.isEmpty { record["urls"] = extracted.urls }
                if !extracted.emails.isEmpty { record["emails"] = extracted.emails }
                if !extracted.phones.isEmpty { record["phones"] = extracted.phones }
                if !extracted.paths.isEmpty { record["file_paths"] = extracted.paths }
            }

            JSONLWriter.shared.append(record, to: jsonlURL)
        }
    }

    // MARK: - Sidecar

    /// Sends an image path to the sidecar and returns the recognized text.
    /// Returns nil if OCR is unavailable (sidecar could not start). Must be
    /// called on `queue`.
    private func recognize(imageURL: URL) -> String? {
        guard let (stdin, stdout) = ensureSidecar() else { return nil }

        guard let line = (imageURL.path + "\n").data(using: .utf8) else { return nil }
        do {
            try stdin.write(contentsOf: line)
        } catch {
            log("[OCR] sidecar write failed: \(error) — restarting")
            teardownSidecar()
            return nil
        }

        guard let reply = readLine(from: stdout) else {
            log("[OCR] sidecar produced no reply — restarting")
            teardownSidecar()
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            return nil
        }
        return obj["text"] as? String ?? ""
    }

    /// Lazily launches the sidecar and waits for its readiness line.
    private func ensureSidecar() -> (FileHandle, FileHandle)? {
        if let stdin = sidecarIn, let stdout = sidecarOut, sidecar?.isRunning == true {
            return (stdin, stdout)
        }
        if sidecarFailed { return nil }

        guard let python = Self.pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let script = Self.sidecarScriptPath() else {
            log("[OCR] no python interpreter or sidecar script found — OCR disabled")
            sidecarFailed = true
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script]
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            log("[OCR] sidecar launch failed: \(error) — OCR disabled")
            sidecarFailed = true
            return nil
        }

        let stdin = inPipe.fileHandleForWriting
        let stdout = outPipe.fileHandleForReading
        outBuffer.removeAll()

        // Wait for the readiness handshake (model load can take a few seconds).
        guard let ready = readLine(from: stdout),
              let obj = try? JSONSerialization.jsonObject(with: ready) as? [String: Any],
              obj["ready"] as? Bool == true else {
            log("[OCR] sidecar did not report ready — OCR disabled")
            proc.terminate()
            sidecarFailed = true
            return nil
        }

        sidecar = proc
        sidecarIn = stdin
        sidecarOut = stdout
        log("[OCR] RapidOCR sidecar ready (\(python))")
        return (stdin, stdout)
    }

    private func teardownSidecar() {
        sidecar?.terminate()
        sidecar = nil
        sidecarIn = nil
        sidecarOut = nil
        outBuffer.removeAll()
    }

    /// Blocking read of one newline-delimited line from a pipe, buffering any
    /// surplus bytes for the next call.
    private func readLine(from handle: FileHandle) -> Data? {
        while true {
            if let nl = outBuffer.firstIndex(of: 0x0A) {
                let line = outBuffer.subdata(in: outBuffer.startIndex..<nl)
                outBuffer.removeSubrange(outBuffer.startIndex...nl)
                return line
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }  // EOF
            outBuffer.append(chunk)
        }
    }

    private static func sidecarScriptPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "ocr_sidecar", ofType: "py") {
            return bundled
        }
        // Dev fallback: alongside the sources.
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("ocr_sidecar.py").path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    // MARK: - Structured Extraction

    private struct ExtractedData {
        var urls: [String] = []
        var emails: [String] = []
        var phones: [String] = []
        var paths: [String] = []
    }

    private static func extractStructuredData(from text: String) -> ExtractedData {
        var result = ExtractedData()

        // URLs
        if let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"\']+"#, options: .caseInsensitive) {
            let matches = urlRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            result.urls = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }

        // Also catch localhost URLs
        if let localRegex = try? NSRegularExpression(pattern: #"localhost:\d+[^\s<>\"\']*"#, options: .caseInsensitive) {
            let matches = localRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let locals = matches.compactMap { Range($0.range, in: text).map { "http://\(String(text[$0]))" } }
            result.urls.append(contentsOf: locals)
        }

        // Catch domain-based URLs without protocol (e.g. from browser address bars)
        if let domainRegex = try? NSRegularExpression(pattern: #"[\w-]+\.[\w.-]+/[^\s<>\"\']*"#) {
            let matches = domainRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let domains = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .filter { $0.contains("/") && !$0.hasPrefix("http") }
                .map { "https://\($0)" }
            result.urls.append(contentsOf: domains)
        }

        // Emails
        if let emailRegex = try? NSRegularExpression(pattern: #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#) {
            let matches = emailRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            result.emails = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }

        // Phone numbers (international format)
        if let phoneRegex = try? NSRegularExpression(pattern: #"\+?\d[\d\s\-()]{7,}\d"#) {
            let matches = phoneRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            result.phones = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .filter { $0.filter(\.isNumber).count >= 7 }
        }

        // File paths
        if let pathRegex = try? NSRegularExpression(pattern: #"(?:/[\w.-]+){2,}"#) {
            let matches = pathRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            result.paths = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .filter { $0.count > 5 }
        }

        // Deduplicate
        result.urls = Array(Set(result.urls))
        result.emails = Array(Set(result.emails))
        result.phones = Array(Set(result.phones))
        result.paths = Array(Set(result.paths))

        return result
    }
}
