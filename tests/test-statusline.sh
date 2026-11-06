#!/usr/bin/env bash
# End-to-end tests with synthetic JSON and disposable Git repositories only.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${STATUSLINE_SCRIPT:-"$ROOT/statusline.sh"}
BASH_BIN=$(command -v "${BASH_BIN:-$BASH}")
TEST_FILTER=${TEST_FILTER:-}
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/statusline-tests.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
PASSED=0
FAILED=0

# Rendering never compiles. Build first, or select an already built binary.
export STATUSLINE_BIN=${STATUSLINE_BIN:-"${CARGO_TARGET_DIR:-$ROOT/target}/debug/claude-statusline"}
case $STATUSLINE_BIN in
  /*) ;;
  *) STATUSLINE_BIN="$PWD/$STATUSLINE_BIN" ;;
esac
if [ ! -x "$STATUSLINE_BIN" ]; then
  printf 'Build the Rust binary first: cargo build --locked\n' >&2
  exit 1
fi
mkdir -p "$TEST_TMP/home"
export HOME="$TEST_TMP/home" XDG_CONFIG_HOME="$TEST_TMP/home"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

mkdir -p "$TEST_TMP/working directory" "$TEST_TMP/other repo" "$TEST_TMP/tools"
export GIT_AUTHOR_NAME='Victor Ivanov' GIT_COMMITTER_NAME='Victor Ivanov'
export GIT_AUTHOR_EMAIL='victor.n.ivanov@gmail.com' GIT_COMMITTER_EMAIL='victor.n.ivanov@gmail.com'
# Do not inherit a caller's repository selection into the fixture repositories.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
for repo in 'working directory' 'other repo'; do
  git init -q "$TEST_TMP/$repo"
  git -C "$TEST_TMP/$repo" symbolic-ref HEAD "refs/heads/fixture-${repo%% *}"
  git -C "$TEST_TMP/$repo" commit -q --allow-empty -m 'Create synthetic fixture'
done

# A restricted PATH lets tests remove individual optional/required tools.
for tool in jq git; do
  tool_path=$(command -v "$tool")
  ln -s "$tool_path" "$TEST_TMP/tools/$tool"
done

run_line() {
  local fixture=$1
  local tools_path=${2:-$PATH}
  STATUS=0
  (cd "$TEST_TMP/working directory" && PATH="$tools_path" "$BASH_BIN" "$SCRIPT" < "$fixture") \
    > "$TEST_TMP/stdout" 2> "$TEST_TMP/stderr" || STATUS=$?
  # Remove only the renderer's intended SGR color codes, leaving any injected
  # OSC sequences, newlines, or other controls visible to exact comparisons.
  PLAIN=$(sed -E $'s/\033\\[[0-9;]*m//g' "$TEST_TMP/stdout")
}

quiet_success() {
  [ "$STATUS" -eq 0 ] && [ ! -s "$TEST_TMP/stderr" ] &&
    [ "$(wc -l < "$TEST_TMP/stdout" | tr -d ' ')" -eq 1 ]
}

normal_session() {
  run_line "$ROOT/tests/fixtures/session.json"
  quiet_success && [ "$PLAIN" = '◆ Claude Fixture │ ctx: 41% ▰▰▰▰▱▱▱▱▱▱ (70k/167k) │ fixture-working │ 1h2m │ +42 -7 │ ↑285k ↓18k' ]
}

malformed_json() {
  run_line "$ROOT/tests/fixtures/malformed.json"
  quiet_success && [ "$PLAIN" = '◆ statusline: invalid JSON' ]
}

empty_input() {
  run_line /dev/null
  quiet_success && [ "$PLAIN" = '◆ statusline: invalid JSON' ]
}

invalid_top_levels() {
  local payload
  for payload in 'null' '[]' 'true' '42' '"text"' '{} {}'; do
    printf '%s' "$payload" > "$TEST_TMP/input.json"
    run_line "$TEST_TMP/input.json"
    quiet_success && [ "$PLAIN" = '◆ statusline: invalid JSON' ] || return 1
  done
}

invalid_types() {
  run_line "$ROOT/tests/fixtures/invalid-types.json"
  quiet_success && [ "$PLAIN" = '◆ ... │ ctx: 0% ▱▱▱▱▱▱▱▱▱▱ (0/167k) │ fixture-working │ 0s │ +0 -0 │ ↑0 ↓0' ]
}

invalid_nested_objects() {
  printf '%s' '{"model":[],"cost":true,"context_window":"text","workspace":42,"cwd":null}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [ "$PLAIN" = '◆ ... │ ctx: 0% ▱▱▱▱▱▱▱▱▱▱ (0/167k) │ fixture-working │ 0s │ +0 -0 │ ↑0 ↓0' ]
}

initial_session() {
  printf '%s' '{"model":{"display_name":null},"context_window":{"used_percentage":null,"context_window_size":null,"current_usage":null},"cost":null}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [ "$PLAIN" = '◆ ... │ ctx: 0% ▱▱▱▱▱▱▱▱▱▱ (0/167k) │ fixture-working │ 0s │ +0 -0 │ ↑0 ↓0' ]
}

small_context_windows() {
  local size
  for size in 1 32000 33000; do
    printf '{"context_window":{"context_window_size":%s,"used_percentage":50}}' "$size" > "$TEST_TMP/input.json"
    run_line "$TEST_TMP/input.json"
    quiet_success && [[ "$PLAIN" == *'ctx: 50% ▰▰▰▰▰▱▱▱▱▱'* ]] || return 1
  done
}

invalid_context_sizes() {
  local size
  for size in 0 -1 true '"08"' '{}' 1e100; do
    printf '{"context_window":{"context_window_size":%s,"used_percentage":50}}' "$size" > "$TEST_TMP/input.json"
    run_line "$TEST_TMP/input.json"
    quiet_success && [[ "$PLAIN" == *'ctx: 59% ▰▰▰▰▰▱▱▱▱▱ (100k/167k)'* ]] || return 1
  done
}

extended_context() {
  printf '%s' '{"context_window":{"context_window_size":1000000,"used_percentage":99.9}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'ctx: 103% ▰▰▰▰▰▰▰▰▰▰ (999k/967k)'* ]]
}

out_of_range_percentages() {
  printf '%s' '{"context_window":{"used_percentage":-20}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'ctx: 0% ▱▱▱▱▱▱▱▱▱▱'* ]] || return 1
  printf '%s' '{"context_window":{"used_percentage":150}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'ctx: 119% ▰▰▰▰▰▰▰▰▰▰ (200k/167k)'* ]]
}

numeric_formats() {
  printf '%s' '{"cost":{"total_duration_ms":6.19999e4,"total_lines_added":42.9},"context_window":{"total_input_tokens":1e6,"total_output_tokens":999.9}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ 1m │ +42 -0 │ ↑1.0M ↓999' ]]
}

numeric_overflow() {
  printf '%s' '{"cost":{"total_duration_ms":1e100,"total_lines_added":1e100,"total_lines_removed":-1},"context_window":{"total_input_tokens":1e100,"total_output_tokens":1e100}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ 0s │ +0 -0 │ ↑0 ↓0' ]]
}

arithmetic_injection() {
  local payload
  printf -v payload 'x[$(touch "%s")]' "$TEST_TMP/unexpected"
  jq -n --arg value "$payload" '{cost:{total_duration_ms:$value},context_window:{total_input_tokens:$value}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [ ! -e "$TEST_TMP/unexpected" ] && [[ "$PLAIN" == *'│ 0s │ +0 -0 │ ↑0 ↓0' ]]
}

integer_boundary() {
  printf '%s' '{"cost":{"total_duration_ms":9007199254740991,"total_lines_added":9007199254740991},"context_window":{"total_input_tokens":9007199254740991}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ 2501999792h59m │ +9007199254740991 -0 │ ↑9007199254.7M ↓0' ]]
}

terminal_controls() {
  run_line "$ROOT/tests/fixtures/terminal-controls.json"
  quiet_success && [[ "$PLAIN" == '◆ Fixture]52;c;inert31m Ω\literal %s │'* ]] && [[ "$PLAIN" == *'│ +0 -0 │'* ]]
}

workspace_branch() {
  jq -n --arg dir "$TEST_TMP/other repo" '{workspace:{current_dir:$dir}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ fixture-other │'* ]]
}

cwd_branch() {
  jq -n --arg dir "$TEST_TMP/other repo" '{workspace:{current_dir:false},cwd:$dir}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ fixture-other │'* ]]
}

workspace_whitespace() {
  local dir="$TEST_TMP/"$'space\tline\nbreak'
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/fixture-whitespace
  jq -n --arg dir "$dir" '{workspace:{current_dir:$dir}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ fixture-whitespace │'* ]]
}

outside_repository() {
  jq -n --arg dir "$TEST_TMP" '{workspace:{current_dir:$dir}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ ? │'* ]]
}

no_stale_branch() {
  git -C "$TEST_TMP/working directory" symbolic-ref HEAD refs/heads/fixture-updated
  run_line "$ROOT/tests/fixtures/session.json"
  git -C "$TEST_TMP/working directory" symbolic-ref HEAD refs/heads/fixture-working
  quiet_success && [[ "$PLAIN" == *'│ fixture-updated │'* ]]
}

branch_controls() {
  local branch=$'fixture-\302\23331m'
  git -C "$TEST_TMP/other repo" symbolic-ref HEAD "refs/heads/$branch"
  jq -n --arg dir "$TEST_TMP/other repo" '{workspace:{current_dir:$dir}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  git -C "$TEST_TMP/other repo" symbolic-ref HEAD refs/heads/fixture-other
  quiet_success && [[ "$PLAIN" == *'│ fixture-31m │'* ]]
}

detached_head() {
  local head
  head=$(git -C "$TEST_TMP/other repo" rev-parse --short HEAD)
  git -C "$TEST_TMP/other repo" checkout -q --detach
  jq -n --arg dir "$TEST_TMP/other repo" '{workspace:{current_dir:$dir}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  git -C "$TEST_TMP/other repo" checkout -q fixture-other
  quiet_success && [[ "$PLAIN" == *"│ $head │"* ]]
}

missing_git() {
  mv "$TEST_TMP/tools/git" "$TEST_TMP/git.saved"
  run_line "$ROOT/tests/fixtures/session.json" "$TEST_TMP/tools"
  mv "$TEST_TMP/git.saved" "$TEST_TMP/tools/git"
  quiet_success && [[ "$PLAIN" == *'│ ? │'* ]]
}

missing_jq() {
  mv "$TEST_TMP/tools/jq" "$TEST_TMP/jq.saved"
  run_line "$ROOT/tests/fixtures/session.json" "$TEST_TMP/tools"
  mv "$TEST_TMP/jq.saved" "$TEST_TMP/tools/jq"
  quiet_success && [[ "$PLAIN" == *'│ fixture-working │'* ]]
}

minimal_tools() {
  mkdir -p "$TEST_TMP/minimal-tools"
  local tool
  for tool in git; do
    ln -s "$(command -v "$tool")" "$TEST_TMP/minimal-tools/$tool"
  done
  run_line "$ROOT/tests/fixtures/session.json" "$TEST_TMP/minimal-tools"
  quiet_success && [[ "$PLAIN" == *'│ fixture-working │'* ]]
}

exact_ansi() {
  local expected
  run_line "$ROOT/tests/fixtures/session.json"
  printf -v expected '\033[36m\033[1m◆\033[0m \033[37m\033[1mClaude Fixture\033[0m\033[2m │ \033[0m\033[32mctx: 41%% ▰▰▰▰▱▱▱▱▱▱\033[0m \033[2m(70k/167k)\033[0m\033[2m │ \033[0m\033[35mfixture-working\033[0m\033[2m │ \033[0m\033[2m1h2m\033[0m\033[2m │ \033[0m\033[32m+42\033[0m \033[31m-7\033[0m\033[2m │ \033[0m\033[2m↑285k ↓18k\033[0m'
  quiet_success && [ "$(cat "$TEST_TMP/stdout")" = "$expected" ]
}

huge_exponent() {
  printf '%s' '{"future":1e10000,"cost":{"total_lines_added":1e99999},"context_window":{"context_window_size":1e400}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'ctx: 0% ▱▱▱▱▱▱▱▱▱▱ (0/167k)'* ]] && [[ "$PLAIN" == *'│ +0 -0 │'* ]]
}

oversized_input() {
  jq -n '{padding:("x" * 1048576)}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [ "$PLAIN" = '◆ statusline: invalid JSON' ]
}

unicode_labels() {
  jq -n --arg model '日本語 Ω 🦀 é \literal %s' '{model:{display_name:$model}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == '◆ 日本語 Ω 🦀 é \literal %s │'* ]]
}

empty_labels() {
  printf '%s' '{"model":{"display_name":"\u001b\u0000\u009f"}}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == '◆ ... │'* ]]
}

nul_directory_fallback() {
  jq -n --arg dir "$TEST_TMP/other repo" '{workspace:{current_dir:"bad\u0000path"},cwd:$dir}' > "$TEST_TMP/input.json"
  run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ fixture-other │'* ]]
}

inherited_git_directory() {
  jq -n --arg dir "$TEST_TMP/other repo" '{workspace:{current_dir:$dir}}' > "$TEST_TMP/input.json"
  GIT_DIR="$TEST_TMP/working directory/.git" GIT_WORK_TREE="$TEST_TMP/working directory" run_line "$TEST_TMP/input.json"
  quiet_success && [[ "$PLAIN" == *'│ fixture-other │'* ]]
}

missing_binary() {
  local saved=$STATUSLINE_BIN
  STATUSLINE_BIN="$TEST_TMP/missing-binary"
  run_line "$ROOT/tests/fixtures/session.json"
  STATUSLINE_BIN=$saved
  quiet_success && [ "$PLAIN" = '◆ statusline: Rust binary is required' ]
}

installed_launcher() {
  local saved_binary=$STATUSLINE_BIN
  local saved_script=$SCRIPT
  mkdir -p "$TEST_TMP/installed path"
  cp "$SCRIPT" "$TEST_TMP/installed path/statusline.sh"
  cp "$STATUSLINE_BIN" "$TEST_TMP/installed path/claude-statusline"
  SCRIPT="$TEST_TMP/installed path/statusline.sh"
  STATUSLINE_BIN=''
  run_line "$ROOT/tests/fixtures/session.json" "$TEST_TMP/tools"
  SCRIPT=$saved_script
  STATUSLINE_BIN=$saved_binary
  quiet_success && [[ "$PLAIN" == *'│ fixture-working │'* ]]
}

for test_name in normal_session malformed_json empty_input invalid_top_levels \
  invalid_types invalid_nested_objects initial_session small_context_windows invalid_context_sizes \
  extended_context out_of_range_percentages numeric_formats numeric_overflow \
  arithmetic_injection integer_boundary terminal_controls workspace_branch cwd_branch \
  workspace_whitespace outside_repository no_stale_branch branch_controls detached_head \
  missing_git missing_jq minimal_tools exact_ansi huge_exponent oversized_input \
  unicode_labels empty_labels nul_directory_fallback inherited_git_directory \
  missing_binary installed_launcher; do
  if [ -n "$TEST_FILTER" ] && [[ "$test_name" != *"$TEST_FILTER"* ]]; then continue; fi
  if "$test_name"; then
    printf 'PASS %s\n' "$test_name"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL %s (exit %s; output %q)\n' "$test_name" "${STATUS:-unknown}" "${PLAIN:-}"
    if [ -s "$TEST_TMP/stderr" ]; then cat "$TEST_TMP/stderr"; fi
    FAILED=$((FAILED + 1))
  fi
done
printf '%s passed; %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
