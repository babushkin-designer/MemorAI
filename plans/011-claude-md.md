# Plan 011: Add CLAUDE.md so agents onboard the fork correctly

> **Executor instructions**: Follow this plan step by step. Run every
> verification command before moving on. Touch only in-scope files. On any
> STOP condition, stop and report. Commit in your worktree per the git
> workflow section. Do not update `plans/README.md` — the reviewer maintains
> the index.
>
> **Drift check (run first)**: Written against commit `d02bcd3`, 2026-07-09.
> If a `CLAUDE.md` or `AGENTS.md` already exists at your base, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW — docs only
- **Depends on**: none (content references plans 001–004; if they aren't
  merged yet the text below is still accurate — it describes the target
  state and the plans/ process)
- **Category**: dx
- **Planned at**: commit `d02bcd3`, 2026-07-09

## Why this matters

This fork is developed largely by AI agents (plans in `plans/` are executed
by model subagents). There is no `CLAUDE.md`, so every agent session
re-derives the build command, the data layout, and the repo's sharp edges
(TCC permissions, live-app state, the two storage formats). One page fixes
that permanently.

## Current state

- No `CLAUDE.md`, `AGENTS.md`, or `CONTRIBUTING` anywhere in the repo
  (verify: `ls CLAUDE.md AGENTS.md 2>/dev/null` → nothing).
- Facts the file must capture are inlined in Step 1 — they were verified
  against the codebase on 2026-07-09.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| None beyond git | — | — |

## Scope

**In scope**: `CLAUDE.md` (new file, repo root).
**Out of scope**: everything else. No README changes.

## Git workflow

- Branch: `advisor/011-claude-md` off `d02bcd3`. One commit. Do NOT push.
- Worktree: `git -C /Users/ilyababushkin/memory/MemorAI worktree add /tmp/claude/wt-011 -b advisor/011-claude-md`

## Steps

### Step 1: Write CLAUDE.md

Create `CLAUDE.md` with exactly this content (fix nothing, add nothing
beyond formatting):

```markdown
# MemorAI — agent notes

macOS menu-bar app (Swift/AppKit, SwiftPM, no external deps) that records
screen activity (screenshots + OCR), clipboard, and calls (dual-track audio,
optional screen video, whisper.cpp transcription). All data local. This is a
personal fork; do not push to any remote.

## Build / verify

- `swift build` — the primary gate (repo root). ~10 s warm.
- `swift test` — only if the test target exists (see plans/006).
- `bash bundle.sh` — builds MemorAI.app and codesigns it (stable identity so
  macOS TCC permissions survive rebuilds). Needed only to run the GUI.
- CLI checks: `bash -n memorai`.

## Layout

- `AutoRec/` — all Swift sources (single executable target `MemorAI`).
  Key files: AppDelegate (menu bar UI + lifecycle), RecordingManager
  (start/stop state machine), SystemAudioRecorder (SCStream: system audio +
  screen), MicRecorder (AVAudioEngine), CallDetector (CoreAudio per-process
  mic usage), ScreenMemoryManager (screenshot loop), OCRProcessor (RapidOCR
  Python sidecar — `ocr_sidecar.py`), Transcriber (ffmpeg + whisper-cli
  subprocesses), ClipboardMonitor, SettingsManager (UserDefaults,
  domain `com.local.memorai`), Logger (global `log()` → memorai.log).
- `memorai` — bash CLI over the app's data and defaults.
- `tools/` — retention/maintenance scripts.
- `plans/` — advisor-written implementation plans; read `plans/README.md`
  for status before starting work. Executors work in git worktrees on
  `advisor/NNN-*` branches, never in the main working tree.

## Data (runtime, NOT in the repo)

`~/Downloads/MemorAI/` by default (`defaults read com.local.memorai
outputPath` overrides): `screen/YYYY-MM-DD/HH-mm-ss.heif` +
per-day `index.jsonl` (one JSON record per screenshot; legacy per-shot
`HH-mm-ss.json` files exist in old day dirs — read both),
`clipboard.jsonl`, `call_*_{system,mic}.m4a`, `call_*_screen.mp4`,
`call_*_transcript.txt`, `memorai.log`.

## Sharp edges

- The app is usually RUNNING on this machine. Never mutate the
  `com.local.memorai` defaults domain, never kill the app, and never write
  into the real data dir from tests — use fixture dirs and stubbed copies
  of the CLI.
- Subprocess calls must drain stdout/stderr concurrently (pipe-buffer
  deadlock; see Transcriber.runProcess) — reuse `runProcess`, don't add raw
  `waitUntilExit`-then-read code.
- macOS TCC: Screen Recording / Microphone / Accessibility permissions are
  tied to the codesign identity; ad-hoc signing resets them每 rebuild —
  bundle.sh handles this, don't bypass it.
- External binaries are resolved from Homebrew paths at runtime: ffmpeg,
  whisper-cli, python3 (+ `rapidocr_onnxruntime` for OCR).
- Conventions: no external Swift dependencies; callbacks over delegates;
  all logging through the global `log()`; single-line imperative commit
  messages.
```

Note: the string "每 rebuild" in the draft above is a typo artifact — write
"on every rebuild" instead.

**Verify**: `test -f CLAUDE.md && grep -c "swift build" CLAUDE.md` → ≥ 1;
`grep -c "每" CLAUDE.md` → 0.

## Test plan

Docs-only; grep gates above.

## Done criteria

- [ ] `CLAUDE.md` exists at repo root with the content above (typo fixed)
- [ ] Diff touches only `CLAUDE.md`; `git status` clean after commit

## STOP conditions

- `CLAUDE.md`/`AGENTS.md` already exists at your base.

## Maintenance notes

- When plans 001–010 merge, nothing here goes stale (the file describes
  post-merge behavior for runProcess and the CLI). If the storage format or
  default output dir changes, update the Data section in the same PR.
