import Foundation
import CoreAudio

/// Counts the audio dropouts the machine actually suffers while we record.
///
/// The symptom this exists for is crackle in the SPEAKERS during a call — a
/// missed CoreAudio IO deadline, not something any of our recorded files can
/// show (SCStream taps the mix before it reaches the hardware, so the system
/// track stays clean through a dropout the user heard). The only honest signal
/// is `kAudioDeviceProcessorOverload`, which the HAL posts to every listener on
/// a device that missed its cycle.
///
/// It is a MEASUREMENT, not a fix: every event is stamped with what the app was
/// doing at the time (recording, which post-processing stage, which subprocess),
/// so an overload burst can be attributed to our own background load instead of
/// guessed at.
///
/// STRICTLY READ-ONLY toward the devices. It attaches listeners and reads
/// properties; it never sets one. Buffer frame size and sample rate are shared
/// by every client on the machine, and writing them to "help" is the bug we
/// already removed once (live voice processing).
///
/// THREADING. All state lives on `queue`. Property listeners are delivered
/// there too, so a listener never touches an audio thread and never logs from
/// one — it bumps a counter, and the periodic timer does the writing.
final class AudioGlitchMonitor {
    static let shared = AudioGlitchMonitor()

    private let queue = DispatchQueue(label: "com.local.memorai.glitch")

    /// One watched device: its listener block and what it has cost us so far.
    private struct Watch {
        let id: AudioObjectID
        let role: String
        let name: String
        var overloads: Int = 0
        var lastOverload: Date?
        var listener: AudioObjectPropertyListenerBlock?
    }

    private var watches: [Watch] = []
    private var running = false
    private var startedAt: Date?
    /// What the app was doing, for the event lines. Set by RecordingManager /
    /// PostProcessor; read on `queue`.
    private var context = "idle"
    /// The post-processing stage running right now, if any — the load we most
    /// suspect. Set by PostProcessor as it moves through the pipeline.
    private var stage: String?
    private var reportTimer: DispatchSourceTimer?
    private let reportInterval: TimeInterval = 60

    private init() {}

    // MARK: - Lifecycle

    /// Begin watching the default input, output and system-output devices.
    /// Safe to call twice; the second call is ignored.
    func start(context: String) {
        queue.async { [weak self] in
            guard let self = self, !self.running else { return }
            self.running = true
            self.startedAt = Date()
            self.context = context
            self.attachAll()
            self.startReportTimer()
            let names = self.watches.map { "\($0.role)=\($0.name)" }.joined(separator: ", ")
            log("[AudioGlitch] Watching \(self.watches.count) device(s): \(names)")
        }
    }

