# MemorAI — agent notes

macOS menu-bar app (Swift/AppKit, SwiftPM, no external deps) that records
screen activity (screenshots + OCR), clipboard, and calls (dual-track audio,
optional screen video, Deepgram-first call transcription with whisper.cpp
fallback, and local whisper.cpp dictation). Screen memory and dictation stay
local; call audio leaves the machine only when Deepgram is enabled. This is a
personal fork; do not push to any remote.

## Build / verify

- `swift build` — the primary gate (repo root). ~10 s warm.
- `tools/lint.sh` — strict SwiftLint gate. The repository has no lint baseline;
  every configured warning fails the command.
- `swift test` — 169 tests; must stay offline and must never touch the real
  data dir (fixture dirs only). ffmpeg/AEC-dependent tests skip themselves
  where those are not installed.
- `bash bundle.sh` — builds MemorAI.app and codesigns it (stable identity so
  macOS TCC permissions survive rebuilds). Needed only to run the GUI.
  Deploy: `bash bundle.sh` then `ditto MemorAI.app /Applications/MemorAI.app`
  — NOT install.sh, which ad-hoc signs and resets TCC.
- CLI checks: `bash -n memorai`.

## Layout

- `AutoRec/` — all Swift sources (single executable target `MemorAI`, organized
  as an in-process modular monolith).
  Key files: AppDelegate (menu bar UI + lifecycle), RecordingManager
  (start/stop state machine, `@MainActor`), SystemAudioRecorder (SCStream:
  system audio + screen), MicRecorder (AVAudioEngine), CallDetector (CoreAudio
  per-process mic usage), PostProcessor + CallSessionManifest (durable stage
  scheduler after the recorders stop), `Services/CallTranscriptionService`
  (Deepgram/Whisper selection), `Services/CallMediaService` (stitch/AEC/mux),
  `Services/CallLLMService` (serialized title/summary/follow-up jobs),
  MicStitcher (joins mic segments), EchoCanceller
  (`aec_sidecar.py`), AudioMuxer, ScreenMemoryManager (screenshot loop),
  OCRProcessor (RapidOCR Python sidecar — `ocr_sidecar.py`), Transcriber
  (ffmpeg + whisper-cli subprocesses), ClipboardMonitor, SettingsManager
  (UserDefaults, domain `com.local.memorai`), Logger (global `log()` →
  memorai.log).
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

Work files live in the same folder and are NOT recordings: `_mic.part<N>.m4a`
/ `.caf` (segments awaiting the stitcher), `_mic.stitching.m4a`,
`_screen.muxing.mp4` (ffmpeg temporaries), `_session.json` (the post-processing
manifest, present only while a session is unfinished), `_track_<tag>_*.wav` /
`_chunk_<tag>_*.wav` / `_whisper_<tag>_*.json` (the transcription's per-chunk
cache; the JSONs outlive a pause on purpose and are swept when the transcript
is written or the session is given up on). `_mic.aec.m4a` IS data —
the echo-cancelled mic, kept next to the raw one.

## Call pipeline

Where one recording ends: CallDetector polls which OTHER processes hold the
mic. A free mic while system audio plays used to keep recording — Electron call
apps release the mic on mute, and the far side is still worth having. That rule
is now scoped to the app that was holding the mic (`kAudioProcessPropertyIs`
`RunningOutput` on the same per-process API): the far side through Pachca keeps
the session, Spotify after the meeting does not, and back-to-back calls land in
separate files. Threshold `CallDetector.splitAfterCallAppQuiet` (180 s) is a
starting point, NOT a measurement — every mic release and re-acquisition is
logged with its duration so it can be set from real calls. Before this, one
session ran 07:12–11:38 UTC on 2026-09-01: four meetings, five mic releases, one
4.4-hour transcript.

