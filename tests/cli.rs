use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "claude-statusline-cli-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn run(&self, input: &[u8], launcher: bool) -> Output {
        let binary = env!("CARGO_BIN_EXE_claude-statusline");
        let mut command = if launcher {
            let mut command = Command::new("/bin/bash");
            command.arg(concat!(env!("CARGO_MANIFEST_DIR"), "/statusline.sh"));
            command
        } else {
            Command::new(binary)
        };
        let mut child = command
            .env_clear()
            .env("HOME", &self.0)
            .env("PATH", &self.0)
            .env("STATUSLINE_BIN", binary)
            .current_dir(&self.0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // An oversized stream may be rejected before its writer finishes.
        let _ = child.stdin.take().unwrap().write_all(input);
        child.wait_with_output().unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn quiet_line(output: &Output) -> &str {
    assert!(output.status.success(), "{:?}", output.status);
    assert!(output.stderr.is_empty(), "{:?}", output.stderr);
    let line = std::str::from_utf8(&output.stdout).unwrap();
    assert_eq!(line.bytes().filter(|b| *b == b'\n').count(), 1);
    line
}

#[test]
fn exact_session_ansi_and_compatibility_launcher() {
    let fixture = Fixture::new();
    let input = include_bytes!("fixtures/session.json");
    let output = fixture.run(input, false);
    assert_eq!(
        quiet_line(&output),
        concat!(
            "\x1b[36m\x1b[1m◆\x1b[0m \x1b[37m\x1b[1mClaude Fixture\x1b[0m\x1b[2m │ \x1b[0m",
            "\x1b[32mctx: 41% ▰▰▰▰▱▱▱▱▱▱\x1b[0m \x1b[2m(70k/167k)\x1b[0m\x1b[2m │ \x1b[0m",
            "\x1b[35m?\x1b[0m\x1b[2m │ \x1b[0m\x1b[2m1h2m\x1b[0m\x1b[2m │ \x1b[0m",
            "\x1b[32m+42\x1b[0m \x1b[31m-7\x1b[0m\x1b[2m │ \x1b[0m\x1b[2m↑285k ↓18k\x1b[0m\n",
        )
    );
    let launched = fixture.run(input, true);
    assert_eq!(quiet_line(&launched), quiet_line(&output));
}

#[test]
fn malformed_empty_multiple_and_non_object_inputs_are_quiet() {
    let fixture = Fixture::new();
    for input in [
        &b""[..],
        b"null",
        b"[]",
        b"true",
        b"42",
        b"{} {}",
        b"{} trailing",
        b"{\"model\":",
        b"{\"model\":\"\xff\"}",
        b"{\"cost\":{\"x\":01}}",
        b"{\"model\":\"line\nbreak\"}",
        b"{\"cost\":{\"x\":NaN}}",
        b"{\"model\":{\"display_name\":\"\\ud800\"}}",
        b"{\"future\":\"\\ud800\"}",
        b"{\"future\":\"\\udc00\"}",
    ] {
        assert_eq!(
            quiet_line(&fixture.run(input, false)),
            "◆ statusline: invalid JSON\n",
            "{input:?}"
        );
    }
}

#[test]
fn input_limit_is_inclusive_and_oversized_streams_fail_wholly() {
    let fixture = Fixture::new();
    let mut input = b"{}".to_vec();
    input.resize(claude_statusline::MAX_INPUT_BYTES, b' ');
    assert!(quiet_line(&fixture.run(&input, false)).starts_with("\x1b[36m"));
    input.push(b' ');
    assert_eq!(
        quiet_line(&fixture.run(&input, false)),
        "◆ statusline: invalid JSON\n"
    );
    let input = format!(
        "{{\"model\":{{\"display_name\":\"{}\"}}}}",
        "x".repeat(2 * claude_statusline::MAX_INPUT_BYTES)
    );
    assert_eq!(
        quiet_line(&fixture.run(input.as_bytes(), false)),
        "◆ statusline: invalid JSON\n"
    );
}

#[test]
fn huge_exponents_default_metrics_without_rejecting_valid_json() {
    let fixture = Fixture::new();
    let baseline = fixture.run(b"{}", false);
    let overflow = fixture.run(br#"{"future":1e10000,"cost":{"total_duration_ms":1e99999,"total_lines_added":9007199254740992},"context_window":{"total_input_tokens":1e400,"used_percentage":1e400,"context_window_size":1e400}}"#, false);
    assert_eq!(quiet_line(&overflow), quiet_line(&baseline));
}

#[test]
fn decimal_range_check_happens_before_lossy_float_conversion() {
    let fixture = Fixture::new();
    let baseline = fixture.run(b"{}", false);
    for value in [
        "9007199254740991.1",
        "9.0071992547409911e15",
        "9007199254740992",
        "-1e-10000",
    ] {
        let input = format!(
            r#"{{"cost":{{"total_duration_ms":{value},"total_lines_added":{value}}},"context_window":{{"total_input_tokens":{value}}}}}"#
        );
        assert_eq!(
            quiet_line(&fixture.run(input.as_bytes(), false)),
            quiet_line(&baseline),
            "{value}"
        );
    }
}

#[test]
fn negative_zero_count_text_matches_the_previous_renderer() {
    let fixture = Fixture::new();
    let input = br#"{"cost":{"total_lines_added":-0,"total_lines_removed":-0.0},"context_window":{"used_percentage":-0,"total_input_tokens":-0.0}}"#;
    let output = fixture.run(input, false);
    let line = quiet_line(&output);
    assert!(line.contains("(-0/167k)"));
    assert!(line.contains("\x1b[32m+-0\x1b[0m \x1b[31m--0\x1b[0m"));
    assert!(line.contains("↑-0 ↓0"));
}

#[test]
fn labels_keep_unicode_literals_and_strip_every_terminal_control() {
    let fixture = Fixture::new();
    let controls: String = (0..=31)
        .chain(127..=159)
        .map(|c| char::from_u32(c).unwrap())
        .collect();
    let label = format!("{controls}日本語 Ω 🦀 e\u{301} \\literal %s $(echo inert)");
    let input = format!(
        "{{\"model\":{{\"display_name\":{}}}}}",
        serde_json::to_string(&label).unwrap()
    );
    let output = fixture.run(input.as_bytes(), false);
    let line = quiet_line(&output);
    assert!(line.contains("日本語 Ω 🦀 e\u{301} \\literal %s $(echo inert)\x1b[0m"));
    let mut stripped = line.to_owned();
    for code in ["0", "1", "2", "31", "32", "35", "36", "37"] {
        stripped = stripped.replace(&format!("\x1b[{code}m"), "");
    }
    assert!(!stripped
        .trim_end_matches('\n')
        .chars()
        .any(char::is_control));
}

#[test]
fn context_color_thresholds_and_capped_bar_are_exact() {
    let fixture = Fixture::new();
    for (percent, color, bar) in [
        (49, "32", "▰▰▰▰▱▱▱▱▱▱"),
        (50, "33", "▰▰▰▰▰▱▱▱▱▱"),
        (79, "33", "▰▰▰▰▰▰▰▱▱▱"),
        (80, "31", "▰▰▰▰▰▰▰▰▱▱"),
        (100, "31", "▰▰▰▰▰▰▰▰▰▰"),
    ] {
        let input = format!(
            r#"{{"context_window":{{"context_window_size":1000,"used_percentage":{percent}}}}}"#
        );
        let output = fixture.run(input.as_bytes(), false);
        assert!(quiet_line(&output).contains(&format!("\x1b[{color}mctx: {percent}% {bar}\x1b[0m")));
    }
}

#[cfg(unix)]
#[test]
fn invalid_utf8_git_ref_uses_one_replacement_in_direct_and_launcher_output() {
    use std::ffi::OsString;
    use std::os::unix::{ffi::OsStringExt, fs::symlink};

    let fixture = Fixture::new();
    let git = std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .map(|directory| directory.join("git"))
        .find(|path| path.is_file())
        .expect("Git is required for this synthetic ref regression");
    symlink(&git, fixture.0.join("git")).unwrap();
    assert!(Command::new(&git)
        .args(["init", "-q"])
        .current_dir(&fixture.0)
        .env_clear()
        .env("HOME", &fixture.0)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap()
        .status
        .success());
    for suffix in [&b"\xed\xa0\x80"[..], &b"\xe2A"[..]] {
        let mut reference = b"refs/heads/invalid-".to_vec();
        reference.extend_from_slice(suffix);
        assert!(Command::new(&git)
            .args(["symbolic-ref", "HEAD"])
            .arg(OsString::from_vec(reference))
            .current_dir(&fixture.0)
            .env_clear()
            .env("HOME", &fixture.0)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap()
            .status
            .success());
        let input = serde_json::to_vec(&serde_json::json!({
            "workspace": {"current_dir": fixture.0},
        }))
        .unwrap();
        let direct = fixture.run(&input, false);
        let launched = fixture.run(&input, true);
        assert!(quiet_line(&direct).contains("\x1b[35minvalid-�\x1b[0m"));
        assert_eq!(quiet_line(&launched), quiet_line(&direct));
    }
}
