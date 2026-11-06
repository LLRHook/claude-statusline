#!/usr/bin/env python3
"""Byte-for-byte migration check against an explicitly supplied old renderer.

Uses only synthetic input and private temporary Git repositories. The reference
is never obtained from a user's configuration, history, or session directory.
"""
import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    reference = args.reference.resolve(strict=True)
    binary = args.binary.resolve(strict=True)
    fixtures = Path(__file__).resolve().parent / "fixtures"
    with tempfile.TemporaryDirectory(prefix="claude-statusline-parity-") as temp:
        root = Path(temp)
        home = root / "home"
        home.mkdir()
        # Keep only tools needed by the reference, no inherited Git selection or
        # configuration. All fixture commits use the personal project identity.
        env = {"PATH": os.environ["PATH"], "HOME": str(home),
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
               "GIT_AUTHOR_NAME": "Victor Ivanov", "GIT_COMMITTER_NAME": "Victor Ivanov",
               "GIT_AUTHOR_EMAIL": "victor.n.ivanov@gmail.com",
               "GIT_COMMITTER_EMAIL": "victor.n.ivanov@gmail.com",
               "LC_ALL": "C"}

        def git(directory, *arguments):
            return subprocess.run(["git", "-C", str(directory), *arguments],
                                  env=env, check=True, capture_output=True)

        repos = [root / "working directory", root / "space\tline\nbreak"]
        for index, repo in enumerate(repos):
            repo.mkdir()
            git(repo, "init", "-q")
            git(repo, "symbolic-ref", "HEAD", f"refs/heads/fixture-{index}")
            git(repo, "commit", "-q", "--allow-empty", "-m", "Synthetic fixture")

        cases = []

        def add(name, value):
            cases.append((name, json.dumps(value, ensure_ascii=True).encode()))

        for path in sorted(fixtures.glob("*.json")):
            cases.append((path.stem, path.read_bytes()))
        for index, raw in enumerate([b"", b"null", b"[]", b"42", b"true", b'"text"',
                                     b"{} {}", b"{} trailing", b'{"cost":', b'{}\nnull']):
            cases.append((f"invalid-{index}", raw))
        for model in [None, "", 42, [], {}, "\x00\x1b\r\n\x7f\x9f",
                      "日本語 Ω 🦀 e\u0301 \\literal %s $(echo inert)"]:
            add(f"label-{len(cases)}", {"model": {"display_name": model}})
        for value in [None, -1, "1+2", "x[$(echo inert)]", True, {}, [],
                      0, 0.9, 999, 1000, 1500, 2500, 999999, 1000000,
                      1250000, 1750000, 9007199254740991, 9007199254740992, 1e100]:
            add(f"counts-{len(cases)}", {
                "cost": dict.fromkeys(["total_duration_ms", "total_lines_added", "total_lines_removed"], value),
                "context_window": dict.fromkeys(["total_input_tokens", "total_output_tokens"], value)})
        for window in [None, 0, -1, "08", 1, 32000, 33000, 33001, 200000, 1000000]:
            for percent in [-20, 0, 34.9, 49.9, 50, 79.9, 80, 99.9, 100, 150]:
                add(f"context-{len(cases)}", {"context_window": {
                    "context_window_size": window, "used_percentage": percent}})
        for directory in [str(repos[1]), str(root), "missing", "", None, False, "bad\0path"]:
            add(f"workspace-{len(cases)}", {"workspace": {"current_dir": directory}, "cwd": str(repos[1])})
        for index, raw in enumerate([
                b'{"future":1e10000,"cost":{"total_lines_added":1e400}}',
                b'{"cost":{"total_lines_added":{"$serde_json::private::Number":"123"}}}',
                b'{"future":"\\ud800"}',
                b'{"cost":{"total_lines_added":-0,"total_lines_removed":-0.0},"context_window":{"total_input_tokens":-0.0,"used_percentage":-0}}',
                b'{"cost":{"total_lines_added":9007199254740991.1},"context_window":{"total_input_tokens":9.0071992547409911e15}}',
                b'{"cost":null,"\\u0063ost":{"total_lines_added":7}}']):
            cases.append((f"numeric-lexeme-{index}", raw))
        rng = random.Random(20261106)
        for index in range(64):
            add(f"seeded-{index}", {"context_window": {
                "context_window_size": rng.choice([33001, 64000, 128000, 200000, 1000000]),
                "used_percentage": rng.random() * 130,
                "total_input_tokens": rng.randrange(10000000),
                "total_output_tokens": rng.randrange(1000000)},
                "cost": {"total_duration_ms": rng.randrange(10000000),
                         "total_lines_added": rng.random() * 1000}})

        def compare(name, payload):
            results = []
            for command in [["/bin/bash", str(reference)], [str(binary)]]:
                output = subprocess.run(command, input=payload, cwd=repos[0], env=env,
                                        capture_output=True, timeout=10)
                results.append((output.returncode, output.stdout, output.stderr))
            if results[0] != results[1]:
                raise AssertionError(f"{name}: input={payload!r}\nshell={results[0]!r}\nrust={results[1]!r}")
            print(f"PASS {name}")

        for name, payload in cases:
            compare(name, payload)
        head = git(repos[1], "rev-parse", "HEAD").stdout.decode().strip()
        for label in ["fixture-更新", "fixture-\x9b31m", "fixture-changed"]:
            git(repos[1], "update-ref", f"refs/heads/{label}", head)
            git(repos[1], "symbolic-ref", "HEAD", f"refs/heads/{label}")
            compare(f"branch-{label!r}", json.dumps({"workspace": {"current_dir": str(repos[1])}}).encode())
        git(repos[1], "checkout", "-q", "--detach")
        compare("detached", json.dumps({"workspace": {"current_dir": str(repos[1])}}).encode())
        print(f"{len(cases) + 4} passed; 0 failed (exact stdout/stderr/exit parity)")


if __name__ == "__main__":
    main()
