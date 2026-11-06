use serde_json::value::RawValue;
use std::collections::BTreeMap;
use std::io::Read;
use std::process::Command;

/// Bound each refresh, including unused fields. Read at most one byte beyond it.
pub const MAX_INPUT_BYTES: usize = 1024 * 1024;
const INVALID_JSON: &str = "◆ statusline: invalid JSON\n";
const MAX_SAFE_NUMBER: f64 = 9_007_199_254_740_991.0;
const AUTOCOMPACT_BUFFER: u64 = 33_000;
const DEFAULT_WINDOW: u64 = 200_000;

const RESET: &str = "\x1b[0m";
const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const RED: &str = "\x1b[31m";
const CYAN: &str = "\x1b[36m";
const MAGENTA: &str = "\x1b[35m";
const WHITE: &str = "\x1b[37m";
const SEP: &str = "\x1b[2m │ \x1b[0m";

type Object<'a> = BTreeMap<String, &'a RawValue>;

struct Metrics {
    model: String,
    context_percent: u64,
    context_used: f64,
    context_usable: u64,
    duration_ms: u64,
    lines_added: f64,
    lines_removed: f64,
    input_tokens: f64,
    output_tokens: f64,
    directory: String,
}

/// Render one complete object, or the existing quiet, successful error line.
pub fn status_line(reader: impl Read) -> String {
    let mut input = Vec::new();
    if reader
        .take((MAX_INPUT_BYTES + 1) as u64)
        .read_to_end(&mut input)
        .is_err()
        || input.len() > MAX_INPUT_BYTES
    {
        return INVALID_JSON.to_owned();
    }
    let Some(metrics) = Metrics::parse(&input) else {
        return INVALID_JSON.to_owned();
    };
    let branch = git_branch(&metrics.directory);
    metrics.render(&branch)
}

fn object<'a>(field: Option<&&'a RawValue>) -> Object<'a> {
    field
        .and_then(|raw| serde_json::from_str(raw.get()).ok())
        .unwrap_or_default()
}

fn string(field: Option<&&RawValue>) -> Option<String> {
    field.and_then(|raw| serde_json::from_str(raw.get()).ok())
}

fn number(field: Option<&&RawValue>, fallback: f64) -> f64 {
    // RawValue validates JSON first, so numeric strings, objects and expressions
    // cannot become numbers. Reject nonfinite and out-of-range numeric values
    // before converting to integers or doing any arithmetic.
    field
        .filter(|raw| in_numeric_range(raw.get()))
        .and_then(|raw| raw.get().parse::<f64>().ok())
        .filter(|value| value.is_finite() && (0.0..=MAX_SAFE_NUMBER).contains(value))
        .unwrap_or(fallback)
}

fn count(field: Option<&&RawValue>) -> f64 {
    // Retain the sign of literal negative zero in printed counts, as jq does.
    number(field, 0.0).floor()
}

fn in_numeric_range(raw: &str) -> bool {
    // Compare the exact decimal magnitude before binary64 rounding. Otherwise
    // e.g. 9007199254740991.1 rounds down into the permitted integer range.
    let unsigned = raw.strip_prefix('-').unwrap_or(raw);
    let (mantissa, exponent) = unsigned.split_once(['e', 'E']).unwrap_or((unsigned, "0"));
    let exponent = exponent.parse::<i64>().unwrap_or_else(|_| {
        if exponent.starts_with('-') {
            i64::MIN
        } else {
            i64::MAX
        }
    });
    let fraction_len = mantissa
        .split_once('.')
        .map_or(0, |(_, fraction)| fraction.len());
    let digits = mantissa.replace('.', "");
    let significant = digits.trim_start_matches('0');
    if significant.is_empty() {
        return true;
    }
    if raw.starts_with('-') || !significant.bytes().all(|byte| byte.is_ascii_digit()) {
        return false;
    }
    let integer_digits = (significant.len() as i64)
        .saturating_add(exponent)
        .saturating_sub(fraction_len as i64);
    match integer_digits.cmp(&16) {
        std::cmp::Ordering::Less => true,
        std::cmp::Ordering::Greater => false,
        std::cmp::Ordering::Equal => {
            let prefix = significant.bytes().chain(std::iter::repeat(b'0')).take(16);
            match prefix.cmp(b"9007199254740991".iter().copied()) {
                std::cmp::Ordering::Less => true,
                std::cmp::Ordering::Greater => false,
                std::cmp::Ordering::Equal => significant.bytes().skip(16).all(|b| b == b'0'),
            }
        }
    }
}

