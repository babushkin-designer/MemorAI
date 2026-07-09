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
