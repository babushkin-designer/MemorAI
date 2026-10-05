import Cocoa

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--audio-probe" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            try await AudioCaptureProbe.run(in: URL(fileURLWithPath: CommandLine.arguments[2]))
            exit(0)
        } catch {
            fputs("Audio probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    app.run()
    exit(1)
}

// Prevent multiple instances
let runningApps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "com.local.memorai"
}
if runningApps.count > 1 {
    // Another instance is already running — activate it and exit
    runningApps.first { $0 != NSRunningApplication.current }?.activate()
    exit(0)
}

let app = NSApplication.shared
// Top-level code runs on the main thread, but the compiler does not know that
// under this language mode; the delegate is main-actor bound.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
