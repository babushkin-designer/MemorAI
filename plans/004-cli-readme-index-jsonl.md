# Plan 004: Make the CLI and README match the index.jsonl storage format

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: Written against commit `d02bcd3` (v1.5.0, the
> commit that introduced the JSONL screenshot index) with a dirty working
> tree. The `memorai` script and `README.md` were clean. Compare the "Current
> state" excerpts against the live files; on mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW — read-only inspection paths; the app itself is untouched
- **Depends on**: none
- **Category**: bug (stale tooling/docs after a format migration)
- **Planned at**: commit `d02bcd3`, 2026-07-09

## Why this matters

v1.5.0 changed screenshot metadata storage from one `HH-mm-ss.json` per
screenshot to a single per-day `index.jsonl`
(AutoRec/ScreenMemoryManager.swift:153 — `dayDir/index.jsonl`, appended by
AutoRec/JSONLWriter.swift). The `memorai` CLI still globs `*.json`, so
`memorai status` reports 0 screenshots and `memorai screenshots` / `memorai
ocr` show nothing for any day recorded since the migration. The README
documents the old layout and the old `.jpg` extension (images are now `.heif`,
ScreenMemoryManager.swift:152 / ScreenCapturer.swift:80). The data is being
written fine — the read tooling is just blind to it. Old pre-migration day
folders still contain `*.json` files (`tools/consolidate-jsons.sh` merges them),
so the CLI must read **both** formats.

## Current state

- `memorai` (bash script, repo root) — the CLI. Stale sites:
  - `cmd_status`, line 69: `count=$(ls "$screen_dir"/*.json 2>/dev/null | wc -l ...)`
  - `cmd_screenshots`, lines 100-112: `for f in "$screen_dir"/*.json; do ... python3 -c "... json.load(open('$f')) ..."`
  - `cmd_ocr`, lines 154-165: `ls "$screen_dir"/*.json 2>/dev/null | tail -n "$count" | while read f; do ...`
- `README.md`, lines 69-83 ("Data Structure") — shows per-shot
  `14-30-05.jpg` + `14-30-05.json`; reality is `HH-mm-ss.heif` +
  one `index.jsonl` per day dir. README line 10 says screenshots are captured
  "every N seconds (configurable 1–30s)" and line 12 says "OCR — Apple
  Vision"; OCR is now a RapidOCR Python sidecar
  (AutoRec/OCRProcessor.swift:3-9, AutoRec/ocr_sidecar.py).
- New-format record fields (written in ScreenMemoryManager.swift:161-165 +
  OCRProcessor.process): `timestamp` (ISO8601), `image_file`, `app_name`,
  `app_bundle_id`, optional `window_title`, `url`, `ocr_text`, `urls`,
  `emails`, `phones`, `file_paths`. Old per-shot `.json` files have the same
  field names (no `image_file`).
- `tools/consolidate-jsons.sh` — one-off migrator from old format; leave as-is.

Conventions: the CLI is plain bash + inline `python3 -c` heredocs; keep that
style (no new dependencies, no jq).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Syntax check | `bash -n memorai` | exit 0, silence |
| Smoke | `./memorai help` | usage text |

The Swift app is not rebuilt by this plan.

## Scope

**In scope**:
- `memorai` (bash script)
- `README.md`

**Out of scope**:
- Any Swift source — the writer side is correct.
- `tools/consolidate-jsons.sh`, `tools/retention.sh` — retention already
  handles `.heif`.
- The `.claude/` directory.

## Git workflow

- Branch: `advisor/004-cli-index-jsonl`. One commit per file is fine. Do NOT
  push unless instructed.

## Steps

### Step 1: Add a shared reader helper in `memorai`

Below `get_output_path()`, add a helper that emits every record for a day as
JSON lines, reading `index.jsonl` when present and falling back to (or
merging with) legacy per-shot `*.json` files:

```bash
# Emit all screenshot records for a day dir as JSON lines (new index.jsonl
# format plus any legacy per-shot .json files), sorted by timestamp.
emit_day_records() {
    local screen_dir="$1"
    python3 - "$screen_dir" << 'PYEOF'
import json, sys, glob, os
d = sys.argv[1]
records = []
idx = os.path.join(d, "index.jsonl")
if os.path.exists(idx):
    for line in open(idx, encoding="utf-8"):
        line = line.strip()
        if not line: continue
        try: records.append(json.loads(line))
        except json.JSONDecodeError: pass
for f in glob.glob(os.path.join(d, "*.json")):
    try: records.append(json.load(open(f, encoding="utf-8")))
    except Exception: pass
records.sort(key=lambda r: r.get("timestamp", ""))
for r in records:
    print(json.dumps(r, ensure_ascii=False))
PYEOF
}
```

