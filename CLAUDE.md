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

Location comes from `defaults read com.local.memorai outputPath`; the
built-in fallback when that key is unset is `~/Downloads/MemorAI/`. On this
machine the key IS set, to `~/Documents/MemorAI/` — always read the pref, do
not assume the fallback. Contents: `screen/YYYY-MM-DD/HH-mm-ss.heif` +
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
  tied to the codesign identity; ad-hoc signing resets them on every rebuild —
  bundle.sh handles this, don't bypass it.
- External binaries are resolved from Homebrew paths at runtime: ffmpeg,
  whisper-cli, python3 (+ `rapidocr_onnxruntime` for OCR).
- Conventions: no external Swift dependencies; callbacks over delegates;
  all logging through the global `log()`; single-line imperative commit
  messages.

## LLM layer (summary / follow-up, plan 012)

- Manual only, from the Recent Calls submenu. Writes `call_<tag>_summary.md`
  / `_followup.md` next to the transcript.
- OpenAI-compatible chat completions: default provider Bluesminds
  (`gpt-5.5`; claude-* NOT enabled on this key), fallback OpenAI direct.
  Keys are macOS Keychain generic passwords `bluesminds-api-key` /
  `openai-api-key` (account = current user) — never .env, never log keys.
- HARD RULE: on 429 `insufficient_quota` stop and alert; never retry (past
  the free daily allowance OpenAI silently bills real money). Retry (max 2)
  only on transport/5xx. Always cap max_tokens and log usage tokens.
- `swift test` must stay offline — network calls live only in thin
  LLMClient.post; everything parseable is a pure static helper with tests.
