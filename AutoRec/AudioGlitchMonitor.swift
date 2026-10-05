import Foundation
import CoreAudio

/// Read-only HAL overload and route/configuration observations.
/// A missing event does not establish clean playback: driver and cross-process
/// notification coverage vary. Capture continuity and audible playback are
/// separate acceptance criteria. This monitor never sets device properties.
/// All listener state and session totals live on `queue`, including reattachment
/// when the default device changes.
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
    private struct ConfigurationListener {
        let id: AudioObjectID
        let property: AudioObjectPropertyAddress
        let callback: AudioObjectPropertyListenerBlock
    }
    private var retiredOverloads = 0
    private var routeListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var configurationListeners: [ConfigurationListener] = []
    private var totalOverloads: Int { retiredOverloads + watches.reduce(0) { $0 + $1.overloads } }
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
            self.retiredOverloads = 0
            self.attachAll()
            self.attachRouteListeners()
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
            let total = self.totalOverloads
            let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let perMinute = elapsed > 0 ? Double(total) / (elapsed / 60) : 0
            let detail = self.watches
                .filter { $0.overloads > 0 }
                .map { "\($0.role) \($0.overloads)" }
                .joined(separator: ", ")
            log(String(format: "[AudioGlitch] Session total: %d overload(s) in %.0fs (%.2f/min)%@",
                       total, elapsed, perMinute, detail.isEmpty ? "" : " — \(detail)"))
            self.detachRouteListeners()
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
                // Safety offset and latency exist per direction, not globally:
                // asked for in the global scope they simply come back missing.
                let scope = role == "input" ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
                let safety = Self.uint32Property(id, kAudioDevicePropertySafetyOffset, scope: scope)
                let latency = Self.uint32Property(id, kAudioDevicePropertyLatency, scope: scope)
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
        for selector in [kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyNominalSampleRate] {
            var property = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.snapshot("device configuration changed")
            }
            if AudioObjectAddPropertyListenerBlock(id, &property, queue, callback) == noErr {
                configurationListeners.append(ConfigurationListener(id: id, property: property, callback: callback))
            }
        }
    }

    private func detachAll() {
        for listener in configurationListeners {
            var address = listener.property
            AudioObjectRemovePropertyListenerBlock(listener.id, &address, queue, listener.callback)
        }
        configurationListeners.removeAll()
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

    private func attachRouteListeners() {
        for (_, selector) in Self.defaultDeviceSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.running else { return }
                self.retiredOverloads += self.watches.reduce(0) { $0 + $1.overloads }
                self.detachAll()
                self.attachAll()
                self.snapshot("default audio device changed")
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, callback) == noErr {
                routeListeners.append((address, callback))
            }
        }
    }

    private func detachRouteListeners() {
        for (property, callback) in routeListeners {
            var address = property
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, callback)
        }
        routeListeners.removeAll()
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
            let total = self.totalOverloads
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
        // The HAL hands back a +1 reference; taking it as Unmanaged is what
        // lets ARC balance it instead of leaking one string per snapshot.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let value = name?.takeRetainedValue() else { return "device \(id)" }
        return value as String
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
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