    /// Stop watching and write the session total.
    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.running else { return }
            self.running = false
            self.reportTimer?.cancel()
            self.reportTimer = nil
            let total = self.watches.reduce(0) { $0 + $1.overloads }
            let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let perMinute = elapsed > 0 ? Double(total) / (elapsed / 60) : 0
            let detail = self.watches
                .filter { $0.overloads > 0 }
                .map { "\($0.role) \($0.overloads)" }
                .joined(separator: ", ")
            log(String(format: "[AudioGlitch] Session total: %d overload(s) in %.0fs (%.2f/min)%@",
                       total, elapsed, perMinute, detail.isEmpty ? "" : " — \(detail)"))
            self.detachAll()
            self.startedAt = nil
        }
    }

    /// Note what the app is doing, so overload lines say what to blame.
    func setContext(_ value: String) {
        queue.async { [weak self] in self?.context = value }
    }

    /// Note which post-processing stage is running (nil once the pipeline is
    /// idle). Recorded whether or not a recording is in progress, so the log
    /// shows an overload burst landing on top of a live call.
    func setStage(_ value: String?) {
        queue.async { [weak self] in self?.stage = value }
    }

    /// `context: recording, stage: whisper mic` — what to blame, in one piece.
    private var blame: String {
        stage.map { "\(context), stage: \($0)" } ?? context
    }

    // MARK: - Read-only device snapshot

    /// Log the shared IO parameters of the default devices at `label`.
    ///
    /// Taken before and after each recorder starts, this is what turns "maybe
    /// our second mic client reconfigures the HAL" into a yes or a no: if the
    /// output device's buffer frame size or sample rate moves when the mic
    /// engine comes up, the reconfiguration is real and measured.
    func snapshot(_ label: String) {
        queue.async {
            for (role, selector) in Self.defaultDeviceSelectors {
                guard let id = Self.defaultDevice(selector) else { continue }
                let name = Self.deviceName(id)
                let frames = Self.uint32Property(id, kAudioDevicePropertyBufferFrameSize)
                let rate = Self.doubleProperty(id, kAudioDevicePropertyNominalSampleRate)
                let safety = Self.uint32Property(id, kAudioDevicePropertySafetyOffset)
                let latency = Self.uint32Property(id, kAudioDevicePropertyLatency)
                log("[AudioGlitch] \(label) — \(role): \(name), buffer \(frames.map(String.init) ?? "?") frames, "
                    + "\(rate.map { String(format: "%.0f", $0) } ?? "?")Hz, safety \(safety.map(String.init) ?? "?"), "
                    + "latency \(latency.map(String.init) ?? "?")")
            }
        }
    }

    // MARK: - Listeners (queue)

    private static let defaultDeviceSelectors: [(String, AudioObjectPropertySelector)] = [
        ("output", kAudioHardwarePropertyDefaultOutputDevice),
        ("system-output", kAudioHardwarePropertyDefaultSystemOutputDevice),
        ("input", kAudioHardwarePropertyDefaultInputDevice),
    ]

    private func attachAll() {
        var seen = Set<AudioObjectID>()
        for (role, selector) in Self.defaultDeviceSelectors {
            guard let id = Self.defaultDevice(selector) else { continue }
            // The default output and the default system output are usually the
            // same device; one listener per device is enough.
            guard seen.insert(id).inserted else { continue }
            attach(id: id, role: role)
        }
    }

    private func attach(id: AudioObjectID, role: String) {
        var watch = Watch(id: id, role: role, name: Self.deviceName(id))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.recordOverload(id: id)
        }
        let status = AudioObjectAddPropertyListenerBlock(id, &address, queue, listener)
        guard status == noErr else {
            log("[AudioGlitch] ⚠️ Could not watch \(role) device \(watch.name) (OSStatus \(status))")
            return
        }
        watch.listener = listener
        watches.append(watch)
    }

    private func detachAll() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for watch in watches {
            guard let listener = watch.listener else { continue }
            AudioObjectRemovePropertyListenerBlock(watch.id, &address, queue, listener)
        }
        watches.removeAll()
    }

    /// Already on `queue` — the listener block was registered against it.
    private func recordOverload(id: AudioObjectID) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        watches[index].overloads += 1
        let now = Date()
        let previous = watches[index].lastOverload
        watches[index].lastOverload = now
        // One line per event would itself become load during a burst; log the
        // first of a burst and let the periodic report carry the rest.
        let isBurstStart = previous.map { now.timeIntervalSince($0) > 5 } ?? true
        if isBurstStart {
            log("[AudioGlitch] ⚠️ Overload on \(watches[index].role) (\(watches[index].name)) "
                + "— #\(watches[index].overloads), context: \(blame)")
        }
    }

    private func startReportTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + reportInterval, repeating: reportInterval)
        var lastTotal = 0
        timer.setEventHandler { [weak self] in
            guard let self = self, self.running else { return }
            let total = self.watches.reduce(0) { $0 + $1.overloads }
            defer { lastTotal = total }
            guard total > lastTotal else { return }
            log("[AudioGlitch] \(total - lastTotal) overload(s) in the last \(Int(self.reportInterval))s "
                + "(\(total) this session), context: \(self.blame)")
        }
        timer.resume()
        reportTimer = timer
    }

    // MARK: - Property reads

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    private static func deviceName(_ id: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        return status == noErr ? (name as String) : "device \(id)"
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func doubleProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? Double(value) : nil
    }
}
