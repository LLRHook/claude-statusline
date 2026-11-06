# Claude Code Custom Status Line

A Rust status line command for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays real-time session metrics in a compact, color-coded bar at the bottom of the terminal.

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

### 1. Build and install the command

From a checkout of this repository, build once with Rust and Cargo:

```bash
cargo build --release --locked
mkdir -p ~/.claude
install -m 755 "${CARGO_TARGET_DIR:-target}/release/claude-statusline" ~/.claude/claude-statusline
install -m 755 statusline.sh ~/.claude/statusline.sh
```

`statusline.sh` is a thin Bash compatibility launcher that executes the compiled
`claude-statusline` beside it. Copy **both** files when upgrading an existing
installation. Every refresh uses Rust for JSON parsing, metric calculations,
Git lookup, and ANSI formatting. The launcher never builds or downloads anything.
You can also configure the compiled command directly.

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

- **Rust and Cargo** — needed to build, not to run the installed command.
- **Bash 3.2 or newer** — only for the compatibility launcher.
- **`git`** (optional) — for branch detection; falls back to `?` if unavailable or outside a repository.
- A terminal that supports ANSI escape codes (virtually all modern terminals).

Rendering does not require `jq` or `awk`. If the launcher cannot find an executable
Rust command, it displays `◆ statusline: Rust binary is required` with a successful
exit status and no stderr. For a development build or a separate installation,
`STATUSLINE_BIN` can select an explicit binary path; quote paths containing spaces.

## Why "usable" context instead of raw percentage?

The command estimates usable context by reserving 33k tokens for autocompaction. This buffer is a configurable estimate, not a guarantee of Claude Code's compaction threshold; actual behavior can vary with the model and settings.

For a reported 200k window, the estimate is 167k usable tokens; a 1M window has 967k. The calculation preserves fractional input percentages until the final display rounding. Usage can exceed 100% of the estimate, while the bar stays capped at ten segments. For a window of 33k or less, the command uses the full reported capacity so the denominator stays positive.

## Customization

- **Autocompact buffer**: Change `AUTOCOMPACT_BUFFER` in `src/lib.rs` if Claude Code adjusts its internal buffer size.
- **Progress bar width**: The bar uses 10 segments by default. Adjust the `filled` calculation and `repeat` calls in `Metrics::render` to change it.
- **Colors**: All ANSI codes are defined as constants in `src/lib.rs` — swap them to match your terminal theme.

After changing Rust constants or rendering code, rebuild and reinstall the command.

## Input format

Claude Code pipes one JSON object to the status line command via stdin. See the [official status line input documentation](https://code.claude.com/docs/en/statusline#available-data). The command reads these fields:

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

Branch detection prefers `workspace.current_dir`, then `cwd`, then the command's working directory. Inherited Git repository selectors such as `GIT_DIR` and `GIT_WORK_TREE` do not override this workspace. There is no shared branch cache or filesystem write during rendering.

Missing, null, or mistyped metrics use defaults. Counts must be nonnegative JSON numbers no greater than `9007199254740991`; fractional counts are rounded down, and numeric strings are not evaluated. Missing or invalid window sizes default to 200k. Raw context usage is limited to 0–100% before applying the usable-window estimate. Model and branch labels have C0, DEL, and C1 terminal control characters removed, preserving printable Unicode and literal backslashes.

Input is limited to **1 MiB (1,048,576 bytes)**, including unused fields and whitespace. Oversized input is rejected as a whole, without rendering partial fields. Malformed, empty, non-object, or multiple JSON inputs display `◆ statusline: invalid JSON` without stderr or a failing exit status. Invalid UTF-8 and unpaired Unicode surrogate escapes are rejected, including in unused fields.

## Tests

Build and run the Rust unit and CLI tests, then the fixture-based launcher suite:

```bash
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --release --locked
bash -n statusline.sh tests/test-statusline.sh
STATUSLINE_BIN="${CARGO_TARGET_DIR:-target}/release/claude-statusline" bash tests/test-statusline.sh
```

On macOS, use `/bin/bash` for the last command to verify system Bash 3.2 compatibility.
The launcher suite needs `jq` to generate synthetic fixtures, plus Git and normal
shell test utilities. It verifies rendering without `jq`/`awk`, missing Git and
binary handling, workspace paths containing whitespace, detached HEAD, terminal
controls, Unicode, numeric overflow, exact ANSI bytes, and the input size limit.
Rust CLI tests also exercise the compiled binary directly, inclusive input bounds,
color thresholds, and quiet parse errors. All Git commits and files used by tests
are confined to temporary synthetic repositories with isolated Git configuration.
Tests do not read Claude histories, session files, or change user settings.

For migration checks, an optional Python 3 standard-library harness compares the
binary with an explicitly supplied copy of the previous shell renderer:

```bash
python3 tests/compare-shell.py --reference /path/to/previous-statusline.sh \
  --binary "${CARGO_TARGET_DIR:-target}/release/claude-statusline"
```

It compares stdout **including ANSI codes**, stderr, and exit status across synthetic
fixtures, boundary cases, deterministic generated metrics, and temporary Git states.
The documented input size limit, rejection of all unpaired surrogate escapes
(some `jq` versions replace lone low surrogates with `�`), and removal of
rendering-time `jq`/`awk` requirements are intentional changes from the old renderer.

GitHub Actions runs formatting, Clippy, Rust tests, release builds, shell syntax,
and the launcher regressions on Ubuntu and macOS. The macOS job also uses
`/bin/bash`. The workflow uses read-only repository permissions.

## License

MIT
