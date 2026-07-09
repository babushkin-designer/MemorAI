# Plan 001: Eliminate the subprocess pipe-buffer deadlock in Transcriber

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: This plan was written against commit `d02bcd3`
> with a dirty working tree (uncommitted OCR-sidecar changes in other files —
> `AutoRec/Transcriber.swift` itself was clean). Compare the "Current state"
> excerpts below against the live code before proceeding; on a mismatch, treat
> it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d02bcd3`, 2026-07-09

## Why this matters

`Transcriber.runProcess` (AutoRec/Transcriber.swift:343-381) launches ffmpeg
and whisper-cli with `Pipe()` on stdout/stderr, calls
`process.waitUntilExit()`, and only **afterwards** reads the pipes. A macOS
pipe buffer holds ~64 KB. ffmpeg prints continuous progress/stats lines to
stderr; on a long call recording (the app's core use case — hour-long calls),
stderr output exceeds the buffer, ffmpeg blocks on `write(2)`, the parent
blocks in `waitUntilExit`, and the watchdog timer eventually kills the child
(default timeout 3600 s). The merge then "fails" and the transcript is silently
lost. This is the classic pipe-drain deadlock, and it makes transcription of
exactly the longest, most valuable recordings unreliable. The fix is to drain
both pipes concurrently while the process runs, and to silence ffmpeg's stats
output.

## Current state

- `AutoRec/Transcriber.swift` — the only file to change. Relevant pieces:

`runProcess` (lines 343-381), the buggy pattern:

```swift
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
process.standardOutput = stdoutPipe
process.standardError = stderrPipe
...
process.waitUntilExit()          // ← blocks while child blocks writing to full pipe
timer.cancel()

