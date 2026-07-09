# Plan 010: `memorai search` — a retrieval surface over the captured data

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. Touch
> only in-scope files. On any STOP condition, stop and report. Commit in your
> worktree per the git workflow section. Do not update `plans/README.md` —
> the reviewer maintains the index.
>
> **Drift check (run first)**: Written against branch
> `advisor/004-cli-index-jsonl` @ `62bea0b` — this plan builds on the
> `emit_day_records` helper added there. Branch from that commit (or the
> owner's branch if 004 is merged). If `emit_day_records` is absent in your
> base, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW — read-only over the data; new subcommand only
- **Depends on**: plans/004-cli-readme-index-jsonl.md (DONE, branch `advisor/004-cli-index-jsonl`)
- **Category**: direction (stated-but-undelivered: README promises data "ready for AI-powered retrieval"; no read/search path exists)
- **Planned at**: `advisor/004-cli-index-jsonl` @ `62bea0b`, 2026-07-09

## Why this matters

MemorAI writes three searchable corpora — per-day screenshot OCR records
(`screen/YYYY-MM-DD/index.jsonl` + legacy per-shot `*.json`), clipboard
history (`clipboard.jsonl`), and call transcripts
(`call_*_transcript.txt`) — and offers no way to search any of them. The
README's first paragraph promises "a structured, searchable archive …
ready for AI-powered retrieval". This plan delivers the minimal honest
version: `memorai search <query>` with source and date filters, plain
substring/regex matching in Python (no index, no new dependencies). It also
becomes the building block an MCP server can later shell out to.

## Current state

- `memorai` (bash, post-plan-004) — has `get_output_path()` and
  `emit_day_records()` (emits day records as JSON lines, both formats,
  timestamp-sorted; added by plan 004). Dispatcher `case` at the bottom;
  `cmd_help` heredoc lists commands.
- Data shapes:
  - screen record fields: `timestamp` (ISO8601), `image_file`, `app_name`,
    `app_bundle_id`, optional `window_title`, `url`, `ocr_text`, `urls`,
    `emails`, `phones`, `file_paths`
  - clipboard line fields: `timestamp`, `app_name`, `app_bundle_id`,
    `type` (text/image/url/file/other), `content`
  - transcripts: plain text files `call_<YYYY-MM-DD_HH-mm-ss>_transcript.txt`
    in the output dir root
- Day dirs are named `YYYY-MM-DD` under `<output>/screen/`.

Conventions: bash + inline python3 heredocs, no jq, no pip packages.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Syntax  | `bash -n memorai` | exit 0 |

## Scope

**In scope**:
- `memorai` (new `cmd_search` + dispatcher + help)
- `README.md` (document the new command in the CLI section)

**Out of scope**:
- Any Swift source.
- SQLite/FTS indexing, embeddings, an MCP server — explicitly deferred;
  this plan is the plain-scan baseline (a day of OCR is a few MB; scanning
  a 30-day window stays subsecond).

## Git workflow

- Branch: `advisor/010-search` off `advisor/004-cli-index-jsonl` (or the
  owner's branch if merged). One or two commits. Do NOT push.
- Worktree: `git -C /Users/ilyababushkin/memory/MemorAI worktree add /tmp/claude/wt-010 advisor/004-cli-index-jsonl -b advisor/010-search` (adjust base if merged)

## Steps

### Step 1: Implement `cmd_search`

CLI contract (put it in `cmd_help` verbatim):

```
search <query> [--days N] [--source screen|clipboard|calls|all] [--regex] [--limit N]
    Search OCR text, clipboard history, and call transcripts.
    Defaults: --days 7, --source all, substring match (case-insensitive), --limit 50
```

Implementation: `cmd_search` parses flags in bash, computes the day list
(`date -v-<i>d +%Y-%m-%d` for i in 0..N-1 — BSD date), then calls ONE python3
heredoc that receives: query, regex flag, limit, output dir, the day list,
and source selection via argv/env. The python script:

- **screen**: for each day dir that exists, read records the same way
  `emit_day_records` does (reuse by piping `emit_day_records` output per day
  into the python process is awkward across days — instead, replicate the
  same read logic inside this one heredoc; keep field names identical).
  Match against `ocr_text`, `window_title`, `url`, `app_name`.
- **clipboard**: stream `clipboard.jsonl`, filter by timestamp prefix in the
  day set, match against `content` and `app_name`.
- **calls**: for `call_*_transcript.txt` whose filename date part is in the
  day set, scan line by line; report matching lines.
- Output, one hit per line, newest first, capped at limit:
  `2026-07-09T10:00:00  [screen]   Safari — <60-char context around match>`
  `2026-07-09T09:59:12  [clip]     Terminal — <60-char context>`
  `2026-07-08            [call]     call_..._transcript.txt: <matching line, 80 chars>`
- Case-insensitive substring by default; `--regex` switches to `re.search`
  with `re.IGNORECASE`. A bad regex prints `invalid regex: <msg>` to stderr,
  exit 1.
- No hits: print `no matches` and exit 0.

**Verify**: `bash -n memorai` → exit 0.

### Step 2: Fixture test

Build a fixture dir (never the real data dir) with all three corpora and a
stubbed copy of the script (same technique as plan 004's review: a copy with
`get_output_path()` overridden — the committed script keeps the real one):

```bash
T=$(mktemp -d /tmp/claude/search-test.XXXX)
TODAY=$(date +%Y-%m-%d)
mkdir -p "$T/screen/$TODAY"
printf '%s\n' "{\"timestamp\":\"${TODAY}T10:00:00Z\",\"app_name\":\"Safari\",\"window_title\":\"Docs\",\"ocr_text\":\"quarterly kickoff notes\"}" > "$T/screen/$TODAY/index.jsonl"
printf '%s\n' "{\"timestamp\":\"${TODAY}T09:00:00Z\",\"app_name\":\"Terminal\",\"type\":\"text\",\"content\":\"ssh kickoff-server\"}" > "$T/clipboard.jsonl"
printf 'we discussed the kickoff yesterday\nunrelated line\n' > "$T/call_${TODAY}_12-00-00_transcript.txt"
```

Expected:
- `search kickoff` → 3 hits (screen, clip, call), newest first
- `search kickoff --source clipboard` → exactly 1 hit
- `search KICKOFF` → same 3 hits (case-insensitive)
- `search 'kick.ff' --regex` → 3 hits
- `search zzzz` → `no matches`, exit 0
- `search '(' --regex` → stderr `invalid regex`, exit 1

**Verify**: run all six against the stubbed copy; paste actual outputs in
your report.

### Step 3: README

Add `search` to the CLI section of README.md with the same one-line summary
and an example.

**Verify**: `grep -n "memorai search\|search <query>" README.md` → 1+ match.

## Test plan

The six fixture cases in Step 2 are the tests; list exact commands and
outputs in the report.

## Done criteria

- [ ] `bash -n memorai` exits 0
- [ ] All six fixture cases produce the expected results
- [ ] `./memorai help` shows the search contract
- [ ] Real data dir untouched (stubbed copy only)
- [ ] Diff touches only `memorai` and `README.md`; `git status` clean

## STOP conditions

- `emit_day_records` missing from your base (wrong base commit).
- The flag parsing balloons past ~40 lines of bash — simplify to
  positional-plus-flags or STOP and propose moving the whole command into a
  single python heredoc with argparse (reviewer decision).

## Maintenance notes

- This is deliberately index-free. When day counts × record sizes make scans
  slow (rule of thumb: >2 s for --days 30), the follow-up is an SQLite FTS5
  index built incrementally from the same files — the CLI contract here
  should not change.
- An MCP server exposing this as a tool can shell out to `memorai search`
  as-is; keep the output format stable (one hit per line, tab-separable).
- Reviewer: check the timestamp-prefix day filtering for clipboard (string
  prefix match on ISO8601 is timezone-naive — the writer uses
  ISO8601DateFormatter UTC ("Z"), so "today" in local time may straddle two
  UTC dates; acceptable for v1, note it).
