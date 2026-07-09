# Plan 003: Finalize in-flight recordings before the app terminates

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: Written against commit `d02bcd3` (working tree
> dirty in other files; `AppDelegate.swift` and `RecordingManager.swift` were
> clean). Compare the "Current state" excerpts against the live code; on
> mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — touches the recording state machine; a mistake can hang quit
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d02bcd3`, 2026-07-09

## Why this matters

Quitting MemorAI while a call is being recorded corrupts the recording.
`AppDelegate.quit()` (AutoRec/AppDelegate.swift:426-430) calls
`recordingManager.stopRecording()` — which merely *spawns* an async `Task` —
and then immediately calls `NSApp.terminate(nil)`. The process dies before
`AVAssetWriter.finishWriting` runs, so the `.m4a`/`.mp4` files are left
unfinalized (an MP4 without its moov atom is unplayable). The same happens for
⌘Q via the system, logout/shutdown, and `memorai stop` (which uses `pkill`).
Call recordings are the app's most valuable, least reproducible artifact — a
user who quits right after a call loses that call. The fix is the standard
AppKit pattern: `applicationShouldTerminate` returning `.terminateLater`,
replying once the recorders have finished.

## Current state

- `AutoRec/AppDelegate.swift` — menu Quit action, lines 426-430:

```swift
@objc private func quit() {
    screenMemory.stop()
    recordingManager.stopRecording()
    NSApp.terminate(nil)
}
```

There is currently **no** `applicationShouldTerminate` or
`applicationWillTerminate` implementation in the file.

- `AutoRec/RecordingManager.swift` — `stopRecording` (lines 108-149) sets
  state `.stopping`, then does the actual stop inside `Task { ... }`:

```swift
func stopRecording(source: String = "manual") {
    guard state == .recording || state == .starting || state == .paused else { return }
    log("[RecordingManager] Recording stopped (source: \(source))")
    setState(.stopping)
    ...
    Task {
        micRecorder?.stop()
        await systemAudioRecorder?.stop()
        micRecorder = nil
        systemAudioRecorder = nil
        setState(.idle)
        onRecordingActiveChanged?(false)
        log("[RecordingManager] All recorders stopped")
        // ... AudioMuxer + Transcriber kick-off follow
    }
}
```

`SystemAudioRecorder.stop()` (AutoRec/SystemAudioRecorder.swift:216-270) is
`async` and awaits `finishWriting` for both audio and video writers — that is
the work that must complete before process exit. It includes a fixed 0.3 s
buffer-drain sleep, so a normal stop completes in well under 3 s.

- `RecordingState` (AutoRec/RecordingState.swift) is a simple enum:
  `.idle, .starting, .recording, .paused, .stopping`.

Conventions: callbacks-over-delegates, `log()` for logging, main-thread UI
updates via `DispatchQueue.main.async`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build   | `swift build` (in repo root `MemorAI/`) | exit 0, "Build complete!" |

## Scope

**In scope**:
- `AutoRec/AppDelegate.swift`
- `AutoRec/RecordingManager.swift`

**Out of scope**:
- `memorai` CLI (`pkill` sends SIGTERM; making the CLI graceful — e.g.
  `osascript -e 'quit app "MemorAI"'` — is a nice follow-up but changes CLI
  behavior; note it, don't do it).
- `AutoRec/Transcriber.swift`, `AutoRec/AudioMuxer.swift` — post-stop
  processing may be abandoned at quit; that is acceptable (transcription can
  be re-run from the audio files, which is exactly what this plan preserves).
- The start/stop race during `.starting` (see plans/README.md "considered"
  section) — do not attempt to fix it here.

## Git workflow

- Branch: `advisor/003-graceful-shutdown`. Commit per step, single-line
  imperative messages. Do NOT push unless instructed.

## Steps

### Step 1: Give `stopRecording` a completion callback

In `RecordingManager.swift`, change the signature to
`func stopRecording(source: String = "manual", completion: (() -> Void)? = nil)`.

- Inside the early-return `guard`, call `completion?()` before returning
  (callers must always get the callback).
- Inside the `Task`, call `completion?()` immediately after
  `log("[RecordingManager] All recorders stopped")` — i.e. after writers are
  finalized but before the AudioMuxer/Transcriber kick-off (those are
  abandonable post-processing).

Existing call sites (`AppDelegate.swift:49` auto-detect callback,
`AppDelegate.swift:309` menu action, `RecordingManager.swift:67`
stream-error handler) compile unchanged thanks to the default value.

**Verify**: `swift build` → exit 0.

### Step 2: Implement deferred termination in AppDelegate

Add to `AppDelegate`:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    screenMemory.stop()
    let state = recordingManager?.state ?? .idle
    guard state == .recording || state == .starting || state == .paused || state == .stopping else {
        return .terminateNow
    }
    log("[AppDelegate] Terminate requested during recording — finalizing first")
    recordingManager.stopRecording(source: "app-quit") {
        DispatchQueue.main.async {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
    // Failsafe: never hang quit for more than 10s.
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        NSApp.reply(toApplicationShouldTerminate: true)  // no-op if already replied
    }
    return .terminateLater
}
```

