import Foundation

class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // MARK: - Call Recording

    var outputPath: String {
        get {
            defaults.string(forKey: "outputPath")
                ?? NSString("~/Downloads/MemorAI").expandingTildeInPath
        }
        set { defaults.set(newValue, forKey: "outputPath") }
    }

    var autoDetect: Bool {
        get {
            if defaults.object(forKey: "autoDetect") == nil { return true }
            return defaults.bool(forKey: "autoDetect")
        }
        set { defaults.set(newValue, forKey: "autoDetect") }
    }

    var recordScreen: Bool {
        get {
            if defaults.object(forKey: "recordScreen") == nil { return true }
            return defaults.bool(forKey: "recordScreen")
        }
        set { defaults.set(newValue, forKey: "recordScreen") }
    }

    var autoTranscribe: Bool {
        get {
            if defaults.object(forKey: "autoTranscribe") == nil { return true }
            return defaults.bool(forKey: "autoTranscribe")
        }
        set { defaults.set(newValue, forKey: "autoTranscribe") }
    }

    /// Acoustic echo cancellation on the call mic (Apple voice processing).
    /// Strips speaker playback from the mic track so speakerless calls don't
    /// end up with the far side recorded twice (mic leak + system audio).
    var micEchoCancellation: Bool {
        get {
            if defaults.object(forKey: "micEchoCancellation") == nil { return true }
            return defaults.bool(forKey: "micEchoCancellation")
        }
        set { defaults.set(newValue, forKey: "micEchoCancellation") }
    }

    /// Whisper language code: "ru", "en", "auto", etc. Default "ru".
    var whisperLanguage: String {
        get { defaults.string(forKey: "whisperLanguage") ?? "ru" }
        set { defaults.set(newValue, forKey: "whisperLanguage") }
    }

    // MARK: - Screen Memory

    var screenMemoryEnabled: Bool {
        get {
            if defaults.object(forKey: "screenMemoryEnabled") == nil { return true }
            return defaults.bool(forKey: "screenMemoryEnabled")
        }
        set { defaults.set(newValue, forKey: "screenMemoryEnabled") }
    }

    var saveClipboard: Bool {
        get {
            if defaults.object(forKey: "saveClipboard") == nil { return true }
            return defaults.bool(forKey: "saveClipboard")
        }
        set { defaults.set(newValue, forKey: "saveClipboard") }
    }

    var captureInterval: TimeInterval {
        get {
            let val = defaults.double(forKey: "captureInterval")
            return val > 0 ? val : 3
        }
        set { defaults.set(newValue, forKey: "captureInterval") }
    }

    var excludedBundleIds: [String] {
        get { defaults.stringArray(forKey: "excludedBundleIds") ?? [] }
        set { defaults.set(newValue, forKey: "excludedBundleIds") }
    }

    // MARK: - Whisper / Transcription

    /// Custom whisper-cli binary path override. Empty = auto-detect from common locations.
    var whisperPath: String {
        get { defaults.string(forKey: "whisperPath") ?? "" }
        set { defaults.set(newValue, forKey: "whisperPath") }
    }

    /// Custom Whisper model file path override. Empty = use default ~/.local/share/whisper-models/.
    var modelPath: String {
        get { defaults.string(forKey: "modelPath") ?? "" }
        set { defaults.set(newValue, forKey: "modelPath") }
    }

    // MARK: - Dictation

    /// System-wide voice dictation via ⌥Space (DictationManager).
    var dictationEnabled: Bool {
        get {
            if defaults.object(forKey: "dictationEnabled") == nil { return true }
            return defaults.bool(forKey: "dictationEnabled")
        }
        set { defaults.set(newValue, forKey: "dictationEnabled") }
    }

    // MARK: - LLM (summary / follow-up)

    /// "bluesminds" (default; separate free-token key) or "openai" (fallback;
    /// key shared with trading bots — overage silently bills, see plan 012).
    var llmProvider: String {
        get { defaults.string(forKey: "llmProvider") ?? "bluesminds" }
        set { defaults.set(newValue, forKey: "llmProvider") }
    }

    /// Model id on the selected provider. gpt-5.5 is the verified-working
    /// default on Bluesminds (claude-* are not enabled on this key).
    var llmModel: String {
        get { defaults.string(forKey: "llmModel") ?? "gpt-5.5" }
        set { defaults.set(newValue, forKey: "llmModel") }
    }

    // MARK: - Helpers

    func ensureOutputDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputPath) {
            try? fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
        }
    }
}