Recording: SystemAudioRecorder writes `_system.m4a` + `_screen.mp4`;
MicRecorder writes `_mic.part<N>` segments (a new one on every engine restart —
device switches change the format, and a file's format is fixed when opened).

Post-processing (PostProcessor, off a `_session.json` manifest written at
start): publish `_mic.m4a` from the segments → Deepgram call transcription
(two source tracks uploaded concurrently; local Whisper fallback) → optional
EchoCanceller → AudioMuxer. Each stage is idempotent and recorded as it completes, so quitting
or crashing mid-pipeline only costs the stage in flight; the next launch calls
`resumeUnfinishedSessions()` and finishes the rest. Quit waits for the writers
only — never for ffmpeg or whisper.

CPU-heavy post-processing NEVER runs while a recording is in progress. The gate closes
before the recorders start (`PostProcessor.setRecordingActive`), terminates the
child process in flight, and reopens 15 s after the session stops; the deferred
session is picked back up off its manifest. A Deepgram upload that was already
in flight may finish because it is network-only; its completed transcript is
preserved before the pipeline defers AEC/mux. Whisper on the GPU plus the AEC
sidecar on top of a live call is what made the speakers crackle mid-conversation
(measured 2026-08-19: whisper 08:17:53–08:25:41 across a call recorded
08:20:12–08:33:34). A stage cut short must NOT be recorded as done — an
interrupted AEC otherwise passes for "declined" and the call keeps the raw mic
forever, and an interrupted transcription for a finished transcript with a
ten-minute hole in it. The gate is checked between stages AND inside the
transcription's own chunk loop — killing the child in flight only frees the
machine until the next chunk starts, and a long call is dozens of whisper runs
(measured 2026-09-01: a 4.4 h call's transcription ran straight through the
whole of the next call). Each chunk's whisper JSON stays on disk until the
transcript is written, so a resumed run costs the interrupted chunk, not the
hours before it; a chunk whisper fails on gets one retry, and a chunk lost
after that is logged with the timestamps it covers rather than silently
dropped. Post-processing children run through `ProcessRunner` with
`role: .postProcessing` (utility QoS + nice 10, cancellable as a group);
`.background` was measured at 2.6x slower and is not worth it now that the gate
removes the overlap. Screen memory + OCR and dictation (its third audio engine
and resident whisper-server) also stand down for the duration of a call.

`AudioGlitchMonitor` is the instrument for all of this: it counts
`kAudioDeviceProcessorOverload` on the default output/input while recording and
stamps each event with the stage to blame, and it photographs (read-only, never
sets) buffer frame size / sample rate around each recorder's start and stop.
`tools/glitch-probe.sh` is the causal test — it SIGSTOPs the heavy children for
a few seconds mid-crackle and resumes them.

Invariants worth not breaking:
- `call_<tag>_mic.m4a` appears only when it holds the WHOLE track. A failed
  stitch leaves it absent and the parts on disk; downstream then honestly runs
  without a mic track.
- Track alignment comes from host-clock starts (`AudioMuxer.computeOffsets`),
  used by both the muxer and the speaker-labeled transcript.
- MicRecorder's tap runs on the audio thread: shared state is `_`-prefixed and
  guarded by `UnfairLock`, and the tap NEVER tears anything down — it posts one
  main-queue event and the main queue owns the engine.
- Echo cancellation is OFFLINE only. Apple voice processing reconfigures the
  shared input device for every app on the machine and degraded a real meeting;
  the live path was removed on purpose, do not bring it back.
- EchoCanceller thresholds in `verdict` are set from measurements on real calls
  (voice −0.07 dB at 0.997 correlation, 9–25 dB of echo removed) — do not
  retune them without new measurements. The sidecar aligns the tracks itself by
  cross-correlation; unaligned input drops cancellation from 24.7 dB to 0.7.

## Sharp edges

- The app is usually RUNNING on this machine. Never mutate the
  `com.local.memorai` defaults domain, never kill the app, and never write
  into the real data dir from tests — use fixture dirs and stubbed copies
  of the CLI.
- Subprocess calls must drain stdout/stderr concurrently (pipe-buffer
  deadlock; see Transcriber.runProcess) — reuse `runProcess`, don't add raw
  `waitUntilExit`-then-read code.
- Every child has to be taken down on quit. `applicationShouldTerminate`
  cancels the `.postProcessing` group and stops the OCR sidecar; without that
  they outlive the app (seen 2026-09-01: an AEC and an OCR sidecar still
  running after the app was gone). A new resident sidecar needs the same.
- Nothing may claim a capture is kept before it is on disk. ClipboardMonitor
  advances `lastChangeCount` only after the append succeeds, so a failed write
  is retried on the next poll instead of skipped forever; the append throws
  (and catches JSONSerialization's ObjC *raise*) rather than swallowing.
- Durations come from the container header — `ffmpeg -i file` with no output.
  `-f null -` decodes the whole track; on a 4-hour call it just burned the
  timeout and then parsed the same header line anyway.
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