Caveat the executor must handle: if `state == .stopping`, a stop `Task` is
already in flight and `stopRecording` will hit its guard and call
`completion?()` immediately — before the writers finish. To cover that case,
in Step 1 also store the completion when state is `.stopping`: add a private
`var pendingStopCompletions: [() -> Void] = []`; in the guard branch, if
`state == .stopping`, append `completion` to the array and return *without*
calling it; in the `Task`, after finalization, drain and call every entry in
`pendingStopCompletions` (on the main queue) in addition to the `completion`
parameter. Keep it simple — this app is effectively single-user/main-thread
at these call sites.

Then simplify the menu `quit()` action to just:

```swift
@objc private func quit() {
    NSApp.terminate(nil)
}
```

(`applicationShouldTerminate` now handles `screenMemory.stop()` and recorder
finalization for every quit path, not just the menu item.)

**Verify**: `swift build` → exit 0.

### Step 3: Manual verification

If you can run the GUI: `bash bundle.sh && open MemorAI.app`, start a manual
recording from the menu, wait ~10 s, hit Quit. Then:

```bash
ffmpeg -v error -i "$(ls -t ~/Downloads/MemorAI/call_*_system.m4a | head -1)" -f null - && echo OK
```

**Verify**: prints `OK` (file finalized and decodable). Also
`grep "Terminate requested" ~/Downloads/MemorAI/memorai.log` → 1+ line.
If no GUI available, report this step as environment-skipped.

## Test plan

No test target exists; the build gate + Step 3 manual check are the
verification. Do not add a test target in this plan.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `AppDelegate` implements `applicationShouldTerminate` returning
      `.terminateLater` when state ≠ idle
- [ ] `quit()` no longer calls `recordingManager.stopRecording()` directly
- [ ] `stopRecording` completion fires after writer finalization (read the
      code to confirm ordering: after "All recorders stopped" log)
- [ ] `git status` shows only the two in-scope files modified (plus plans/README.md)
- [ ] plans/README.md status row updated

## STOP conditions

- Excerpts don't match the live code.
- `swift build` fails twice on Swift-concurrency isolation errors around
  `NSApp.reply` (must be main-thread; the `DispatchQueue.main.async` wrapper
  is the intended fix — if that doesn't compile, stop).
- You find yourself modifying `SystemAudioRecorder.swift` or `MicRecorder.swift`
  — the fix belongs entirely in AppDelegate + RecordingManager.

## Maintenance notes

- `memorai stop` (CLI `pkill`) still SIGTERMs the app; SIGTERM triggers
  AppKit's termination path for `.accessory` apps in most cases, but a
  follow-up switching the CLI to `osascript -e 'quit app "MemorAI"'` would
  make it explicit.
- The 10 s failsafe means a pathologically hung writer still loses data —
  that's deliberate (never brick quit). Reviewer should confirm the double
  `reply(toApplicationShouldTerminate:)` is harmless (AppKit ignores the
  second reply).
- If pause/resume semantics change, revisit the state guard list here.
