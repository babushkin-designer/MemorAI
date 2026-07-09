#!/bin/bash
# MemorAI screenshot retention.
# Deletes screenshot image files older than RETENTION_DAYS, but keeps the OCR
# text (index.jsonl) forever — text is the searchable asset, images are just a
# visual cache. Day folders left with only index.jsonl are kept; fully empty
# ones are pruned.
set -e
RETENTION_DAYS="${RETENTION_DAYS:-14}"
# `|| true`: with set -e, a failing command substitution in an assignment
# aborts the script — and `defaults read` exits 1 when outputPath is unset
# (the common case: default location in use).
DIR_BASE="${MEMORAI_DIR:-$(defaults read com.local.memorai outputPath 2>/dev/null || true)}"
[ -z "$DIR_BASE" ] && DIR_BASE="$HOME/Downloads/MemorAI"
DIR="$DIR_BASE/screen"
LOG="$DIR_BASE/memorai.log"

[ -d "$DIR" ] || exit 0

before=$(find "$DIR" -type f \( -name '*.jpg' -o -name '*.heif' -o -name '*.png' \) | wc -l | tr -d ' ')
find "$DIR" -type f \( -name '*.jpg' -o -name '*.heif' -o -name '*.png' \) -mtime +"$RETENTION_DAYS" -delete
after=$(find "$DIR" -type f \( -name '*.jpg' -o -name '*.heif' -o -name '*.png' \) | wc -l | tr -d ' ')
# Remove day folders that have become completely empty.
find "$DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [retention] kept text, removed $((before - after)) images older than ${RETENTION_DAYS}d" >> "$LOG"

# Cap the log: if it exceeds MAX_LOG_BYTES, keep only the last KEEP_BYTES.
# Truncate via `cat >` (not `mv`) so the running app's open FileHandle keeps
# pointing at the same inode.
MAX_LOG_BYTES=$((10 * 1024 * 1024))
KEEP_BYTES=$((5 * 1024 * 1024))
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt "$MAX_LOG_BYTES" ]; then
    tail -c "$KEEP_BYTES" "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG" && rm -f "$LOG.tmp"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [retention] truncated memorai.log to last ${KEEP_BYTES} bytes" >> "$LOG"
fi
