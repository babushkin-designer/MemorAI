# Speaker crackle during call recording

Status: implementation, independent code review, simplify and final automated
verification complete. Final signed version is installed and running after the second call ended. User reported no audible crackle during the second call;
this is encouraging real-call evidence, not a general proof of the cause.

## Evidence collected 2026-10-05

- Repository HEAD: 778b9e2; working tree initially clean.
- Running app: /Applications/MemorAI.app/Contents/MacOS/MemorAI, PID 2334.
  Its executable has not been compared with this checkout.
- Existing log: /Users/ilyababushkin/Documents/MemorAI/memorai.log.
- Current recording began at 13:01:30 Asia/Almaty (08:01:30 UTC).
- PostProcessor reports its gate closed; ScreenMemory reports paused for call
  recording and its OCR sidecar released.
- Before recorders, after SCStream start, and after mic engine start, the default
  output remains MacBook Pro Speakers at 48000 Hz / 512 frames. Input remains
  MacBook Pro Microphone at 48000 Hz / 512 frames. No device reconfiguration is
  visible in those snapshots.
- No AudioGlitch overload event appeared in the inspected current-call log.
  This does not establish that playback was clean or exclude other causes.
- The old live voice-processing path was removed in 6d724af. Do not restore it.

## Remaining suspect in the capture path

MicRecorder.handleTap currently takes a shared blocking lock and performs
AVAudioFile.write (including AAC encoding for <=2-channel devices) before
returning. It also computes RMS, constructs messages on exceptional paths, and
schedules callbacks there. writePendingPauseSilenceLocked can encode an entire
paused interval in that same callback. The pause case is a definite unbounded
amount of work in the callback; neither it nor ordinary synchronous writes have
yet been causally linked to the user's intermittent speaker crackle.

The existing UnfairLock tests exercise synchronization and pause accessors,
not a stalled writer, tap latency, queue overflow, or audio during a device
switch. AudioGlitchMonitor is supplementary evidence, not an audible-playback
acceptance test.

## Resume after the call

1. Read the completed session's capture/tap/overload summaries. Compare the
   installed executable with the checkout before attributing behavior to HEAD.
2. Separate microphone capture from file writing: a bounded, preallocated PCM
   handoff with a producer that does not wait for encoding, disk IO, logging,
   or a writer-held lock. Keep buffer ownership explicit; tap buffers cannot
   just be retained for deferred use without verifying their lifetime contract.
3. Give the writer exclusive ownership of AVAudioFile, pause padding, RMS and
   write-error handling. Preserve native formats, first host timestamps,
   complete part files, and canonical-file publication after finalization.
4. Define and measure overflow behavior. Never hide lost samples: account for
   dropped duration and preserve the recorded timeline or report a recording
   failure. An unbounded DispatchQueue.async per buffer is not sufficient.
5. Stop/restart must stop the producer, drain accepted buffers, finalize the old
   part, and only then open the next format. Recovery must post one main-queue
   event, reject stale events from an earlier engine generation, and preserve
   stop idempotence. Pause transitions must remain ordered with captured audio.
6. Add deterministic tests with synthetic PCM and temporary files, without
   opening hardware: blocked writer / bounded handoff, overflow accounting,
   drain on stop, pause alignment, format changes, write failure and recovery.
   Run these with limited build parallelism after the live call ends.
7. Only after automated verification, validate audible playback in a disposable
   test call. Compare recording off/on, mic/system/screen capture separately,
   and long pause/resume. Verify both speaker audio and saved track alignment.
   A clean file or zero HAL overload counters alone does not prove this fixed.

Do not mark this issue fixed until implementation and playback validation are
complete. No audio runtime, defaults, installed bundle, or recorded data was
modified by this investigation.

## Claude CLI discussion, 2026-10-05

Two read-only CLI consultations, with tools, MCP, hooks/customizations and
session persistence disabled. Requested claude-opus-5-5 was rejected by CLI
2.1.276 (requires >=2.1.280); the successful consultations used claude-opus-5.
No CLI update was performed. Raw responses are temporarily available under
/tmp/memorai-crackle-review (review.md and followup.json).

