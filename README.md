# Claude Code Custom Status Line

A custom status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays real-time session metrics in a compact, color-coded bar at the bottom of the terminal.

## Preview

```
◆ Claude Opus 4.6 │ ctx: 41% ▰▰▰▰▱▱▱▱▱▱ (70k/167k) │ main │ 12m │ +42 -7 │ ↑285k ↓18k
```

## Sections

The status line is divided into six sections separated by dim `│` delimiters:

| Section | Example | Description |
|---|---|---|
| **Model** | `◆ Claude Opus 4.6` | The active model's display name, prefixed with a cyan diamond. |
| **Context usage** | `ctx: 41% ▰▰▰▰▱▱▱▱▱▱ (70k/167k)` | Percentage of *usable* context consumed, with a 10-segment progress bar and rounded token counts. "Usable" = reported window minus an estimated 33k autocompact buffer; windows of 33k or less use the full window. Color shifts green → yellow (≥50%) → red (≥80%). |
| **Git branch** | `main` | Branch in the supplied workspace directory, queried on each refresh. Detached HEAD shows a short commit hash; unavailable Git or repositories show `?`. |
| **Session duration** | `12m` | Total session running time, formatted as `Ns`, `Nm`, or `NhNm`. |
| **Lines changed** | `+42 -7` | Cumulative lines added (green) and removed (red) during the session. |
| **Input / output tokens** | `↑285k ↓18k` | Input (↑) and output (↓) tokens reported in the context window from the latest API response, formatted as `k` or `M`. |

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

- **Bash 3.2 or newer** and **`awk`** — available on macOS and typical Linux installations.
- **`jq`** — used to parse the JSON payload Claude Code pipes to the script. If missing, the script displays `◆ statusline: jq is required`.
- **`git`** (optional) — for branch detection; falls back to `?` if unavailable or outside a repository.
- A terminal that supports ANSI escape codes (virtually all modern terminals).

## Why "usable" context instead of raw percentage?

The script estimates usable context by reserving 33k tokens for autocompaction. This buffer is a configurable estimate, not a guarantee of Claude Code's compaction threshold; actual behavior can vary with the model and settings.

For a reported 200k window, the estimate is 167k usable tokens; a 1M window has 967k. The calculation preserves fractional input percentages until the final display rounding. Usage can exceed 100% of the estimate, while the bar stays capped at ten segments. For a window of 33k or less, the script uses the full reported capacity so the denominator stays positive.

## Customization

- **Autocompact buffer**: Change `AUTOCOMPACT_BUFFER` at the top of the script if Claude Code adjusts its internal buffer size.
- **Progress bar width**: The bar uses 10 segments by default. Change the divisor in `FILLED=$((CTX_PCT / 10))` and `EMPTY` calculation to adjust.
- **Colors**: All ANSI codes are defined in the colors section of the script — swap them to match your terminal theme.

## Input format

Claude Code pipes one JSON object to the status line command via stdin. See the [official status line input documentation](https://code.claude.com/docs/en/statusline#available-data). The script reads these fields:

```
.model.display_name
.context_window.used_percentage
.context_window.context_window_size
.context_window.total_input_tokens
.context_window.total_output_tokens
.cost.total_duration_ms
.cost.total_lines_added
.cost.total_lines_removed
.workspace.current_dir
.cwd
```

Branch detection prefers `workspace.current_dir`, then `cwd`, then the script's working directory. There is no shared branch cache or filesystem write during rendering.

Missing, null, or mistyped metrics use defaults. Counts must be nonnegative JSON numbers no greater than `9007199254740991`; fractional counts are rounded down, and numeric strings are not evaluated. Missing or invalid window sizes default to 200k. Raw context usage is limited to 0–100% before applying the usable-window estimate. Model and branch labels have C0, DEL, and C1 terminal control characters removed, preserving printable Unicode and literal backslashes.

Malformed, empty, non-object, or multiple JSON inputs display `◆ statusline: invalid JSON` without stderr or a failing exit status.

## Tests

Run the fixture-based regression suite with the tools above:

```bash
bash -n statusline.sh tests/test-statusline.sh
bash tests/test-statusline.sh
```

On macOS, `/bin/bash tests/test-statusline.sh` also verifies compatibility with the system Bash 3.2. Tests use synthetic JSON, a private temporary directory, and disposable Git repositories. They do not read Claude histories or session files.

## License

MIT