**Verify**: `bash -n memorai` → exit 0.

### Step 2: Rewrite the three stale commands on top of the helper

- `cmd_status` screenshot count:
  `count=$(emit_day_records "$screen_dir" | wc -l | tr -d ' ')`
- `cmd_screenshots`: pipe `emit_day_records "$screen_dir"` into a single
  `python3 -c` that reads stdin lines and prints `ts / app / title` (same
  output columns as today, replacing the per-file loop).
- `cmd_ocr`: `emit_day_records "$screen_dir" | tail -n "$count"` piped into a
  python stdin reader printing the same `--- ts [app] ---` + `ocr_text[:200]`
  blocks as today.

Keep output formats byte-compatible with the current ones where records exist
(same columns, truncations, separators) so any user scripts keep working.

**Verify**: create a fixture and run all three:

```bash
TMP=$(mktemp -d /tmp/claude/memorai-test.XXXX)
mkdir -p "$TMP/screen/2026-07-09"
printf '%s\n' '{"timestamp":"2026-07-09T10:00:00Z","app_name":"Safari","window_title":"Test","ocr_text":"hello","image_file":"10-00-00.heif"}' > "$TMP/screen/2026-07-09/index.jsonl"
printf '%s' '{"timestamp":"2026-07-09T09:00:00Z","app_name":"Old","window_title":"Legacy","ocr_text":"legacy"}' > "$TMP/screen/2026-07-09/09-00-00.json"
```

Temporarily run with `defaults write com.local.memorai outputPath "$TMP"`
(**restore the previous value afterwards** — read it first with
`defaults read com.local.memorai outputPath 2>/dev/null`; if it was unset,
`defaults delete com.local.memorai outputPath`):

- `./memorai screenshots 2026-07-09` → two rows, Legacy (09:00) before Test (10:00)
- `./memorai ocr 2026-07-09 5` → both `legacy` and `hello` blocks
- `./memorai status` → `Screenshots:      2 (...)`

### Step 3: Update README.md

- "Data Structure" block (lines 69-83): show
  `screen/2026-03-22/14-30-05.heif` and `screen/2026-03-22/index.jsonl  # one JSON record per screenshot`,
  drop the per-shot `.json` line.
- Line 12: change "OCR — Apple Vision extracts text" to describe the RapidOCR
  ONNX Python sidecar (Russian + English), and add its setup requirement:
  `pip3 install rapidocr_onnxruntime` for a Homebrew python3
  (OCRProcessor.swift:14-17 probes `/opt/homebrew/bin/python3` then
  `/usr/local/bin/python3`). Add this under "Transcription Setup" as a new
  short "OCR Setup" section.
- Line 39 (`cd side-projects/memorAI`): fix to `cd MemorAI` (stale path).

**Verify**: `grep -n "index.jsonl" README.md` → 1+ match;
`grep -n "14-30-05.json\b" README.md` → no matches.

## Test plan

Fixture-based CLI checks in Step 2 are the tests (this repo has no test
harness for bash). List in your report the exact commands run and outputs.

## Done criteria

- [ ] `bash -n memorai` exits 0
- [ ] `grep -c '\*\.json' memorai` → only the legacy-glob inside
      `emit_day_records` remains (1 match)
- [ ] Step 2 fixture run produces the three expected outputs
- [ ] README shows `.heif` + `index.jsonl`, RapidOCR OCR section, fixed build path
- [ ] `git status` shows only `memorai` and `README.md` modified (plus plans/README.md)
- [ ] plans/README.md status row updated

## STOP conditions

- The `memorai` script or writer-side Swift no longer matches the excerpts.
- `defaults read com.local.memorai outputPath` points at a real data dir you
  cannot safely restore — do the fixture test by exporting a modified copy of
  the script with `get_output_path` stubbed instead of touching defaults.

## Maintenance notes

- Any future storage-format change must update `emit_day_records` (single
  choke point now) and the README block together.
- Legacy `*.json` support can be dropped once `tools/consolidate-jsons.sh`
  has been run on all historical data — leave a TODO comment in
  `emit_day_records` saying exactly that.
- Reviewer: check the sort key tolerates records missing `timestamp`.