Agreed conclusion: synchronous writes and arbitrary-length pause padding under
the shared lock are demonstrated by source. Their causal connection to audible
OUTPUT crackle is not demonstrated. Do not assert the tap is the hardware
output render thread, assign it the 512-frame device deadline, or interpret
tap timestamp gaps as proof of missed output deadlines without measurements.

Corrections discussed and accepted:

- Logger already dispatches disk writes onto logQueue. Formatting, os_log and
  enqueueing still happen in the caller; claiming synchronous log file IO in
  the tap was incorrect.
- Pause-as-segment is NOT a safe drop-in fix: MicStitcher.gaps caps inferred
  gaps at 30 seconds. Arbitrary-length explicit pauses require separate
  metadata/policy, or ordered padding on the writer. Never shorten a long pause.
- tools/glitch-probe.sh subtracts background load; it does not generate a known
  overload or calibrate HAL notifications. Do not run it during the live call.
- The video writer uses HEVC, despite nearby H.264 comments. Consider system
  capture, screen encoding and overall load independently in playback tests.

Further source findings:

- AudioGlitchMonitor attaches to default devices once at start. After a route
  switch it can keep observing the old device. Add read-only default-device
  listeners and reattach, preserving session totals. Listen for buffer/rate
  changes throughout the session instead of relying only on start snapshots.
- SystemAudioRecorder's RMS path allocates/copies audio data. Review safe access
  to potentially noncontiguous CMBlockBuffers before optimizing; do not assume
  a single contiguous data pointer exists.
- CallDetector source does not instantiate AVAudioEngine; an assertion in the
  first review that it adds another mic engine was not substantiated. Dictation
  does use an engine and has call-recording suspension logic; inspect that
  lifecycle if needed rather than assuming a third active mic client.

Refined sequence: completed-call evidence and installed-version check first;
passive callback duration/thread and route-change instrumentation next; then
isolated disposable playback comparisons to distinguish system-audio capture,
screen capture and mic capture. A bounded writer handoff remains valuable for
recording robustness, but its acceptance criteria are separate from the user's
speaker-crackle symptom. No behavior-changing fix was applied in this review.

## Additional Opus 5.5 review

After the user authorized updating the CLI, Claude Code was updated to 2.1.289.
An additional read-only consultation succeeded with modelUsage confirming
claude-opus-5-5. Full review: 013-speaker-crackle-opus55.md. Treat the review's
API explanations as hypotheses unless verified against authoritative sources.

New source observations, checked by Codex:

- DictationManager.setCallActive(true) queues transcription if listening, then
  stops the server. Queued transcription/warmup can subsequently call
  ensureServer, which has no call-active guard and directly launches Process.
  Server state is accessed from both main and workQueue. AppDelegate wires
  setCallActive through onRecordingActiveChanged, so this path is connected.
  Fix the race without discarding pending dictation, and cover delayed warmup
  and transcription with an injected launcher. The affected scenario is a
  dictation operation overlapping call start; no evidence yet that it happened
  during the reported crackle.
- _expectedNextHost survives pause and same-format restarts. Reported tap gaps
  therefore include intentional interruptions; continuous buffer timestamps
  also do not prove callback execution was timely. Reset continuity baselines
  appropriately and measure callback runtime separately.
- A restart during a pause can cause both file padding and stitcher gap padding.
  _currentSegmentFirstHost describes the incoming post-resume buffer, but that
  segment may begin with pending pause silence. Cover this case, plus a pause
  before the first buffer, and enforce that segment frame zero corresponds to
  its declared host-time origin. Compensate each pause exactly once.
- Moving arbitrary-length pause padding to a writer can itself cause ring
  overflow while that writer catches up. Design explicit pause metadata or
  another bounded strategy before implementing; stop during a pause must keep
  the existing track-end behavior. Main-thread control markers must not turn a
  supposedly single-producer ring into an unsafe multiple-producer queue.

Revised priority after the call: inspect completed logs and installed version;
correct passive metrics; fix/test dictation gating and pause/restart alignment;
isolate audible crackle with controlled capture comparisons; implement a bounded
writer as a separately validated recording-robustness change. None of these
source findings alone establishes the cause of speaker crackle.

## Git history checked after the user recalled earlier regressions

- 2026-07-29 cfbfee7 added live Apple voice processing to address echo in muxed
  videos. This was an echo change, not the later background-load crackle fix.
