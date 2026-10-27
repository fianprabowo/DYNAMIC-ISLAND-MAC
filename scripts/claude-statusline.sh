#!/bin/bash
# Claude Code status line for the Dynamic Island app.
# Saves the status JSON (model, rate limits) for the notch widget, then prints a bar status line.
# Local only: no network, no credentials.

input=$(cat)

dir="$HOME/Library/Application Support/DynamicIsland"
mkdir -p "$dir" && chmod 700 "$dir"
file="$dir/claude-status.json"
# Keep the last known value of each limit window: a session that hasn't replied yet has no
# rate_limits, and a window that isn't in use is left out. The app treats past resets as unused.
saved=$(jq -c --slurpfile prev "$file" \
  '.rate_limits = (($prev[0].rate_limits // {}) + (.rate_limits // {})) | if .rate_limits == {} then del(.rate_limits) end' \
  <<<"$input" 2>/dev/null) || saved=$input
tmp=$(mktemp "$dir/.claude-status.XXXXXX") && printf '%s' "$saved" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file"

model=$(jq -r '.model.display_name // "Claude"' <<<"$input")

bar() {
  local pct=$1 filled color i out=""
  filled=$(( (pct + 5) / 10 )); (( filled > 10 )) && filled=10
  if (( pct >= 80 )); then color='\033[31m'; elif (( pct >= 50 )); then color='\033[33m'; else color='\033[32m'; fi
  for ((i = 0; i < 10; i++)); do
    if (( i < filled )); then out+="▰"; else out+="▱"; fi
  done
  printf "%b%s %d%%\033[0m" "$color" "$out" "$pct"
}

line="\033[1m$model\033[0m"
five=$(jq -r '.rate_limits.five_hour.used_percentage // empty | floor' <<<"$input")
week=$(jq -r '.rate_limits.seven_day.used_percentage // empty | floor' <<<"$input")
[[ -n $five ]] && line+="   5h $(bar "$five")"
[[ -n $week ]] && line+="   week $(bar "$week")"
printf "%b\n" "$line"
