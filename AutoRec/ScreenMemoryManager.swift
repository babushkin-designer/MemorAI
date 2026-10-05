import AppKit
import Foundation

class ScreenMemoryManager {
    private let capturer = ScreenCapturer()
    private let ocrProcessor = OCRProcessor()
    private let metadata = MetadataCollector()
    let clipboard = ClipboardMonitor()

    private var captureThread: Thread?
    private var lastSavedHash: UInt64 = 0
    private var keyPressCount = 0
    private var lastActiveAppBundleId: String = ""
    private var eventTap: CFMachPort?

    private let hashThreshold = 10
    private let keyPressThreshold = 30

    /// Pause capturing after this many seconds with no keyboard/mouse input.
    /// Handles an unattended-but-awake machine (e.g. background trading bots
    /// keeping dashboards live overnight): the screen changes but the user is
    /// away, so there is nothing worth recording.
    private let idlePauseSeconds: Double = 300
    private var idlePaused = false

    private(set) var isRunning = false

    /// Set while the session is locked or the display is asleep — capturing then
    /// only wastes CPU and records junk (e.g. the lock-screen clock ticking once
    /// a minute), so the tick is skipped until the screen is back.
    private var screenOff = false

    /// Set while a call is being recorded. Screenshots are cheap, but the OCR
    /// sidecar behind them is not, and a call is the one time the machine has
    /// a hard real-time deadline to meet. The frames are not worth a crackling
    /// conversation — the call has its own screen recording anyway.
    private var callPaused = false

    func setCallActive(_ active: Bool) {
        guard callPaused != active else { return }
        callPaused = active
        ocrProcessor.setCallActive(active)
        if active {
            // Dictation releases its whisper-server for a call; the OCR model
            // is the same kind of resident weight and does no work either way
            // while the loop is paused. `ensureSidecar` brings it back after.
            log("[ScreenMemory] paused (call recording, OCR sidecar released)")
        } else {
            lastSavedHash = 0  // the screen moved on while we were not looking
            log("[ScreenMemory] resumed (call ended)")
        }
    }

