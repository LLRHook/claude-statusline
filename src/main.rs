use std::io::{self, Write};

fn main() {
    let line = claude_statusline::status_line(io::stdin().lock());
    // A closed status-line consumer is not a reason to print a panic to stderr.
    let _ = io::stdout().lock().write_all(line.as_bytes());
}
