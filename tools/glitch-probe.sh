#!/bin/bash
# Suspend MemorAI's heavy background children for a few seconds, then resume
# them — the cheapest causal test there is for "the speakers crackle while a
# call records".
#
# Run it WHILE you can hear the crackle. If the crackle (and the [AudioGlitch]
# overload lines in memorai.log) stop within a second of the suspend and come
# back on resume, our own post-processing load is the cause. If nothing changes,
# the cause is elsewhere — the capture path, the mic client, or the OS.
#
# Nothing is killed and nothing is configured: SIGSTOP freezes a process, SIGCONT
# resumes it, and the trap resumes everything even if you interrupt the script.
# whisper-cli gets a 1 h deadline from the app, so a pause of a few tens of
# seconds cannot cost a transcript.
#
#   bash tools/glitch-probe.sh [seconds]   # default 45

set -uo pipefail

DURATION="${1:-45}"
# The expensive ones. whisper-server (dictation) is included: it holds the model
# resident and wakes on its own.
PATTERNS=(whisper-cli whisper-server aec_sidecar.py ocr_sidecar.py ffmpeg)

stamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

pids=()
for pattern in "${PATTERNS[@]}"; do
    while read -r pid; do
        [ -n "$pid" ] && pids+=("$pid")
    done < <(pgrep -f "$pattern" 2>/dev/null)
done

if [ ${#pids[@]} -eq 0 ]; then
    echo "$(stamp)  nothing to suspend — none of: ${PATTERNS[*]}"
    echo "  Run this while post-processing is actually running (see memorai.log)."
    exit 1
fi

resume() {
    for pid in "${pids[@]}"; do kill -CONT "$pid" 2>/dev/null; done
    echo "$(stamp)  RESUMED ${#pids[@]} process(es)"
}
trap resume EXIT INT TERM

echo "$(stamp)  suspending ${#pids[@]} process(es) for ${DURATION}s:"
for pid in "${pids[@]}"; do
    echo "    pid $pid  $(ps -p "$pid" -o comm= 2>/dev/null)"
done

for pid in "${pids[@]}"; do kill -STOP "$pid" 2>/dev/null; done
echo "$(stamp)  SUSPENDED — listen now: does the crackle stop?"

sleep "$DURATION"
# The trap does the resume, so an interrupt here cannot leave anything frozen.
