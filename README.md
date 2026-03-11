# Claude Code Custom Status Line

A custom status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays real-time session metrics in a compact, color-coded bar at the bottom of the terminal.

## Preview

```
◆ Claude Opus 4.6 │ ctx: 34% ▰▰▰▱▱▱▱▱▱▱ (68k/167k) │ main │ 12m │ +42 -7 │ ↑285k ↓18k
```

## Sections

The status line is divided into six sections separated by dim `│` delimiters:

| Section | Example | Description |
|---|---|---|
| **Model** | `◆ Claude Opus 4.6` | The active model's display name, prefixed with a cyan diamond. |
| **Context usage** | `ctx: 34% ▰▰▰▱▱▱▱▱▱▱ (68k/167k)` | Percentage of *usable* context consumed, with a 10-segment progress bar and raw token counts. "Usable" = total window minus a 33k autocompact buffer. Color shifts green → yellow (≥50%) → red (≥80%). |
| **Git branch** | `main` | Current branch name (cached for 5s to avoid repeated `git` calls). |
| **Session duration** | `12m` | Wall-clock time since the session started, formatted as `Ns`, `Nm`, or `NhNm`. |
| **Lines changed** | `+42 -7` | Cumulative lines added (green) and removed (red) during the session. |
| **Token throughput** | `↑285k ↓18k` | Total input (↑) and output (↓) tokens for the session, formatted as `k` or `M`. |

## Installation

### 1. Copy the script

```bash
mkdir -p ~/.claude
curl -o ~/.claude/statusline.sh \
  https://raw.githubusercontent.com/LLRHook/claude-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

### 2. Enable it in Claude Code settings

Add the following to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

### 3. Requirements

- **`jq`** — used to parse the JSON payload Claude Code pipes to the script.
- **`git`** — for branch detection (gracefully falls back to `?` if not in a repo).
- A terminal that supports ANSI escape codes (virtually all modern terminals).

## Why "usable" context instead of raw percentage?

Claude Code reports a 200k token context window, but it doesn't actually let you use all 200k. Internally, it reserves ~33k tokens as a buffer for autocompaction — when the context gets too full, Claude Code automatically summarizes older messages to free up space. This compaction is triggered *before* you hit the true 200k ceiling, so the last ~33k tokens are never available to your conversation.

If you displayed percentage against the full 200k, you'd see the context get "compacted" at around 83% and never understand why it didn't reach 100%. This script instead calculates usage against the *usable* space (200k − 33k = ~167k), so 100% actually means "compaction is about to happen." The color thresholds (green → yellow at 50%, red at 80%) are calibrated against this usable space to give you a meaningful heads-up.

## Customization

- **Autocompact buffer**: Change `AUTOCOMPACT_BUFFER` at the top of the script if Claude Code adjusts its internal buffer size.
- **Git cache TTL**: Change `GIT_CACHE_TTL` (default 5 seconds) to control how often the branch name refreshes.
- **Progress bar width**: The bar uses 10 segments by default. Change the divisor in `FILLED=$((CTX_PCT / 10))` and `EMPTY` calculation to adjust.
- **Colors**: All ANSI codes are defined as variables near the top of the script — swap them to match your terminal theme.

## Input format

Claude Code pipes a JSON object to the status line command via stdin. The script reads these fields:

```
.model.display_name
.context_window.used_percentage
.context_window.context_window_size
.context_window.total_input_tokens
.context_window.total_output_tokens
.cost.total_duration_ms
.cost.total_lines_added
.cost.total_lines_removed
```

## License

MIT