fn valid_strings(input: &[u8]) -> bool {
    // RawValue defers string decoding, including surrogate validation. Decode
    // each complete JSON string with serde_json so malformed Unicode anywhere
    // (even in an unused field) rejects the whole input. JSON structure and
    // numeric syntax are still validated by serde_json, not this token scan.
    if std::str::from_utf8(input).is_err() {
        return false;
    }
    let mut cursor = 0;
    while cursor < input.len() {
        if input[cursor] != b'"' {
            cursor += 1;
            continue;
        }
        let start = cursor;
        cursor += 1;
        loop {
            match input.get(cursor) {
                Some(b'\\') => cursor += 2,
                Some(b'"') => {
                    cursor += 1;
                    if serde_json::from_slice::<String>(&input[start..cursor]).is_err() {
                        return false;
                    }
                    break;
                }
                Some(_) => cursor += 1,
                None => return false,
            }
        }
    }
    true
}

fn safe_label(value: &str, fallback: &str) -> String {
    let label: String = value.chars().filter(|c| !c.is_control()).collect();
    if label.is_empty() {
        fallback.to_owned()
    } else {
        label
    }
}

fn directory(field: Option<&&RawValue>) -> Option<String> {
    string(field).filter(|s| !s.is_empty() && !s.contains('\0'))
}

impl Metrics {
    fn parse(input: &[u8]) -> Option<Self> {
        if !valid_strings(input) {
            return None;
        }
        // Borrow raw field values: even a valid 1e10000 in an unused field must
        // not invalidate the session. Maps preserve last-key-wins semantics and
        // do not reinterpret objects containing serde's private number key.
        let root: Object<'_> = serde_json::from_slice(input).ok()?;
        let model = object(root.get("model"));
        let cost = object(root.get("cost"));
        let context = object(root.get("context_window"));
        let workspace = object(root.get("workspace"));
        let max = number(context.get("context_window_size"), DEFAULT_WINDOW as f64).floor() as u64;
        let max = if max == 0 { DEFAULT_WINDOW } else { max };
        let usable = if max > AUTOCOMPACT_BUFFER {
            max - AUTOCOMPACT_BUFFER
        } else {
            max
        };
        let percent = number(context.get("used_percentage"), 0.0).min(100.0);
        // Preserve the shell/jq floating-point operation order and floor only
        // at the display boundary (not the fractional input percentage).
        let used = percent * max as f64 / 100.0;
        Some(Self {
            model: safe_label(
                &string(model.get("display_name")).unwrap_or_default(),
                "...",
            ),
            context_percent: (used * 100.0 / usable as f64).floor() as u64,
            context_used: used.floor(),
            context_usable: usable,
            duration_ms: count(cost.get("total_duration_ms")) as u64,
            lines_added: count(cost.get("total_lines_added")),
            lines_removed: count(cost.get("total_lines_removed")),
            input_tokens: count(context.get("total_input_tokens")),
            output_tokens: count(context.get("total_output_tokens")),
            directory: directory(workspace.get("current_dir"))
                .or_else(|| directory(root.get("cwd")))
                .unwrap_or_else(|| ".".to_owned()),
        })
    }

    fn render(&self, branch: &str) -> String {
        let color = if self.context_percent >= 80 {
            RED
        } else if self.context_percent >= 50 {
            YELLOW
        } else {
            GREEN
        };
        let filled = (self.context_percent / 10).min(10) as usize;
        let bar = "▰".repeat(filled) + &"▱".repeat(10 - filled);
        format!(
            "{CYAN}{BOLD}◆{RESET} {WHITE}{BOLD}{}{RESET}{SEP}\
             {color}ctx: {}% {bar}{RESET} {DIM}({}/{}){RESET}{SEP}\
             {MAGENTA}{branch}{RESET}{SEP}{DIM}{}{RESET}{SEP}\
             {GREEN}+{}{RESET} {RED}-{}{RESET}{SEP}{DIM}↑{} ↓{}{RESET}\n",
            self.model,
            self.context_percent,
            format_tokens(self.context_used),
            format_tokens(self.context_usable as f64),
            format_duration(self.duration_ms),
            self.lines_added,
            self.lines_removed,
            format_tokens(self.input_tokens),
            format_tokens(self.output_tokens),
        )
    }
}

fn git_branch(directory: &str) -> String {
    for args in [
        &["symbolic-ref", "--quiet", "--short", "HEAD"][..],
        &["rev-parse", "--short", "HEAD"][..],
    ] {
        let output = Command::new("git")
            .args(["-C", directory])
            .args(args)
            // Explicit workspace selection takes precedence over inherited
            // repository selectors, including from a caller running in a hook.
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .env_remove("GIT_NAMESPACE")
            .env_remove("GIT_PREFIX")
            .output();
        if let Ok(output) = output {
            if output.status.success() {
                return safe_label(&String::from_utf8_lossy(&output.stdout), "?");
            }
        }
    }
    "?".to_owned()
}

fn format_duration(ms: u64) -> String {
    let seconds = ms / 1000;
    let hours = seconds / 3600;
    let minutes = seconds % 3600 / 60;
    if hours > 0 {
        format!("{hours}h{minutes}m")
    } else if minutes > 0 {
        format!("{minutes}m")
    } else {
        format!("{seconds}s")
    }
}

