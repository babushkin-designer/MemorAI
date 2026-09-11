# MemorAI

Remembers everything you do on your computer for AI.

MemorAI sits in your menu bar and silently captures your digital life — screen activity, clipboard history, and phone calls. Screenshots and dictation stay local; recorded calls use Deepgram for fast transcription when its Keychain API key is configured, with local whisper.cpp as the fallback. The result is a structured, searchable archive of your workday that's ready for AI-powered retrieval.

## Features

### Screen Memory
- **Periodic screenshots** — captures screen every N seconds (configurable 1–30s)
- **Smart change detection** — only saves when something actually changed (perceptual hash)
- **OCR** — a local RapidOCR ONNX Python sidecar extracts text from every screenshot (Russian + English)
- **Structured extraction** — URLs, emails, phone numbers parsed from OCR text
- **Metadata** — active app, window title, browser URL saved with each capture
- **App exclusions** — skip recording for specific apps (Telegram, YouTube, etc.)

### Clipboard History
- **Auto-capture** — saves every clipboard change (text, images, URLs, files)
- **Menu bar access** — last 100 entries in a dropdown, click to re-copy
- **Image previews** — thumbnails for screenshot/image clipboard entries
- **Persistent** — survives app restarts, stored as JSONL

### Call Recording
- **Auto-detection** — monitors mic usage, starts recording when a call begins (Zoom, Teams, FaceTime, etc.)
- **Dual-track audio** — system audio + microphone as separate files
- **Screen recording** — optional 10 fps H.264 capture during calls
- **Fast call transcription** — Deepgram first, local whisper.cpp fallback
- **Efficient codecs** — HE-AAC keeps files small (~5 MB/hour per track)

### General
- **Menu bar only** — colored dot: gray = idle, red = recording call
- **CLI tool** — `memorai` command for status, history, settings
- **Local-first controls** — screen memory and dictation are local; cloud call transcription can be disabled

## Build & Run

```bash
cd MemorAI
bash bundle.sh
open MemorAI.app
```

macOS 14+ required. On first launch, grant **Screen Recording**, **Microphone**, and **Accessibility** permissions.

Development checks require SwiftLint (`brew install swiftlint`):

```bash
tools/lint.sh
swift build
swift test
```

## Architecture

MemorAI is one deployable macOS application, organized as a modular monolith.
AppKit lifecycle and menu rendering live in `AppDelegate`; application work is
split into services under `AutoRec/Services`:

- `CallTranscriptionService` selects Deepgram or local Whisper and reports a
  provider-independent outcome.
- `CallMediaService` publishes mic segments, optionally removes echo, and
  muxes call audio into video.
- `CallLLMService` serializes titles, summaries, and follow-ups and owns
  provider pacing.
- `PostProcessor` is the durable scheduler around those services: it owns the
  recording gate, retries, manifests, and stage ordering.

These are in-process services rather than network microservices: audio files
are local, the workflows share one lifecycle, and splitting them into daemons
would add IPC and recovery failure modes without an independent scaling need.

## CLI

```bash
./memorai status              # app status, settings, today's stats
./memorai screenshots [date]  # list captures for a day
./memorai clipboard [count]   # show clipboard history
./memorai ocr [date] [count]  # show OCR text from screenshots
./memorai search <query> [--days N] [--source screen|clipboard|calls|all] [--regex] [--limit N]
                               # search OCR text, clipboard history, and call transcripts
                               # e.g. ./memorai search "kickoff" --days 14 --source screen
./memorai set <key> <value>   # change settings
./memorai exclude add|remove|list  # manage excluded apps
./memorai start|stop|restart  # control the app
```

## Menu Bar

- Start/Stop/Pause call recording
- Auto-detect Calls (on/off)
- Record Screen during calls (on/off)
- Auto-transcribe Calls (on/off)
- Use Deepgram for Calls (on/off; dictation remains local)
- Enhance Recorded Audio (slow, off by default)
- Screen Memory (on/off)
- Save Clipboard (on/off)
- Clipboard History (last 100 entries)
- Excluded Apps (add/remove from running apps)
- Output folder selection

## Data Structure

The data directory is whatever `defaults read com.local.memorai outputPath`
says; when that key is unset the app falls back to `~/Downloads/MemorAI/`.
Pick a location that survives your housekeeping — Downloads is a folder most
people periodically empty. Changing it: `defaults write com.local.memorai
outputPath -string <path>`, then quit and relaunch the app (a running app
keeps writing to the old path, and moving the folder alone does nothing —
the app just recreates the old one).

```
<outputPath>/                        # e.g. ~/Documents/MemorAI/
  memorai.log                        # app log
  clipboard.jsonl                    # clipboard history
  screen/
    2026-03-22/
      14-30-05.heif                  # screenshot
      index.jsonl                    # one JSON record per screenshot: {timestamp, image_file, app_name, window_title, ocr_text, urls, ...}
  call_<timestamp>_system.m4a       # system audio
  call_<timestamp>_mic.m4a          # microphone
  call_<timestamp>_screen.mp4       # screen (if enabled)
  call_<timestamp>_transcript.txt   # transcription (if enabled)
```

## Retention

Screenshots accumulate quickly, so `tools/retention.sh` deletes screenshot
*images* (`.jpg`/`.heif`/`.png`) older than 14 days (override with
`RETENTION_DAYS`). It never deletes OCR text (`index.jsonl`), clipboard
history, call recordings, or transcripts — those are kept forever. The same
script also caps `memorai.log`: once it exceeds 10 MB it's truncated in
place to the last 5 MB (the file's inode is preserved so the running app's
open log handle stays valid).

The app runs this policy itself once a day (see
`AutoRec/RetentionManager.swift`) — no scheduling setup is needed. A
LaunchAgent can NOT do this job on modern macOS: TCC denies `/bin/bash`
under launchd access to protected folders like `~/Downloads` and
`~/Documents`, so `memorai retention install` is kept only for data dirs
outside them. For a manual pass
from a terminal, run `memorai retention run`.

## Transcription Setup

For fast call transcription, store a Deepgram key in the login Keychain as a
generic password with service `deepgram-api-key` and account equal to your
macOS username. Disable **Use Deepgram for Calls** to keep calls local.

Local Whisper remains the offline fallback and powers button dictation:

```bash
brew install ffmpeg whisper-cpp
mkdir -p ~/.local/share/whisper-models
curl -L "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" \
  -o ~/.local/share/whisper-models/ggml-base.bin
```

For better Russian recognition, use `ggml-medium.bin` instead.

## OCR Setup

```bash
# find a Homebrew python3 (checked in this order)
/opt/homebrew/bin/python3 -m pip install rapidocr_onnxruntime || \
/usr/local/bin/python3 -m pip install rapidocr_onnxruntime
```

RapidOCR runs as a local Python sidecar (Russian + English); no cloud calls.

## License

MIT
