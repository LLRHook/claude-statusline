#!/usr/bin/env bash
# Dev Bar statusline for Claude Code
# Style: ◆ Model │ ctx: NN% ▰▰▰▱▱ (Nk/Nk) │ branch │ NNm │ +N -N │ ↑Nk ↓Nk

set -euo pipefail

# Autocompact buffer size (tokens). Adjust if Claude Code changes this.
AUTOCOMPACT_BUFFER=33000

if ! command -v jq >/dev/null 2>&1; then
  printf '◆ statusline: jq is required\n'
  exit 0
fi

# Parse exactly one object before emitting any fields. Normalize numbers here,
# before they reach shell arithmetic, and strip terminal controls from labels.
# NUL-delimited records preserve literal backslashes and whitespace in paths.
FIELDS=()
while IFS= read -r -d '' field; do
  FIELDS[${#FIELDS[@]}]=$field
done < <(jq -j -s --argjson buffer "$AUTOCOMPACT_BUFFER" '
  def object_or_empty: if type == "object" then . else {} end;
  def number_or($fallback):
    if type == "number" and . >= 0 and . <= 9007199254740991
    then . else $fallback end;
  def count: number_or(0) | floor;
  def safe_label:
    if type == "string" then
      gsub("[\u0000-\u001f\u007f-\u009f]"; "") |
      if length > 0 then . else "..." end
    else "..." end;
  def directory:
    if type == "string" then
      if length > 0 and (contains("\u0000") | not) then . else null end
    else null end;

  if length != 1 or (.[0] | type) != "object"
  then error("expected one JSON object") else .[0] end |
  (.model | object_or_empty) as $model |
  (.cost | object_or_empty) as $cost |
  (.context_window | object_or_empty) as $context |
  (.workspace | object_or_empty) as $workspace |
  ($context.context_window_size | number_or(200000) | floor |
    if . > 0 then . else 200000 end) as $max |
  # A fixed buffer cannot describe windows at or below its own size.
  (if $max > $buffer then $max - $buffer else $max end) as $usable |
  ($context.used_percentage | number_or(0) | if . > 100 then 100 else . end) as $pct |
  ($pct * $max / 100) as $used |
  [
    ($model.display_name | safe_label),
    ($used * 100 / $usable | floor),
    ($used | floor),
    $usable,
    ($cost.total_duration_ms | count),
    ($cost.total_lines_added | count),
    ($cost.total_lines_removed | count),
    ($context.total_input_tokens | count),
    ($context.total_output_tokens | count),
    (($workspace.current_dir | directory) // (.cwd | directory) // ".")
  ] | .[] | tostring + "\u0000"
' 2>/dev/null)

# Slurping ensures malformed/truncated input never produces partial records.
if [ "${#FIELDS[@]}" -ne 10 ]; then
  printf '◆ statusline: invalid JSON\n'
  exit 0
fi
MODEL=${FIELDS[0]}
CTX_PCT=${FIELDS[1]}
CTX_USED=${FIELDS[2]}
CTX_USABLE=${FIELDS[3]}
DURATION_MS=${FIELDS[4]}
LINES_ADDED=${FIELDS[5]}
LINES_REMOVED=${FIELDS[6]}
INPUT_TOKENS=${FIELDS[7]}
OUTPUT_TOKENS=${FIELDS[8]}
PROJECT_DIR=${FIELDS[9]}

# Query the supplied workspace directly: a shared cache can show another
# session/repository branch and requires platform-specific stat flags.
BRANCH="?"
if command -v git >/dev/null 2>&1; then
  BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null ||
    git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || printf '?')
fi
BRANCH=$(printf '%s' "$BRANCH" | jq -Rrs 'gsub("[\u0000-\u001f\u007f-\u009f]"; "")')
if [ -z "$BRANCH" ]; then BRANCH="?"; fi

# --- Session duration ---
format_duration() {
  local ms=$1
  local total_sec=$((ms / 1000))
  local hours=$((total_sec / 3600))
  local mins=$(( (total_sec % 3600) / 60 ))
  if [ "$hours" -gt 0 ]; then
    printf "%dh%dm" "$hours" "$mins"
  elif [ "$mins" -gt 0 ]; then
    printf "%dm" "$mins"
  else
    printf "%ds" "$total_sec"
  fi
}
DURATION_FMT=$(format_duration "$DURATION_MS")

# --- Format token counts as human-readable ---
format_tokens() {
  local tokens=$1
  if [ "$tokens" -ge 1000000 ]; then
    echo "$(awk -v t="$tokens" 'BEGIN {printf "%.1f", t/1000000}')M"
  elif [ "$tokens" -ge 1000 ]; then
    echo "$(awk -v t="$tokens" 'BEGIN {printf "%.0f", t/1000}')k"
  else
    echo "$tokens"
  fi
}

CTX_USED_FMT=$(format_tokens "$CTX_USED")
CTX_USABLE_FMT=$(format_tokens "$CTX_USABLE")
IN_FMT=$(format_tokens "$INPUT_TOKENS")
OUT_FMT=$(format_tokens "$OUTPUT_TOKENS")

# --- Colors ---
RESET='\033[0m'
DIM='\033[2m'
BOLD='\033[1m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
MAGENTA='\033[35m'
WHITE='\033[37m'
BLUE='\033[34m'

# Context color based on usage of usable space
if [ "$CTX_PCT" -ge 80 ]; then
  CTX_COLOR="$RED"
elif [ "$CTX_PCT" -ge 50 ]; then
  CTX_COLOR="$YELLOW"
else
  CTX_COLOR="$GREEN"
fi

# Build progress bar (10 segments, capped at 10 filled)
FILLED=$((CTX_PCT / 10))
if [ "$FILLED" -gt 10 ]; then FILLED=10; fi
EMPTY=$((10 - FILLED))
BAR=""
for ((i = 0; i < FILLED; i++)); do BAR+="▰"; done
for ((i = 0; i < EMPTY; i++)); do BAR+="▱"; done

# --- Separator ---
SEP="${DIM} │ ${RESET}"

# --- Build the line ---
# Model
printf "${CYAN}${BOLD}◆${RESET} ${WHITE}${BOLD}%s${RESET}" "$MODEL"
printf "%b" "$SEP"
# Context usage (relative to usable space)
printf "${CTX_COLOR}ctx: %d%% %s${RESET} ${DIM}(%s/%s)${RESET}" "$CTX_PCT" "$BAR" "$CTX_USED_FMT" "$CTX_USABLE_FMT"
printf "%b" "$SEP"
# Git branch
printf "${MAGENTA}%s${RESET}" "$BRANCH"
printf "%b" "$SEP"
# Session duration
printf "${DIM}%s${RESET}" "$DURATION_FMT"
printf "%b" "$SEP"
# Lines changed
printf "${GREEN}+%s${RESET} ${RED}-%s${RESET}" "$LINES_ADDED" "$LINES_REMOVED"
printf "%b" "$SEP"
# Token throughput (input/output)
printf "${DIM}↑%s ↓%s${RESET}" "$IN_FMT" "$OUT_FMT"
printf "\n"
