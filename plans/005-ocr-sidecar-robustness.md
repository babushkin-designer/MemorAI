# Plan 005: Make the OCR sidecar hang-proof and self-healing

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: Written against commit `d02bcd3` **plus
> uncommitted working-tree changes** — `AutoRec/OCRProcessor.swift` and
> `AutoRec/ocr_sidecar.py` are new/modified and not yet committed. The
> excerpts below are from the working tree, not the commit. If the working
> tree has changed further since 2026-07-09, compare excerpts and STOP on
> mismatch.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — touches the OCR data path; a bug here loses screenshot metadata
- **Depends on**: none (but coordinate with the operator: this file has
  uncommitted work; branch from the current working tree, not from `d02bcd3`)
- **Category**: bug / reliability
- **Planned at**: commit `d02bcd3` + dirty tree, 2026-07-09

## Why this matters

Screen-memory OCR runs through a persistent Python RapidOCR sidecar
(AutoRec/OCRProcessor.swift, AutoRec/ocr_sidecar.py). Two reliability gaps:

1. **A hung sidecar blocks everything, forever.** `readLine(from:)`
   (OCRProcessor.swift:132-143) blocks on `handle.availableData` with no
   timeout. If RapidOCR wedges on one image (native ONNX code — it happens),
   the serial OCR queue blocks permanently. Because the JSONL record is only
   appended *after* `recognize` returns (OCRProcessor.swift:25-40), every
   subsequent screenshot's **metadata record is also never written** — the
   images keep saving but `index.jsonl` silently stops growing. The app was
   built precisely because Apple Vision hung; the replacement must not have
   the same failure mode.
2. **One bad launch disables OCR until app restart.** `sidecarFailed`
   (OCRProcessor.swift:22, set at :81, :97, :112, checked at :76) is never
   reset. A transient failure (Homebrew python mid-upgrade, model download
   race) silently kills OCR for the rest of the app's uptime, with no menu
   indication and nothing but a single log line.

## Current state

- `AutoRec/OCRProcessor.swift` — all the Swift changes land here.

`process()` (lines 25-41): record appended only after `recognize` returns —
correct ordering to keep, but note it means a `recognize` hang stops all
appends:

```swift
func process(imageURL: URL, jsonlURL: URL, baseMeta: [String: Any]) {
    queue.async {
        var record = baseMeta
        if let text = self.recognize(imageURL: imageURL), !text.isEmpty {
            record["ocr_text"] = text
            ...
        }
        JSONLWriter.shared.append(record, to: jsonlURL)
    }
}
```

`readLine(from:)` (lines 132-143), the unbounded blocking read:

```swift
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
```

`sidecarFailed` gate (line 76): `if sidecarFailed { return nil }` — permanent.

- `AutoRec/ocr_sidecar.py` — request/response protocol: one image path per
  stdin line → one `{"text": ...}` JSON per stdout line; `{"ready": true}`
  handshake on startup. No changes needed to the Python side.
- Capture cadence: one `process()` call per saved screenshot, at most one
  every `captureInterval` seconds (default 3, SettingsManager.swift:66-72).
- Conventions: `log()` for logging, serial `DispatchQueue` for state
  isolation, no external dependencies.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build   | `swift build` (in repo root `MemorAI/`) | exit 0, "Build complete!" |
| Sidecar smoke | `python3 AutoRec/ocr_sidecar.py` then type a path | `{"ready": ...}` line (needs rapidocr installed; skip if not) |

## Scope

**In scope**:
- `AutoRec/OCRProcessor.swift`

**Out of scope**:
- `AutoRec/ocr_sidecar.py` — protocol stays as-is.
- `AutoRec/ScreenMemoryManager.swift`, `AutoRec/JSONLWriter.swift` — callers
  and writer are fine.
- Surfacing OCR health in the menu bar UI — worthwhile follow-up, separate
  change (noted in Maintenance).

## Git workflow

- Branch from the **current working tree state** (it contains uncommitted OCR
  work this plan builds on): ask the operator to commit or stash-apply first
  if the tree is no longer dirty in the expected way.
- Branch: `advisor/005-ocr-robustness`. Do NOT push unless instructed.

## Steps

### Step 1: Add a timeout to `readLine`

Give `readLine` a deadline parameter: `readLine(from:handle, timeout: TimeInterval) -> Data?`.
Implementation approach (keep it dependency-free): do the blocking
`availableData` read on a helper thread via `DispatchQueue.global` +
`DispatchSemaphore.wait(timeout:)`, or use `select`-style polling on the file
descriptor. Simplest robust shape — poll the fd with a deadline:

