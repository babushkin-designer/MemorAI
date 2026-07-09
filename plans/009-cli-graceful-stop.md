# Plan 009: Make `memorai stop` graceful and process matching precise

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. Touch
> only in-scope files. On any STOP condition, stop and report. Commit in your
> worktree per the git workflow section. Do not update `plans/README.md` —
> the reviewer maintains the index.
>
> **Drift check (run first)**: Written against branch
> `advisor/004-cli-index-jsonl` @ `62bea0b` (the CLI was rewritten there;
> this plan edits the post-004 script). Branch from that commit or from the
> owner's branch if 004 is merged. Compare excerpts; on mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/004-cli-readme-index-jsonl.md (DONE, branch
  `advisor/004-cli-index-jsonl`); pairs with plan 003 (graceful
  `applicationShouldTerminate`) — without 003 in the app, a graceful quit
  request still corrupts nothing extra, so this is a soft dependency.
- **Category**: bug / dx
- **Planned at**: `advisor/004-cli-index-jsonl` @ `62bea0b`, 2026-07-09

## Why this matters

Two problems in the `memorai` CLI's process management:

1. `pkill -f "MemorAI"` matches the **full command line** of every process —
   it will kill a `tail -f ~/Downloads/MemorAI/memorai.log`, an editor with
   the repo open by path, or any script whose argv mentions the folder.
   Same for `pgrep -f "MemorAI"` in `cmd_status`/`cmd_start` (false
   "RUNNING").
2. `pkill` sends SIGTERM directly. With plan 003 landed, the app finalizes
   recordings on a normal quit — but the CLI should request that quit
   through AppKit (`osascript`) so `applicationShouldTerminate` runs, with
   the signal only as fallback.

## Current state

File: `memorai` (bash, repo root; post-plan-004 state — the `cmd_*`
functions below are unchanged by 004):

```bash
cmd_status() {
    ...
    if pgrep -f "MemorAI" > /dev/null 2>&1; then
        echo "App:              RUNNING"
    ...

cmd_start() {
    if pgrep -f "MemorAI" > /dev/null 2>&1; then
        echo "MemorAI is already running"
    else
        open "$APP_PATH"
        echo "MemorAI started"
    fi
}

cmd_stop() {
    pkill -f "MemorAI" 2>/dev/null && echo "MemorAI stopped" || echo "MemorAI is not running"
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}
```

The app binary is named `MemorAI` (bundle `com.local.memorai`), so
`pgrep -x MemorAI` matches exactly the app process and nothing else.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Syntax  | `bash -n memorai` | exit 0 |

## Scope

**In scope**: `memorai` only.

**Out of scope**: Swift sources; README (the CLI help text inside `memorai`
is fine to touch if wording changes).

## Git workflow

- Branch: `advisor/009-cli-graceful-stop` off `advisor/004-cli-index-jsonl`
  (or the owner's branch if merged). One commit. Do NOT push.
- Worktree: `git -C /Users/ilyababushkin/memory/MemorAI worktree add /tmp/claude/wt-009 advisor/004-cli-index-jsonl -b advisor/009-cli-graceful-stop` (adjust base if merged)

## Steps

### Step 1: Exact-match process detection

Add a helper near `get_output_path` and use it in `cmd_status` and
`cmd_start`:

```bash
app_running() { pgrep -x "MemorAI" > /dev/null 2>&1; }
```

Replace both `pgrep -f "MemorAI"` call sites with `app_running`.

**Verify**: `bash -n memorai` → exit 0; `grep -c 'pgrep -f' memorai` → 0.

### Step 2: Graceful stop with signal fallback

Replace `cmd_stop`:

```bash
cmd_stop() {
    if ! app_running; then
        echo "MemorAI is not running"
        return
    fi
    # Ask AppKit to quit so applicationShouldTerminate can finalize
    # in-flight recordings; fall back to SIGTERM if that fails.
    osascript -e 'tell application id "com.local.memorai" to quit' 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        app_running || { echo "MemorAI stopped"; return; }
        sleep 1
    done
    pkill -x "MemorAI" 2>/dev/null
    sleep 1
    app_running && echo "MemorAI did not stop (still running)" || echo "MemorAI stopped (forced)"
}
```

12-second wait covers plan 003's 10 s finalization failsafe.

**Verify**: `bash -n memorai` → exit 0; `grep -c 'pkill -f' memorai` → 0.

### Step 3: Behavioral check (safe on a live machine)

Only if the app is NOT currently running (`pgrep -x MemorAI` empty):
`./memorai stop` → prints "MemorAI is not running", exit 0, nothing killed.
If the app IS running, skip this step and say so — do not stop the owner's
live app.

**Verify**: as described (or explicitly skipped-because-app-live).

## Test plan

Step 3 is the only runtime check; the rest is syntax + grep. No test
framework exists for the CLI.

## Done criteria

- [ ] `bash -n memorai` exits 0
- [ ] `grep -cE 'p(kill|grep) -f' memorai` → 0
- [ ] `cmd_stop` tries osascript quit before any signal
- [ ] Diff touches only `memorai`; `git status` clean after commit

## STOP conditions

- The `cmd_stop`/`cmd_start`/`cmd_status` excerpts don't match your base.
- You're tempted to stop/start the owner's live app to test — don't; STOP
  applies only to the plan step, report it skipped.

## Maintenance notes

- If the binary is ever renamed (bundle rename), `pgrep -x MemorAI` breaks
  loudly (status shows NOT RUNNING) — acceptable and visible.
- `cmd_restart`'s `sleep 1` now sits on top of a potentially 12 s stop; fine
  for a manual CLI. If someone scripts rapid restarts, revisit.
