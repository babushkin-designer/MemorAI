# Plan 007: Serialize start/stop so a stop during startup can't orphan a session

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. Touch
> only in-scope files. On any STOP condition, stop and report. Commit in your
> worktree per the git workflow section. Do not update `plans/README.md` —
> the reviewer maintains the index.
>
> **Drift check (run first)**: Written against branch
> `advisor/003-graceful-shutdown` @ `39007fa` (NOT bare `d02bcd3` — this plan
> builds on plan 003's completion-callback changes to `stopRecording`).
> Branch your worktree from that commit (or from the owner's branch if 003
> has been merged there). Compare the "Current state" excerpts; on mismatch,
> STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — recording state machine; wrong ordering can deadlock stop
- **Depends on**: plans/003-graceful-shutdown-finalize-recorders.md (DONE, branch `advisor/003-graceful-shutdown`)
- **Category**: bug
- **Planned at**: `advisor/003-graceful-shutdown` @ `39007fa`, 2026-07-09

## Why this matters

`RecordingManager.startRecording` sets state `.starting` and does the actual
recorder startup inside an unstructured `Task`. `stopRecording` accepts state
`.starting` and spawns its own `Task`. The two tasks are not ordered: if
auto-detect fires call-end (or the user hits Stop, or a stream error fires)
while the start task is still inside `try await sysRec.start()`, the stop
task can run first — its `systemAudioRecorder?.stop()` no-ops (recorder not
yet `isRecording`), it sets state `.idle` — and then the start task finishes,
starts the mic, and sets state `.recording`. Result: an orphaned session that
records indefinitely with the call-detector already disarmed, and files that
are never finalized. The fix: the stop task must await the start task before
stopping anything.

## Current state

File: `AutoRec/RecordingManager.swift` (as of `advisor/003-graceful-shutdown` @ 39007fa).

`startRecording` (core shape — lines ~29-90 at d02bcd3, shifted slightly by plan 003):

```swift
func startRecording(source: String = "manual") {
    guard state == .idle else { ... return }
    setState(.starting)
    onRecordingActiveChanged?(true)
    ...
    Task {
        do {
            let sysRec = SystemAudioRecorder(audioURL: sysURL, videoURL: vidURL)
            ...
            self.systemAudioRecorder = sysRec
            try await sysRec.start()

            let micRec = MicRecorder(outputURL: micURL)
            ...
            self.micRecorder = micRec
            try micRec.start()

            setState(.recording)
            log("[RecordingManager] All recorders running")
        } catch {
            log("[RecordingManager] ❌ Failed to start: \(error)")
            await systemAudioRecorder?.stop()
            micRecorder?.stop()
            systemAudioRecorder = nil
            micRecorder = nil
            setState(.idle)
            onRecordingActiveChanged?(false)
        }
    }
}
```

`stopRecording` (post-plan-003 shape, with `completion` parameter and
`pendingStopCompletions`):

```swift
func stopRecording(source: String = "manual", completion: (() -> Void)? = nil) {
    guard state == .recording || state == .starting || state == .paused else {
        if state == .stopping {
            if let completion = completion {
                pendingStopCompletions.append(completion)
            }
        } else {
            completion?()
        }
        return
    }
    log("[RecordingManager] Recording stopped (source: \(source))")
    setState(.stopping)
    ...
    Task {
        micRecorder?.stop()
        await systemAudioRecorder?.stop()
        ...
    }
}
```

Conventions: `log()` for logging, unstructured `Task`s, callbacks fired on
main via `DispatchQueue.main.async` where UI-relevant.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build   | `swift build` | exit 0, "Build complete!" |
| Test    | `swift test` | exit 0 (only if plan 006 landed on your base branch; otherwise skip) |

## Scope

**In scope**:
- `AutoRec/RecordingManager.swift`

**Out of scope**:
- `AutoRec/AppDelegate.swift`, `AutoRec/CallDetector.swift`,
  `AutoRec/SystemAudioRecorder.swift`, `AutoRec/MicRecorder.swift`.
- Adding a full actor-based rewrite — this plan is the minimal ordering fix.

## Git workflow

- Branch: `advisor/007-start-stop-race` off `advisor/003-graceful-shutdown`
  (or off the owner's branch if 003 is merged). One or two commits,
  single-line imperative messages. Do NOT push.
- Create your own worktree:
  `git -C /Users/ilyababushkin/memory/MemorAI worktree add /tmp/claude/wt-007 advisor/003-graceful-shutdown -b advisor/007-start-stop-race` (adjust base if merged)

## Steps

### Step 1: Retain the start task

Add a property:

```swift
/// The in-flight startup task; stop must await it so a stop issued during
/// .starting cannot run before the recorders exist (orphaned-session race).
private var startTask: Task<Void, Never>?
```

In `startRecording`, assign the existing `Task { ... }` to it:
`startTask = Task { ... }`. At the end of both the success path (after
`log("[RecordingManager] All recorders running")`) and the catch path, set
`self.startTask = nil` is NOT needed (awaiting a finished task is free) —
leave it retained; it is replaced on the next start.

**Verify**: `swift build` → exit 0.

### Step 2: Await it in the stop task

In `stopRecording`'s `Task`, as the first statement:

```swift
Task {
    // Wait for a still-running startup to finish so we stop real, started
    // recorders — otherwise stop no-ops on nil/unstarted recorders and the
    // startup task then brings the session up with nobody left to stop it.
    await startTask?.value
    micRecorder?.stop()
    await systemAudioRecorder?.stop()
    ...
}
```

Edge case to verify by reading (no code needed): if the start task's `catch`
branch already tore everything down and set `.idle`, the stop task then
stops nil recorders (no-op) and sets `.idle` again — harmless. If start
succeeded, stop now always sees live recorders — the race is closed.

**Verify**: `swift build` → exit 0.

### Step 3: Guard double-start during stopping

`startRecording`'s guard is `state == .idle`, which already rejects starts
during `.stopping` — confirm by reading and note in your report that no
change was needed (or STOP if the guard has changed).

**Verify**: `grep -n "guard state == .idle" AutoRec/RecordingManager.swift` → 1 match.

## Test plan

No runtime harness exists for the async race (would need mock recorders —
out of scope). Verification is build + code review of the ordering. If plan
006's test target exists on your base, run `swift test` to confirm no
regressions.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `stopRecording`'s Task begins with `await startTask?.value`
- [ ] `startRecording` assigns its Task to `startTask`
- [ ] Diff touches only `AutoRec/RecordingManager.swift`
- [ ] `git status` clean after commit

## STOP conditions

- Your base branch's `stopRecording` lacks the `completion` parameter /
  `pendingStopCompletions` (means you branched from the wrong commit — plan
  003 must be underneath).
- The compiler forces `startTask` access into actor isolation you can't
  resolve with the current class design — report rather than sprinkling
  `@MainActor` around.

## Maintenance notes

- This is the minimal fix. If RecordingManager grows more concurrent entry
  points, convert it to an actor instead of adding more ordering fields.
- Reviewer: check that `await startTask?.value` cannot deadlock — the start
  task never waits on the stop task (it only awaits recorder startup), so
  the wait graph is acyclic.
