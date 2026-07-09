# Plan 002: Stop persisting concealed clipboard content (password-manager copies)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: Written against commit `d02bcd3` (working tree
> dirty in other files; `AutoRec/ClipboardMonitor.swift` was clean). Compare
> the "Current state" excerpt against the live code; on mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `d02bcd3`, 2026-07-09

## Why this matters

`ClipboardMonitor.checkAndSave` (AutoRec/ClipboardMonitor.swift:28-113) writes
every clipboard text change verbatim to `clipboard.jsonl` in the output folder
(default `~/Downloads/MemorAI/`) and keeps it in the in-memory menu history.
Password managers (1Password, Bitwarden, KeePassXC, Apple Passwords, etc.)
mark sensitive copies with the de-facto standard pasteboard type
`org.nspasteboard.ConcealedType`; well-behaved clipboard recorders skip those.
MemorAI has no such check, so every password the user copies lands in a
plaintext JSONL file and in the menu-bar history. For an app whose whole job
is persisting the user's activity, honoring the concealed/transient markers is
the single highest-value privacy fix available, and it is a few lines.

## Current state

- `AutoRec/ClipboardMonitor.swift` — the only file to change.

The entry point, lines 28-39 as they exist today:

```swift
func checkAndSave(excludedBundleIds: [String]) {
    guard let storage = storageURL else { return }
    let current = pasteboard.changeCount
    guard current != lastChangeCount else { return }
    lastChangeCount = current

    // Skip excluded apps
    let frontApp = NSWorkspace.shared.frontmostApplication
    if let bundleId = frontApp?.bundleIdentifier,
       excludedBundleIds.contains(bundleId) {
        return
    }
```

There is no check of `pasteboard.types` for concealed/transient markers
anywhere in the file (verify: `grep -n "Concealed" AutoRec/ClipboardMonitor.swift`
→ no matches today).

Conventions: plain AppKit/Foundation, logging via the global `log()` function
(AutoRec/Logger.swift), no external dependencies.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build   | `swift build` (in repo root `MemorAI/`) | exit 0, "Build complete!" |

## Scope

**In scope**:
- `AutoRec/ClipboardMonitor.swift`

**Out of scope**:
- `AutoRec/ScreenMemoryManager.swift` (calls `checkAndSave`; signature must
  not change)
- Any scrubbing/migration of existing `clipboard.jsonl` data — that is user
  data outside the repo; note it in the final report instead.
- OCR capture of on-screen passwords — different surface, different plan.

## Git workflow

- Branch: `advisor/002-concealed-clipboard`. One commit, single-line
  imperative message. Do NOT push unless the operator instructed it.

## Steps

### Step 1: Skip concealed and transient pasteboard contents

In `checkAndSave`, immediately after the `lastChangeCount = current` line and
**before** the excluded-app check, add:

```swift
// Honor the de-facto standard privacy markers set by password managers
// and clipboard tools: never persist concealed or transient contents.
// http://nspasteboard.org
let privacyMarkers: [NSPasteboard.PasteboardType] = [
    NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
]
if let types = pasteboard.types, privacyMarkers.contains(where: types.contains) {
    log("[Clipboard] Skipped concealed/transient clipboard entry")
    return
}
```

Placement matters: after updating `lastChangeCount` (so the same concealed
copy isn't re-examined every 2 s poll), before any content is read.

**Verify**: `swift build` → exit 0.

### Step 2: Manual verification

1. Run the app: `bash bundle.sh && open MemorAI.app` (grant permissions if a
   fresh signature; if you cannot run a GUI in your environment, mark this
   step as skipped in your report rather than faking it).
2. Copy a password from a password manager (or simulate:
   `osascript -e 'set the clipboard to "sekret"'` will NOT set the concealed
   type — a real password-manager copy is needed for a true end-to-end check).
3. `tail -1 ~/Downloads/MemorAI/clipboard.jsonl` → the concealed copy must
   not appear; `grep "Skipped concealed" ~/Downloads/MemorAI/memorai.log` →
   at least one line.

**Verify**: as described, or explicitly reported as environment-skipped.

## Test plan

No test target exists; do not create one for this. The build gate plus the
grep-based done criteria below are the checks.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `grep -c "org.nspasteboard" AutoRec/ClipboardMonitor.swift` → 2 (or 3 with the comment URL)
- [ ] The new guard sits after `lastChangeCount = current` and before the
      excluded-app block (confirm by reading the function)
- [ ] `git status` shows only `AutoRec/ClipboardMonitor.swift` modified (plus plans/README.md)
- [ ] plans/README.md status row updated

## STOP conditions

- The `checkAndSave` excerpt doesn't match the live code.
- You are tempted to also filter "password-looking" strings heuristically —
  out of scope, STOP and report the idea instead (false positives would
  silently drop legitimate clipboard history).

## Maintenance notes

- If a settings UI is added later, "record concealed clipboard: off" could
  become a toggle, but off must stay the default.
- Existing `clipboard.jsonl` files may already contain copied secrets; the
  operator should be told to review/rotate anything sensitive and optionally
  scrub old entries. This plan intentionally does not touch user data.
- Reviewer: confirm the guard runs before any `pasteboard.string(...)` read.
