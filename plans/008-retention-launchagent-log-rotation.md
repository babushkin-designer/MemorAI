# Plan 008: Schedule retention and cap the log — finish the disk-hygiene story

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. Touch
> only in-scope files. On any STOP condition, stop and report. Commit in your
> worktree per the git workflow section. Do not update `plans/README.md` —
> the reviewer maintains the index.
>
> **Drift check (run first)**: Written against commit `d02bcd3`, 2026-07-09.
> CAVEAT: `tools/retention.sh` is UNTRACKED in the fork owner's working tree
> — your worktree from `d02bcd3` will NOT contain it. Its full current
> content is inlined below; Step 1 commits it verbatim first. If a tracked
> `tools/retention.sh` already exists in your base commit with different
> content, that's drift — STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW — new files + additive CLI subcommand; retention deletes only image files older than N days, and only under the MemorAI screen dir
- **Depends on**: none (merge note: the owner's tree has an untracked
  `tools/retention.sh`; merging this branch will require removing that
  untracked copy first — flag it in your report)
- **Category**: dx
- **Planned at**: commit `d02bcd3`, 2026-07-09

## Why this matters

Screenshots accumulate at hundreds of MB per day; `tools/retention.sh`
already implements the policy (delete images older than 14 days, keep OCR
text forever) but nothing ever runs it. `memorai.log` (written by
`AutoRec/Logger.swift`, appended forever, never rotated) grows unboundedly.
This plan ships the missing scheduling: a LaunchAgent that runs retention
daily, log truncation folded into the same script, and a `memorai retention`
CLI verb to install/run/check it.

## Current state

- `tools/retention.sh` — exists only as an untracked file in the owner's
  tree. Full current content (commit this verbatim in Step 1):

```bash
#!/bin/bash
# MemorAI screenshot retention.
# Deletes screenshot image files older than RETENTION_DAYS, but keeps the OCR
# text (index.jsonl) forever — text is the searchable asset, images are just a
# visual cache. Day folders left with only index.jsonl are kept; fully empty
# ones are pruned.
set -e
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DIR="$HOME/Downloads/MemorAI/screen"
LOG="$HOME/Downloads/MemorAI/memorai.log"

[ -d "$DIR" ] || exit 0

before=$(find "$DIR" -type f \( -name '*.jpg' -o -name '*.heif' -o -name '*.png' \) | wc -l | tr -d ' ')
find "$DIR" -type f \( -name '*.jpg' -o -name '*.heif' -o -name '*.png' \) -mtime +"$RETENTION_DAYS" -delete
after=$(find "$DIR" -type f \( -name '*.jpg' -o -name '*.heif' -o -name '*.png' \) | wc -l | tr -d ' ')
# Remove day folders that have become completely empty.
find "$DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [retention] kept text, removed $((before - after)) images older than ${RETENTION_DAYS}d" >> "$LOG"
```