let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
```

Call sites of `runProcess` inside this file (do not change their semantics):
- line 110 and 124: ffmpeg merge/convert (uses `convertResult.exitCode` and `.stderr`)
- line 146 and 179: whisper-cli transcription (uses `.exitCode`, `.stderr`)
- line 168: ffmpeg chunk extraction (uses `.exitCode`)
- line 215 (`trackDuration`): ffmpeg `-i <file> -f null -` with `timeout: 10`;
  parses `Duration: HH:MM:SS.ss` out of `result.stderr` **without checking the
  exit code** — this call currently *relies* on getting stderr even when the
  process was killed by timeout. The fix must preserve that: stderr collected
  so far must be returned even on timeout.

Repo conventions: no external dependencies, plain Foundation, logging via the
global `log()` function (see AutoRec/Logger.swift). Match that style.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build   | `swift build` (run in the repo root, `MemorAI/`) | exit 0, "Build complete!" |
| Test    | `swift test` | only if a test target exists by then; otherwise skip |

## Scope

**In scope** (the only files you may modify):
- `AutoRec/Transcriber.swift`

**Out of scope** (do NOT touch, even though they look related):
- `AutoRec/AudioMuxer.swift` — has a similar but *not identical* pattern (it
  reads stderr only after failure and its output volume is bounded by
  `-c:v copy`; it also already discards stdout into an unread `Pipe()`, which
  has the same theoretical issue). Fixing it is a follow-up, noted in
  Maintenance notes — keep this plan's diff minimal and verifiable.
- `AutoRec/OCRProcessor.swift` — its sidecar protocol is intentionally
  blocking; covered by plan 005.

## Git workflow

- Branch: `advisor/001-pipe-deadlock` (repo has single-line version-style
  commit messages, e.g. `v1.5.0: HEVC call video and JSONL screenshot index`;
  a plain imperative one-liner is fine).
- Do NOT push unless the operator instructed it.

## Steps

### Step 1: Drain pipes concurrently in `runProcess`

Rewrite the body of `runProcess` so stdout and stderr are accumulated *while*
the process runs, using `readabilityHandler`. Target shape:

```swift
private func runProcess(_ path: String, args: [String], timeout: TimeInterval? = nil) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Drain both pipes as data arrives so the child never blocks on a full
    // pipe buffer (ffmpeg's stderr stats exceed 64 KB on long inputs).
    var stdoutData = Data()
    var stderrData = Data()
    let ioQueue = DispatchQueue(label: "com.local.memorai.process-io")
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        ioQueue.async { stdoutData.append(chunk) }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        ioQueue.async { stderrData.append(chunk) }
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
    }

    // (keep the existing timeout timer logic unchanged)
    ...
    process.waitUntilExit()
    timer.cancel()

    // Stop handlers, then collect any remaining buffered bytes synchronously.
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    let finalOut = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? nil
    let finalErr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
    let (outData, errData): (Data, Data) = ioQueue.sync {
        (stdoutData + (finalOut ?? Data()), stderrData + (finalErr ?? Data()))
    }
    ...
}
```

Notes that are load-bearing:
- All appends go through the serial `ioQueue`; the final read of the
  accumulated data must also go through `ioQueue.sync` (readability handlers
  fire on an arbitrary internal queue).
- An empty `availableData` chunk signals EOF; appending an empty Data is
  harmless, so no special-casing is needed inside the handler.
- Keep the existing timeout `DispatchSourceTimer`, `timedOut` flag, exit-code
  `-2` convention, and the timeout log line exactly as they are — `trackDuration`
  depends on stderr being returned even when `timedOut == true`.
- The `...` markers in the excerpt stand for the existing timer code — keep it.

**Verify**: `swift build` → exit 0, "Build complete!"

### Step 2: Silence ffmpeg stats output at the call sites

Belt-and-suspenders: reduce stderr volume so even pathological cases stay
small. In `transcribeSession` and `trackDuration`, add `"-nostats",
"-loglevel", "error"` immediately after the `"-y"` flag (or as the first args
for `trackDuration`, which has no `-y`) to every **ffmpeg** invocation:
lines 110, 124, 168 (`-y` present) and line 215 (`trackDuration`).

Exception — `trackDuration` parses the `Duration:` header, which `-loglevel
error` suppresses. For that one call use `"-hide_banner", "-nostats"` only
(keep default loglevel `info`, which prints the `Duration:` line). Do NOT add
loglevel flags to whisper-cli calls.

**Verify**: `swift build` → exit 0. Then confirm flags:
`grep -n "nostats" AutoRec/Transcriber.swift` → 4 matches.

### Step 3: Manual smoke test of the merge path

Generate a long test input and run the exact merge command the app builds, to
prove the child no longer stalls (this exercises ffmpeg, not the Swift code,
but confirms flag correctness):

```bash
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=60" -c:a aac /tmp/claude/t_mic.m4a
ffmpeg -y -f lavfi -i "sine=frequency=220:duration=60" -c:a aac /tmp/claude/t_sys.m4a
ffmpeg -y -nostats -loglevel error -i /tmp/claude/t_mic.m4a -i /tmp/claude/t_sys.m4a \
  -filter_complex "[0:a]loudnorm=I=-16:TP=-1.5:LRA=11[mic];[1:a]loudnorm=I=-16:TP=-1.5:LRA=11[sys];[mic][sys]amix=inputs=2:duration=longest[a]" \
  -map "[a]" -ar 16000 -ac 1 -c:a pcm_s16le /tmp/claude/t_merged.wav
```

**Verify**: exit 0 and `/tmp/claude/t_merged.wav` exists and is >1 MB.

## Test plan

No test target exists in this repo (verification is `swift build` only). Do
not create one in this plan. The smoke test in Step 3 plus the grep in Step 2
are the regression checks.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `grep -n "readDataToEndOfFile" AutoRec/Transcriber.swift` → no matches
- [ ] `grep -c "nostats" AutoRec/Transcriber.swift` → 4
- [ ] `git status` shows only `AutoRec/Transcriber.swift` modified (plus plans/README.md)
- [ ] plans/README.md status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `runProcess` in the live file no longer matches the excerpt (someone already
  fixed or refactored it).
- After Step 1, `swift build` fails twice with concurrency/actor-isolation
  errors you cannot resolve by keeping the closure captures as plain `var` +
  serial queue (the target uses default Swift 5.9 mode, not strict concurrency
  — if the build is somehow in strict mode, stop).
- You find call sites of `runProcess` outside `Transcriber.swift`.

## Maintenance notes

- `AudioMuxer.swift:74-96` has the sibling pattern (unread stdout pipe,
  stderr read after exit). Its risk is lower (`-c:v copy` is fast, stderr
  read is post-failure only) but it should get the same `-nostats -loglevel
  error` flags and drain treatment in a future pass.
- If anyone adds a new subprocess call, they must reuse `runProcess`, never
  the raw waitUntilExit-then-read pattern.
- Reviewer should scrutinize: the `ioQueue.sync` at the end (deadlock-free
  because handlers are nil'd first), and that `trackDuration` still parses
  durations (its loglevel must stay `info`).
