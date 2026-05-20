#!/bin/sh
#
# Vendor-neutral Rapture notes processor.
#
# Pipes each unprocessed .txt file in NOTES_DIR through $LLM_CMD, writes the
# response next to the source as <name>.response.md, and moves the source to
# processed/YYYY-MM/.
#
# Usage:
#   LLM_CMD="claude -p" ./process-notes.sh
#   LLM_CMD="gpt"        ./process-notes.sh
#   LLM_CMD="gemini -p"  ./process-notes.sh
#
# Override NOTES_DIR if your folder isn't in the default location:
#   NOTES_DIR="$HOME/Dropbox/Notes" LLM_CMD="claude -p" ./process-notes.sh

set -eu

NOTES_DIR="${NOTES_DIR:-$HOME/Documents/Rapture Notes}"
LLM_CMD="${LLM_CMD:?set LLM_CMD to your LLM CLI, e.g. 'claude -p'}"

if [ ! -d "$NOTES_DIR" ]; then
  printf 'NOTES_DIR not found: %s\n' "$NOTES_DIR" >&2
  exit 0
fi

processed_count=0

for note in "$NOTES_DIR"/*.txt; do
  # No-glob fallback when nothing matches.
  [ -f "$note" ] || continue

  # Skip in-flight atomic writes.
  case "$note" in *.tmp) continue ;; esac

  filename=$(basename "$note" .txt)
  month=$(date -r "$note" +%Y-%m)
  processed_dir="$NOTES_DIR/processed/$month"
  mkdir -p "$processed_dir"

  response="$processed_dir/$filename.response.md"

  # Pipe note content through the LLM, write response.
  if ! sh -c "$LLM_CMD" < "$note" > "$response"; then
    printf 'failed: %s\n' "$note" >&2
    rm -f "$response"
    continue
  fi

  mv "$note" "$processed_dir/"
  processed_count=$((processed_count + 1))
  printf 'processed: %s\n' "$filename"
done

printf '\ndone. processed %d note(s).\n' "$processed_count"
