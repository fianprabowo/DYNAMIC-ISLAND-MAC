#!/bin/bash
# Claude Code hook for the Dynamic Island app (Notification and Stop events).
# Appends the event to a log the app watches, so the notch shows when Claude needs you or has
# finished. Local only: no network. Keeps the event, Claude's short message (like "Claude needs your
# permission to use Bash"), the project folder and the terminal app; never the conversation.
# Always exits 0 and prints nothing, so it never gets in Claude Code's way.

input=$(cat)
umask 077

dir="$HOME/Library/Application Support/DynamicIsland"
mkdir -p "$dir" && chmod 700 "$dir"
file="$dir/claude-events.jsonl"
# The app only reads new events; start over once the log gets long.
size=$(stat -f %z "$file" 2>/dev/null) || size=0
if (( size > 65536 )); then
  : > "$file"
fi

event=$(jq -c --arg app "${__CFBundleIdentifier:-}" --arg terminal "${TERM_PROGRAM:-}" \
  '{event: .hook_event_name, type: (.notification_type // ""), message: (.message // ""), cwd: (.cwd // ""), app: $app, terminal: $terminal}' \
  <<<"$input" 2>/dev/null)
if [[ -n $event ]]; then
  printf '%s\n' "$event" >> "$file"
  chmod 600 "$file"
fi
exit 0
