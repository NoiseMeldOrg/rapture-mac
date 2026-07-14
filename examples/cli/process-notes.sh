#!/bin/sh
#
# Vendor-neutral Rapture notes processor.
#
# Rapture for Mac has already triaged each capture into a Markdown note under
# Notes/, Links/, Tasks/, Ideas/, or Journal/. This script pipes each note it
# hasn't seen before through $LLM_CMD, writes the response to
# responses/YYYY-MM/<name>.response.md, and records the note in
# responses/processed.log so it isn't processed twice. Notes stay where the
# app filed them.
#
# Skips Links/Media/ (fetched transcript/article artifacts, not notes).
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

LOG="$NOTES_DIR/responses/processed.log"
mkdir -p "$NOTES_DIR/responses"
touch "$LOG"

processed_count=0

# Top level of each triaged subfolder only. Links/Media/ is a level deeper,
# so these globs never match its artifacts.
for note in "$NOTES_DIR"/Notes/*.md \
            "$NOTES_DIR"/Links/*.md \
            "$NOTES_DIR"/Tasks/*.md \
            "$NOTES_DIR"/Ideas/*.md \
            "$NOTES_DIR"/Journal/*.md; do
  # No-glob fallback when nothing matches.
  [ -f "$note" ] || continue

  # Skip in-flight atomic writes.
  case "$note" in *.tmp) continue ;; esac

  # Skip anything already recorded in the processed log.
  rel="${note#"$NOTES_DIR"/}"
  if grep -Fxq "$rel" "$LOG"; then
    continue
  fi

  filename=$(basename "$note" .md)
  month=$(date -r "$note" +%Y-%m)
  response_dir="$NOTES_DIR/responses/$month"
  mkdir -p "$response_dir"

  response="$response_dir/$filename.response.md"

  # Pipe note content (frontmatter and all) through the LLM, write response.
  if ! sh -c "$LLM_CMD" < "$note" > "$response"; then
    printf 'failed: %s\n' "$rel" >&2
    rm -f "$response"
    continue
  fi

  printf '%s\n' "$rel" >> "$LOG"
  processed_count=$((processed_count + 1))
  printf 'processed: %s\n' "$rel"
done

printf '\ndone. processed %d note(s).\n' "$processed_count"