```swift
private func readLine(from handle: FileHandle, timeout: TimeInterval) -> Data? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let nl = outBuffer.firstIndex(of: 0x0A) {
            let line = outBuffer.subdata(in: outBuffer.startIndex..<nl)
            outBuffer.removeSubrange(outBuffer.startIndex...nl)
            return line
        }
        var pfd = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return nil }  // timeout
        let rc = poll(&pfd, 1, Int32(min(remaining, 1.0) * 1000))
        if rc < 0 { return nil }          // poll error
        if rc == 0 { continue }           // interval elapsed, re-check deadline
        let chunk = handle.availableData
        if chunk.isEmpty { return nil }   // EOF
        outBuffer.append(chunk)
    }
}
```

(`poll` and `pollfd` come from Darwin; `import Darwin` if the compiler asks.)

Timeouts at call sites: handshake in `ensureSidecar` → **60 s** (model load
is slow on first run); per-image reply in `recognize` → **30 s**. On a nil
return in `recognize`, the existing "no reply — restarting" path already
calls `teardownSidecar()` — keep that; a hung child must also be killed,
which `teardownSidecar`'s `terminate()` does.

**Verify**: `swift build` → exit 0.

### Step 2: Replace the permanent `sidecarFailed` flag with bounded retry + cooldown

Replace `private var sidecarFailed = false` with:

```swift
private var consecutiveFailures = 0
private var retryAfter: Date? = nil
private let maxConsecutiveFailures = 3
private let retryCooldown: TimeInterval = 600  // 10 min
```

In `ensureSidecar`:
- Entry gate: if `let after = retryAfter, Date() < after` → return nil
  (silently; one log line when the cooldown is *set*, not per tick).
- On any failure path that today sets `sidecarFailed = true` (no interpreter,
  launch throw, bad handshake): increment `consecutiveFailures`; if it
  reaches `maxConsecutiveFailures`, set
  `retryAfter = Date().addingTimeInterval(retryCooldown)`, reset the counter,
  and log `"[OCR] sidecar failed \(maxConsecutiveFailures)× — retrying in 10 min"`.
- On a successful handshake: reset `consecutiveFailures = 0` and
  `retryAfter = nil`.

Net behavior: transient failures self-heal on later ticks; a persistent
failure (rapidocr not installed) costs 3 launch attempts every 10 minutes —
cheap — instead of dying until app restart.

**Verify**: `swift build` → exit 0, and
`grep -n "sidecarFailed" AutoRec/OCRProcessor.swift` → no matches.

### Step 3: Manual hang-recovery check

Simulate a wedged sidecar without rapidocr: create
`/tmp/claude/hang_sidecar.py`:

```python
import sys, json, time
sys.stdout.write(json.dumps({"ready": True}) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    time.sleep(3600)  # wedge on first request
```

Temporarily point `sidecarScriptPath()` at it (edit locally, do not commit),
run the app or a small harness calling `process()` twice, and confirm from
the log: first call logs the restart after ~30 s ("sidecar produced no
reply — restarting"), second call relaunches, and **both** records appear in
the target `index.jsonl` (without `ocr_text`). Revert the local edit.
If you cannot run the GUI/harness, report this step as environment-skipped
and rely on Steps 1-2 code review.

## Test plan

No Swift test target exists; do not create one here. Step 3 is the behavioral
check. Report exactly what was run.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `readLine` takes a `timeout` parameter; no unbounded `availableData`
      loop remains (`grep -n "availableData" AutoRec/OCRProcessor.swift` →
      only inside the new poll-guarded loop)
- [ ] `grep -n "sidecarFailed" AutoRec/OCRProcessor.swift` → no matches
- [ ] A `recognize` timeout still results in the JSONL record being appended
      (confirm by reading `process()` — the append is unconditional)
- [ ] `git status` shows only `AutoRec/OCRProcessor.swift` modified relative
      to the pre-plan working tree (plus plans/README.md)
- [ ] plans/README.md status row updated

## STOP conditions

- `AutoRec/OCRProcessor.swift` in the working tree no longer matches the
  excerpts (this file is actively being developed — high drift risk).
- The operator has committed the OCR work under a different design (e.g.
  moved to async/await or NIO) — replan rather than force this shape.
- `poll()` is unavailable or misbehaves in Swift on the target macOS — fall
  back to the semaphore-on-helper-thread approach; if both fail twice, STOP.

## Maintenance notes

- The 30 s per-image timeout bounds worst-case queue latency; with a 3 s
  capture interval a repeatedly-hanging sidecar still degrades to ~1 record
  per 30 s. If that proves too slow, drop the timeout to 10 s — RapidOCR on a
  1600px screenshot takes ~1-3 s normally.
- Follow-up candidates deliberately not in scope: menu-bar indicator for "OCR
  degraded/disabled"; queue-depth cap that skips OCR (but still writes the
  metadata record) when the backlog exceeds N images.
- Reviewer: scrutinize `outBuffer` handling across restarts (`teardownSidecar`
  clears it; `ensureSidecar` clears it again — both must stay).
