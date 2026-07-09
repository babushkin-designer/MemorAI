# Plan 006: Establish a test baseline for the pure logic

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. Touch
> only in-scope files. On any STOP condition, stop and report. Commit in your
> worktree per the git workflow section. Do not update `plans/README.md` —
> the reviewer maintains the index.
>
> **Drift check (run first)**: Written against commit `d02bcd3` (2026-07-09).
> The in-scope Swift files were clean at that commit. Compare the "Current
> state" excerpts against the live code; on mismatch, STOP.

## Status

- **Priority**: P1 (unblocks safer future refactors)
- **Effort**: M
- **Risk**: LOW-MED — restructuring Package.swift can break the build; logic changes are visibility-only
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `d02bcd3`, 2026-07-09

## Why this matters

The repo has zero tests and no CI; the only verification gate is `swift
build`. Meanwhile it contains genuinely testable pure logic that already
caused real bugs the hard way (whisper hallucination dedup, OCR structured
extraction). A minimal XCTest target over the pure functions gives every
future plan a `swift test` gate instead of build-only, at near-zero runtime
cost (no GUI, no audio, no subprocess in these tests).

## Current state

- `Package.swift` — single `executableTarget` named `MemorAI`, path
  `AutoRec`, swift-tools-version 5.9, macOS 14+. No test target.
- Pure logic worth testing:
  - `AutoRec/ScreenCapturer.swift:25-55` — `dhash(_:)` (9x8 grayscale
    difference hash) and `hammingDistance(_:_:)`. Both internal — already
    testable via `@testable import`.
  - `AutoRec/OCRProcessor.swift:164-216` — `extractStructuredData(from:)`,
    currently `private static func` returning a `private struct
    ExtractedData`. Needs visibility widened to internal (drop both
    `private`s) for testing.
  - `AutoRec/Transcriber.swift:228-278` — `deduplicateTranscript(at:)`,
    currently `private func` on `Transcriber`, operates on a file URL. Needs
    `private` dropped.
- SwiftPM since 5.5 supports testing executable targets: a `.testTarget`
  with `dependencies: ["MemorAI"]` plus `@testable import MemorAI` links
  against the executable's modules on macOS. `AutoRec/main.swift` contains
  top-level NSApplication code, but importing a module does not execute its
  main — tests must simply never call `NSApplication.shared.run` or
  instantiate `AppDelegate`.
- IMPORTANT caveat: `AutoRec/OCRProcessor.swift` has uncommitted changes in
  the fork owner's main working tree (RapidOCR sidecar). Your worktree from
  `d02bcd3` contains the OLD Apple-Vision version of the file, whose
  `extractStructuredData` is identical in both versions. Only touch the
  visibility keywords on `extractStructuredData` / `ExtractedData` — keep the
  diff to that file minimal so the owner's later merge stays trivial.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build   | `swift build` | exit 0, "Build complete!" |
| Test    | `swift test` | exit 0, all tests pass |

## Scope

**In scope**:
- `Package.swift` (add `.testTarget`)
- `Tests/MemorAITests/` (new directory, new test files)
- `AutoRec/OCRProcessor.swift` — ONLY the two `private` keyword removals
- `AutoRec/Transcriber.swift` — ONLY the `private` keyword removal on
  `deduplicateTranscript`

**Out of scope**:
- Any behavioral change to the functions under test — if a test reveals a
  bug, write the test to document CURRENT behavior, add a `// NOTE: arguably
  wrong —` comment, and report it; do not fix it here.
- CI configuration, UI code, recorders.

## Git workflow

- Branch: `advisor/006-test-baseline` off `d02bcd3`. Commit per step,
  single-line imperative messages. Do NOT push.
- Create your own worktree:
  `git -C /Users/ilyababushkin/memory/MemorAI worktree add /tmp/claude/wt-006 -b advisor/006-test-baseline`

## Steps

### Step 1: Add the test target

In `Package.swift`, append to `targets:`:

```swift
.testTarget(
    name: "MemorAITests",
    dependencies: ["MemorAI"],
    path: "Tests/MemorAITests"
),
```

Create `Tests/MemorAITests/SmokeTests.swift` with one trivial test
(`XCTAssertEqual(1+1, 2)`) using `import XCTest` and
`@testable import MemorAI`.

**Verify**: `swift test` → exit 0, 1 test passes. If linking the executable
target fails here, this is the STOP condition below — do not restructure
targets on your own.

### Step 2: Widen visibility of the two private functions

- `AutoRec/OCRProcessor.swift`: `private struct ExtractedData` → `struct
  ExtractedData`; `private static func extractStructuredData` → `static func
  extractStructuredData`.
- `AutoRec/Transcriber.swift`: `private func deduplicateTranscript` → `func
  deduplicateTranscript`.

**Verify**: `swift build` → exit 0.

### Step 3: Write the tests

`Tests/MemorAITests/ExtractStructuredDataTests.swift` — call
`OCRProcessor.extractStructuredData(from:)` with:
- text containing an `https://` URL, a `localhost:3000/x` URL, and a bare
  `example.com/path` → all three appear in `.urls` (localhost gets `http://`
  prefix, bare domain gets `https://`)
- an email `a.b+c@test.io` → in `.emails`
- a phone `+7 999 123-45-67` → in `.phones`
- a path `/usr/local/bin/python3` → in `.paths`
- empty string → all four arrays empty
- duplicate URLs in input → deduplicated in output (order not guaranteed —
  compare as Sets)

`Tests/MemorAITests/DhashTests.swift` — using a tiny helper that builds a
solid-color `CGImage` in memory:
- same image twice → identical hashes, `hammingDistance == 0`
- solid black vs solid white → hash may legitimately be equal (no gradients);
  assert only `hammingDistance(h, h) == 0` and that
  `hammingDistance(0b1011, 0b0010) == 2` for the pure distance function
- `hammingDistance(0, .max) == 64`

`Tests/MemorAITests/DeduplicateTranscriptTests.swift` — write a temp file
(use `FileManager.default.temporaryDirectory`), run
`Transcriber.shared.deduplicateTranscript(at:)`, read it back:
- 5 identical consecutive lines → collapsed to 1
- 4 lines sharing a 15+ char prefix → collapsed to 1 (near-duplicate run)
- 2 lines sharing a prefix (run < 3) → kept as-is
- interleaved distinct lines → untouched

**Verify**: `swift test` → exit 0; test count ≥ 12.

### Step 4: Document the gate

Add to the end of `Package.swift` a one-line comment: `// Run tests: swift test`.

**Verify**: `swift build && swift test` → both exit 0.

## Test plan

This plan IS the test plan. No mocking, no GUI, no subprocesses in tests.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0 with ≥ 12 tests passing
- [ ] Diff in `AutoRec/OCRProcessor.swift` and `AutoRec/Transcriber.swift`
      touches only `private` keywords (verify with `git diff -w d02bcd3 -- AutoRec/`)
- [ ] `git status` clean after commits

## STOP conditions

- `swift test` cannot link/import the executable target after Step 1 despite
  the `.testTarget` being correctly declared — report the exact error; the
  fallback (splitting a library target out of the executable) is a separate
  decision for the reviewer, not yours.
- A function under test behaves so differently from the plan's expectations
  that tests can't be written without guessing (e.g. extraction regexes
  changed) — that's drift; STOP.

## Maintenance notes

- Every future plan should add `swift test` next to `swift build` in its
  command table.
- The `Transcriber.shared` singleton is used directly; if tests ever get
  flaky from shared state, that's the signal to extract the pure functions
  into free functions.