fn format_tokens(tokens: f64) -> String {
    // Like awk's printf, Rust's precision formatting rounds ties to even.
    if tokens >= 1_000_000.0 {
        format!("{:.1}M", tokens / 1_000_000.0)
    } else if tokens >= 1000.0 {
        format!("{:.0}k", tokens / 1000.0)
    } else {
        tokens.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duration_boundaries() {
        for (ms, expected) in [
            (0, "0s"),
            (999, "0s"),
            (59_999, "59s"),
            (60_000, "1m"),
            (3_599_999, "59m"),
            (3_600_000, "1h0m"),
            (3_723_000, "1h2m"),
            (9_007_199_254_740_991, "2501999792h59m"),
        ] {
            assert_eq!(format_duration(ms), expected);
        }
    }

    #[test]
    fn token_rounding_matches_printf() {
        for (tokens, expected) in [
            (0u64, "0"),
            (999, "999"),
            (1000, "1k"),
            (1500, "2k"),
            (2500, "2k"),
            (999_999, "1000k"),
            (1_000_000, "1.0M"),
            (1_250_000, "1.2M"),
            (1_750_000, "1.8M"),
            (9_007_199_254_740_991, "9007199254.7M"),
        ] {
            assert_eq!(format_tokens(tokens as f64), expected);
        }
    }

    #[test]
    fn label_controls_and_unicode() {
        assert_eq!(safe_label("\0\x1b\r\n\t\u{7f}\u{9b}", "..."), "...");
        assert_eq!(
            safe_label("日本語 Ω 🦀 e\u{301} \\literal %s", "..."),
            "日本語 Ω 🦀 e\u{301} \\literal %s"
        );
    }

    #[test]
    fn fractional_context_and_small_windows() {
        let m = Metrics::parse(br#"{"context_window":{"used_percentage":34.9}}"#).unwrap();
        assert_eq!(
            (m.context_percent, m.context_used, m.context_usable),
            (41, 69800.0, 167000)
        );
        for size in [1, 32000, 33000, 33001, 1_000_000] {
            let input = format!(
                r#"{{"context_window":{{"context_window_size":{size},"used_percentage":100}}}}"#
            );
            let m = Metrics::parse(input.as_bytes()).unwrap();
            assert!(m.context_usable > 0);
            assert!(m.context_percent >= 100);
        }
    }

    #[test]
    fn overflow_and_mistyped_counts_default_without_evaluation() {
        for value in [
            "null",
            "true",
            "[]",
            r#""1+2""#,
            "1e10000",
            "-1",
            "9007199254740992",
            r#"{"$serde_json::private::Number":"123"}"#,
        ] {
            let input = format!(r#"{{"cost":{{"total_lines_added":{value}}}}}"#);
            assert_eq!(
                Metrics::parse(input.as_bytes()).unwrap().lines_added,
                0.0,
                "{value}"
            );
        }
        let m = Metrics::parse(
            br#"{"cost":{"total_lines_added":9007199254740991,"total_lines_removed":42.9}}"#,
        )
        .unwrap();
        assert_eq!(
            (m.lines_added, m.lines_removed),
            (9_007_199_254_740_991.0, 42.0)
        );
    }

    #[test]
    fn malformed_and_multiple_inputs_fail_as_a_whole() {
        for input in [
            "",
            "null",
            "[]",
            "true",
            "42",
            "\"text\"",
            "{} {}",
            "{}x",
            "{\"model\":",
            "{\"x\":NaN}",
        ] {
            assert!(Metrics::parse(input.as_bytes()).is_none(), "{input}");
        }
    }

    #[test]
    fn defaults_and_duplicate_or_escaped_keys() {
        let m = Metrics::parse(br#"{"model":[],"cost":true,"context_window":null,"workspace":42}"#)
            .unwrap();
        assert_eq!(m.model, "...");
        assert_eq!(m.directory, ".");
        let m = Metrics::parse(br#"{"cost":null,"\u0063ost":{"total_lines_added":7}}"#).unwrap();
        assert_eq!(m.lines_added, 7.0);
    }

    #[test]
    fn paths_preserve_whitespace_but_reject_nul() {
        let m = Metrics::parse(
            br#"{"workspace":{"current_dir":"space\tline\nbreak"},"cwd":"fallback"}"#,
        )
        .unwrap();
        assert_eq!(m.directory, "space\tline\nbreak");
        let m =
            Metrics::parse(br#"{"workspace":{"current_dir":"bad\u0000path"},"cwd":"fallback"}"#)
                .unwrap();
        assert_eq!(m.directory, "fallback");
    }

    #[test]
    fn read_errors_are_quiet_invalid_input() {
        struct Broken;
        impl Read for Broken {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                Err(std::io::Error::other("synthetic failure"))
            }
        }
        assert_eq!(status_line(Broken), INVALID_JSON);
    }
}