    func start() {
        guard !isRunning else { return }
        let settings = SettingsManager.shared
        let outputURL = URL(fileURLWithPath: settings.outputPath)

        ocrProcessor.resume()
        isRunning = true
        lastSavedHash = 0
        keyPressCount = 0
        lastActiveAppBundleId = ""

        clipboard.start(storageURL: outputURL)
        startClipboardPolling()
        startKeyboardMonitoring()
        startScreenStateMonitoring()

        let thread = Thread { [weak self] in
            while let self = self, self.isRunning {
                self.tick()
                Thread.sleep(forTimeInterval: SettingsManager.shared.captureInterval)
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        captureThread = thread
    }

    func stop() {
        isRunning = false
        captureThread = nil
        clipboardSource?.cancel()
        clipboardSource = nil
        stopKeyboardMonitoring()
        stopScreenStateMonitoring()
        ocrProcessor.shutdown()
    }

    // MARK: - Screen Lock / Sleep

    private func startScreenStateMonitoring() {
        // Session lock/unlock (e.g. screen locked overnight).
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenWentOff),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenCameBack),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        // Display sleep/wake (e.g. lid closed or display timeout).
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(screenWentOff),
                         name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(screenCameBack),
                         name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    private func stopScreenStateMonitoring() {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func screenWentOff() {
        screenOff = true
        log("[ScreenMemory] paused (screen locked or asleep)")
    }

    @objc private func screenCameBack() {
        screenOff = false
        lastSavedHash = 0  // force a fresh capture on return
        log("[ScreenMemory] resumed (screen on)")
    }

    // MARK: - Capture Tick

    private func tick() {
        let settings = SettingsManager.shared
        let outputURL = URL(fileURLWithPath: settings.outputPath)

        guard settings.screenMemoryEnabled else { return }
        guard !screenOff else { return }
        guard !callPaused else { return }

        // Skip while the user is idle (no input), even if the screen is changing.
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        if idle >= idlePauseSeconds {
            if !idlePaused { idlePaused = true; log("[ScreenMemory] paused (user idle)") }
            return
        }
        if idlePaused {
            idlePaused = false
            lastSavedHash = 0  // capture a fresh frame on return
            log("[ScreenMemory] resumed (user active)")
        }

        // Check if current app is excluded
        let currentApp = metadata.activeAppBundleID() ?? ""
        if settings.excludedBundleIds.contains(currentApp) { return }

        guard let image = capturer.capture() else { return }

        let currentHash = capturer.dhash(image)
        let distance = capturer.hammingDistance(currentHash, lastSavedHash)
        let appChanged = !lastActiveAppBundleId.isEmpty && currentApp != lastActiveAppBundleId
        let keyThreshold = keyPressCount >= keyPressThreshold

        lastActiveAppBundleId = currentApp

        let shouldSave = distance > hashThreshold || appChanged || keyThreshold
        guard shouldSave else { return }

        let now = Date()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"

        let dayDir = outputURL.appendingPathComponent("screen").appendingPathComponent(dayFormatter.string(from: now))
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let base = timeFormatter.string(from: now)
        let imageURL = dayDir.appendingPathComponent("\(base).heif")
        let jsonlURL = dayDir.appendingPathComponent("index.jsonl")

        guard !FileManager.default.fileExists(atPath: imageURL.path) else { return }

        let meta = metadata.collect()
        let savedURL = capturer.saveImage(image, to: imageURL)
        guard let savedURL = savedURL else {
            // Both of these say "this frame is on disk". Setting them before
            // the write meant a failed save left the screen looking already
            // captured, and nothing was kept until the screen changed again.
            log("[ScreenMemory] ❌ Could not write \(imageURL.lastPathComponent) — will try again next tick")
            return
        }
        lastSavedHash = currentHash
        keyPressCount = 0

        var baseRecord = meta
        baseRecord["timestamp"] = ISO8601DateFormatter().string(from: now)
        baseRecord["image_file"] = savedURL.lastPathComponent

        ocrProcessor.process(imageURL: savedURL, jsonlURL: jsonlURL, baseMeta: baseRecord)
    }

    // MARK: - Clipboard Polling (separate thread)

    private var clipboardSource: DispatchSourceTimer?

    private func startClipboardPolling() {
        // Use a GCD timer on the main queue — NSPasteboard.changeCount
        // only updates reliably on the main thread.
        //
        // Twice a second, not once every two: two copies inside one interval
        // are indistinguishable from one, since all the pasteboard offers is
        // "the contents changed" plus whatever is there now. Reading the change
        // count is a cheap IPC call and the contents are only read when it
        // moves, so the shorter interval costs close to nothing.
        // Leeway so 172k wakeups a day can be coalesced with other timers —
        // nothing here needs the tick to land on time, only to happen.
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self = self, self.isRunning, SettingsManager.shared.saveClipboard else { return }
            // Read lazily: the settings lookup and its array allocation are
            // only worth paying on the rare tick where the pasteboard moved.
            self.clipboard.checkAndSave(excludedBundleIds: SettingsManager.shared.excludedBundleIds)
        }
        source.resume()
        clipboardSource = source
    }

    // MARK: - Keyboard Monitoring

    private func startKeyboardMonitoring() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: screenMemoryKeyboardCallback,
            userInfo: refcon
        )

        guard let eventTap = eventTap else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopKeyboardMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    func incrementKeyCount() {
        keyPressCount += 1
    }

    func reenableEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

// C-function keyboard callback
private func screenMemoryKeyboardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let mgr = Unmanaged<ScreenMemoryManager>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout {
        mgr.reenableEventTap()
    } else {
        mgr.incrementKeyCount()
    }
    return Unmanaged.passUnretained(event)
}