- Known limitation to fix while touching it: the script hardcodes
  `$HOME/Downloads/MemorAI`, but the output dir is configurable
  (`defaults read com.local.memorai outputPath`, empty = that default —
  the same resolution the CLI does in `memorai`'s `get_output_path()`).
- `memorai` (bash CLI, repo root) — dispatcher at the bottom:

```bash
case "${1:-help}" in
    status)       cmd_status ;;
    start)        cmd_start ;;
    ...
    help|--help|-h) cmd_help ;;
    *)            echo "Unknown command: $1"; cmd_help ;;
esac
```

- `AutoRec/Logger.swift` — appends to `<outputPath>/memorai.log`, keeps a
  cached FileHandle. IMPORTANT interaction: truncating the log while the app
  holds a seek-to-end handle makes the handle's offset point past EOF; on
  APFS the next write produces a sparse gap, not corruption — acceptable.
  Rotation must therefore move-and-recreate, not edit in place… but the app
  would keep writing to the moved inode. Simplest correct approach for a
  menu-bar app: `tail -c` the last N bytes into a temp file and `cat` it
  back over the original (same inode, offset stays valid, file shrinks; the
  next app write may leave one sparse gap — harmless). Do it that way.

Conventions: plain bash, no new dependencies; CLI style matches existing
`cmd_*` functions.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Syntax  | `bash -n tools/retention.sh && bash -n memorai` | exit 0 |
| Plist lint | `plutil -lint tools/com.local.memorai.retention.plist` | "OK" |

## Scope

**In scope**:
- `tools/retention.sh` (commit + extend)
- `tools/com.local.memorai.retention.plist` (new)
- `memorai` (add `retention` subcommand + help text)
- `README.md` (short "Retention" section)

**Out of scope**:
- `AutoRec/Logger.swift` — no Swift changes; rotation is done by the script
  the safe way described above.
- Actually LOADING the LaunchAgent on this machine (`launchctl bootstrap`) —
  installation is the owner's action; the CLI subcommand automates it for
  them, you only verify it dry-runs.

## Git workflow

- Branch: `advisor/008-retention` off `d02bcd3`. Commit per step. Do NOT push.
- Worktree: `git -C /Users/ilyababushkin/memory/MemorAI worktree add /tmp/claude/wt-008 -b advisor/008-retention`

## Steps

### Step 1: Commit retention.sh verbatim, then generalize it

Create `tools/retention.sh` with the inlined content above, `chmod +x`,
commit ("Add retention script (previously untracked)"). Then modify:

- Resolve the data dir like the CLI does:
  ```bash
  DIR_BASE=$(defaults read com.local.memorai outputPath 2>/dev/null)
  [ -z "$DIR_BASE" ] && DIR_BASE="$HOME/Downloads/MemorAI"
  DIR="$DIR_BASE/screen"
  LOG="$DIR_BASE/memorai.log"
  ```
- Append log-cap logic after the image cleanup (cap 10 MB, keep last 5 MB):
  ```bash
  MAX_LOG_BYTES=$((10 * 1024 * 1024))
  KEEP_BYTES=$((5 * 1024 * 1024))
  if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt "$MAX_LOG_BYTES" ]; then
      tail -c "$KEEP_BYTES" "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG" && rm -f "$LOG.tmp"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [retention] truncated memorai.log to last ${KEEP_BYTES} bytes" >> "$LOG"
  fi
  ```
  (`cat >` over the file, NOT `mv` — preserves the inode the running app
  holds open; see Current state.)

**Verify**: `bash -n tools/retention.sh` → exit 0. Functional check against a
fixture (never against the real data dir): set `DIR_BASE` override support
first — change the resolution to honor an env override:
`DIR_BASE="${MEMORAI_DIR:-$(defaults read ... )}"`. Then:

```bash
T=$(mktemp -d /tmp/claude/ret-test.XXXX); mkdir -p "$T/screen/2020-01-01"
touch -t 202001010101 "$T/screen/2020-01-01/old.heif"
printf 'x%.0s' $(seq 1 11000000) > "$T/memorai.log"
MEMORAI_DIR="$T" bash tools/retention.sh
[ ! -f "$T/screen/2020-01-01/old.heif" ] && [ "$(stat -f%z "$T/memorai.log")" -lt 6000000 ] && echo PASS
```
→ prints `PASS`.

### Step 2: Add the LaunchAgent plist

`tools/com.local.memorai.retention.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.local.memorai.retention</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__RETENTION_SH__</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
    <key>RunAtLoad</key><false/>
</dict>
</plist>
```

`__RETENTION_SH__` is a placeholder the installer substitutes (Step 3) with
the absolute path of the script — keep it literal in the committed file.

**Verify**: `sed "s|__RETENTION_SH__|/tmp/x.sh|" tools/com.local.memorai.retention.plist | plutil -lint -` → "OK" (lint the substituted form; the raw template also lints OK since the placeholder is just a string).

### Step 3: Add `memorai retention` subcommand

New `cmd_retention` in `memorai` + dispatcher entry + help text:

- `memorai retention run` — exec the script (resolve it relative to the CLI:
  `"$(dirname "$0")/tools/retention.sh"`, fall back to
  `/Applications/MemorAI.app`-adjacent if you follow the existing
  `APP_PATH` pattern at the top of the script — match how `APP_PATH` is
  resolved).
- `memorai retention install` — substitute the placeholder and install:
  ```bash
  plist_src="$(dirname "$0")/tools/com.local.memorai.retention.plist"
  target="$HOME/Library/LaunchAgents/com.local.memorai.retention.plist"
  sed "s|__RETENTION_SH__|$(cd "$(dirname "$0")" && pwd)/tools/retention.sh|" "$plist_src" > "$target"
  launchctl bootstrap "gui/$(id -u)" "$target" 2>/dev/null || launchctl load "$target"
  echo "Installed: runs daily at 04:30"
  ```
- `memorai retention uninstall` — `launchctl bootout` + remove the plist.
- `memorai retention status` — `launchctl list | grep com.local.memorai.retention || echo "not installed"`.

Do NOT run `install` yourself — only `bash -n` and `retention status`
(read-only) as verification.

**Verify**: `bash -n memorai` → exit 0; `./memorai help | grep retention` →
shows the new verb; `./memorai retention status` → prints "not installed"
(or the loaded entry if the owner already has one — either output is a pass).

### Step 4: README section

Add a short "Retention" section after "Data Structure": what it deletes
(images > 14 days, override `RETENTION_DAYS`), what it never deletes (OCR
text, clipboard, calls, transcripts), log cap behavior, and
`memorai retention install`.

**Verify**: `grep -n "retention" README.md` → 2+ matches.

## Test plan

The fixture check in Step 1 is the behavioral test. Everything else is
lint/grep-gated.

## Done criteria

- [ ] `bash -n tools/retention.sh && bash -n memorai` exit 0
- [ ] Step 1 fixture prints PASS (old image deleted, log capped, run against MEMORAI_DIR fixture only)
- [ ] plist lints OK
- [ ] `./memorai retention status` runs without error
- [ ] Real data dir untouched: you never ran the script without `MEMORAI_DIR` set
- [ ] `git status` clean after commits; diff touches only the four in-scope files

## STOP conditions

- A tracked `tools/retention.sh` exists at your base commit with content
  differing from the inlined version.
- Anything requires writing to `~/Library/LaunchAgents` or the real
  `~/Downloads/MemorAI` during verification — that's install-time, not
  build-time; STOP rather than touch live user state.

## Maintenance notes

- If the owner changes `outputPath` via the app, retention follows it on the
  next run (defaults-based resolution) — no reinstall needed.
- If plan 010 (search) adds an SQLite index later, retention must NOT delete
  `index.jsonl` — it already never does; keep it that way.
- Reviewer: check the `cat > LOG` truncation (inode-preserving) wasn't
  "simplified" into `mv`.