- 2026-08-10 c55d320 moved echo cancellation offline; 6d724af removed the live
  voice-processing code entirely because it degraded real meetings.
- 2026-08-10 25cd5eb added format-specific mic segments, the >2-channel LPCM
  fallback, exception handling and deferred engine restarts. Its source records
  an AirPods switch (16 kHz/2ch -> 48 kHz/7ch) ending mic audio about 50 s into a
  40-minute call, and a config-change callback deadlock freezing the application.
- 2026-08-10 a4d94da removed teardown from the tap and synchronized shared state.
- 2026-08-19 13ddafb introduced monitoring; 3b11dd6 blocked post-processing,
  released OCR/dictation during calls, and introduced the dictation gating path
  that still permits a queued ensureServer to launch after call start.

Important branch divergence: 55b5004 (2026-06-27, manual-start SIGABRT fix) exists
in locally cached origin/main but is NOT an ancestor of current HEAD 778b9e2.
Their merge base is d02bcd3. No remote fetch was performed. That fix used
installTap(format: nil), opened the mic file from actual delivered buffer format,
and continued a system-only session if mic startup failed. Current source uses
an explicit format and stops the whole session on mic-start failure. Current
source has its own ObjCTry protection, so not all June crash protection is absent.
Do not blindly cherry-pick the old fix: it also included stopping from the tap,
which later code explicitly removed. Compare behavior and preserve later safety
changes. The old branch divergence alone does not prove the user's regression.

Order clarification agreed with the user: establish a baseline and isolate the
speaker-crackle cause BEFORE behavior-changing fixes. Passive instrumentation
and read-only history analysis can precede that comparison. Dictation/timeline
bugs should be separately fixed and verified after evidence collection, rather
than changing capture first and losing the baseline.

## Implementation and verification after the call

- Original bundle backed up under `/tmp/memorai-crackle-review/MemorAI-before-fix.app`;
  app quit through its normal quit handler. Installed binary differs from HEAD's
  build even without signatures; the exact installed source revision is unknown.
- Bounded preallocated owned-PCM microphone handoff removes file creation, AAC,
  RMS, logs, long pause padding and recovery from the audio callback. Short
  metadata locks never cover sink IO. Overflow is counted and timeline holes
  retained. Stop drains and finalizes; restart callbacks are generation-checked,
  and permanent mic failure retains system/screen tracks.
- Pauses and capture gaps retain host-time origins across engine generations;
  AAC segment duration counts accepted source frames, not the unflushed encoder
  length. Long gaps are restored offline; legacy manifest compatibility remains.
- Dictation server launch and call gate are synchronized. ffmpeg/whisper use the
  same cancellable recording gate, including the subprocess launch boundary.
  Pending dictation audio/language is persisted before queueing and retained
  across call interruptions and application restarts.
- System writer queues drain before finalization. Monitor follows default-device
  changes without setting device properties; zero HAL overloads do not establish
  clean audible output. XCTest and explicit probe logs use temporary paths.
- Controlled original-HEAD and fixed hardware probes exercised playback, mic,
  system audio, screen capture and combined capture with a 1-second pause. No
  HAL overloads in either run. Fixed combined microphone callback maximum was
  0.045 ms with zero dropped frames. These quiet-tone probes do not reproduce
  call-app behavior and therefore do not prove the audible crackle resolved.
- Probe confirmed AVAssetWriter compacts system-audio PTS holes: the 1-second
  pause was absent from the m4a packet timeline. New manifest metadata records
  successfully appended samples and holes; a first offline stage restores silence
  before transcription/AEC/mux. An immutable compact source makes retry after
  publication safe. Cleanup waits until the whole session has durable completion.
- Full offline suite: 191 tests passed; includes blocked writer, owned buffers,
  overflow, native multi-channel PCM, actual AAC, 61-second pause stitching,
  mic-start fallback, dictation gate/persistence, real system-timeline restoration
  and publication retry. SwiftLint strict gate passed.
- Two implementation reviews were requested through Claude CLI Opus 5.5, in
  addition to the original investigation discussion. First review findings were
  independently checked and corrected. Final review/result is under
  `/tmp/memorai-crackle-review/final-review.json`.

Still required for audible acceptance: compare recording off/on during a real
call using the speakers. If crackle persists, isolate mic/system/screen while
that symptom is actually present; neither source suspicion nor capture-file
continuity is a causal reproduction. Old sessions lack gap positions and are
not automatically rewritten.

Final hardware probe (`probe-final`): playback, mic, system, screen and combined
pause modes all completed successfully. Combined mic callback max 0.019 ms,
zero dropped frames and zero capture gaps; native devices remained 48 kHz /
512 frames. Combined system track went from 5.38 s compact to 6.357 s after
restoring the measured 1.0 s pause (AAC packet rounding remains below 23 ms).
Mic host timeline was 6.200 s; absolute first-host offsets are still used for
alignment. Probe only captures fixture files and logs under `/tmp`.

Final Opus 5.5 review completed. Verified fixes: use cumulative host-time
deficits so positive/negative boundary jitter cancels; external ffmpeg filter
script avoids command-line graph limits; compact source copy is atomically
published; orphan/abandoned compact files are swept; reopen the recording gate
after finalized manifest publication; scheduled retries are excluded from the
automatic launch/resume sweep; histogram thresholds are static. Added jitter
and bounded restoration-failure tests (191 tests now).

One suggested remedy was intentionally rejected: marking a failed restoration
as successful and proceeding with unaligned audio. Instead restoration gets
three automatic attempts; persistent failure retains the manifest and sources
without downstream processing or further automatic attempts. A manual retry
resets the budget. The same batch never repeats restoration in its media pass.

## Independent code review and simplify

The requested read-only review compared main plus staged, unstaged and untracked
files with merge base d02bcd3aa2a9a5f2183baee7ad7142b5285cfb6a (86 changed files).
Five concrete findings were addressed in source: canonical mic publication is
idempotent even after partial part cleanup; dictation disable/enable no longer
changes the real call gate; OCR launch is registered before readiness and queued
work cannot relaunch while paused/disabled; title batches stop and notify on
insufficient_quota; CLI search rejects flags without values instead of looping.
The new CallWorkGate is shared by dictation and OCR.

Simplify covered reuse, simplification, efficiency and altitude. Accepted
cleanups: one labeled-dialogue renderer for Whisper and Deepgram; explicit
done/paused/failed dictation outcomes replace a mutable side channel; record
dictation directly into its pending store so call startup only publishes small
metadata; move the canonical publication invariant into MicStitcher itself.
No runtime defaults or capture settings were changed.

Initial installed build passed 191 tests, strict lint, release build, signing
verification and all hardware probe modes. New regression tests cover partial
mic cleanup, reversible disable while a call is active, quota batch termination,
CLI missing arguments and pending audio publication without a second copy.
These last tests await the end of the active call.

The same independent reviewer verified all five fixes plus simplify cleanup
read-only and found no remaining actionable defects. Final source diff check and
strict lint pass. The installed build is still the earlier 191-test version;
it must not be confused with the later reviewed source while the call is live.

## Final validation after the second call

- Recording 14:31:41–15:00:46 ended normally: 17,449 mic buffers, zero capture
  gaps and zero dropped frames, maximum callback duration 2.138 ms (all others
  below 2.5 ms). System/audio video writers finalized successfully.
- No HAL overload notifications during the 1,745-second session; this is
  supplementary telemetry, not a substitute for the user's audible report.
- Header-only ffprobe checks: mic 1744.960 s, system 1745.152 s; both readable.
  The transcript was saved before graceful app quit. Any interrupted mux stage
  remains resumable from its manifest.
- Final offline suite: 196 tests passed, including all five new regression
  scenarios after code review/simplify. Strict lint, bash syntax and diff check
  passed. No tests wrote into real preferences or the recording directory.

Final release installed at `/Applications/MemorAI.app` and started normally.
Strict codesign verification passed for original backup, final bundle and installed
bundle; designated requirements match. Installed executable equals the release
binary (SHA-256 9f29388832875970cf84fdf14046ab619f6f68885cba980e25f28c3c44ea906e).
Startup confirms dictation monitor, call detector and OCR ready; no new recording
was initiated by verification. The last real session finished muxing and removed
its manifest before the graceful quit. Final install did not reset preferences
or signing identity. All requested implementation/review/cleanup work is complete.
