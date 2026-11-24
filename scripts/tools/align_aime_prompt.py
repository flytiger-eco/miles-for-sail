#!/usr/bin/env python3
# Copyright © 2026 Zhejiang Runhe Cloud Intelligence Technology Co., Ltd

"""Align test-set prompt format to the training-data prompt template.

Extract the common prefix (instruction preamble) and common suffix (output
format reminder) from the user content of every record in the training data
(--train), then wrap each question in the test data (--test) with the same
template and write it out. Labels are preserved verbatim and the input file is
never overwritten. Records that already carry the template are stripped first
and then re-wrapped (idempotent).

Usage::

    python3 align_aime_prompt.py --train <train.jsonl> --test <test.jsonl>
    python3 align_aime_prompt.py --train <train.jsonl> --test <test.jsonl> --out <out.jsonl>

Default output: <same dir as test>/<test stem>-aligned.jsonl; if that directory
is not writable, use --out to specify another path.
"""

import argparse
import json
from pathlib import Path

SEP = "\n\n"


def load_jsonl(path: Path) -> list:
    """Read a jsonl file, asserting each prompt is exactly one user message."""
    records = []
    with open(path, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            rec = json.loads(line)
            prompt = rec.get("prompt")
            if (not isinstance(prompt, list) or len(prompt) != 1
                or prompt[0].get("role") != "user"
                or not isinstance(prompt[0].get("content"), str)):
                raise SystemExit(f"{path} record {i}: prompt must be a single user message")
            records.append(rec)
    return records


def common_affixes(contents: list) -> tuple:
    """Return the longest common prefix and longest common suffix of all contents."""
    prefix, suffix = contents[0], contents[0]
    for c in contents[1:]:
        n = min(len(prefix), len(c)); i = 0
        while i < n and prefix[i] == c[i]: i += 1
        prefix = prefix[:i]
        n = min(len(suffix), len(c)); i = 0
        while i < n and suffix[-1 - i] == c[-1 - i]: i += 1
        suffix = suffix[len(suffix) - i:]
    return prefix, suffix


def extract_template(train_path: Path) -> tuple:
    """Extract the (prefix, suffix) template from training data; both must be
    separated from the question body by a blank line."""
    records = load_jsonl(train_path)
    if len(records) < 2:
        raise SystemExit("training data needs at least 2 records to tell template from question body")
    contents = [r["prompt"][0]["content"] for r in records]
    prefix, suffix = common_affixes(contents)
    if not prefix.endswith(SEP):
        idx = prefix.rfind(SEP)
        prefix = prefix[: idx + len(SEP)] if idx != -1 else ""
    if not suffix.startswith(SEP):
        idx = suffix.find(SEP)
        suffix = suffix[idx:] if idx != -1 else ""
    body = contents[0][len(prefix): len(contents[0]) - len(suffix)]
    if not prefix or not suffix or not body.strip():
        raise SystemExit("no consistent prompt template detected in training data "
            "(common prefix/suffix must be separated from the body by a blank line): "
            f"prefix={prefix[:60]!r} suffix={suffix[:60]!r}")
    return prefix, suffix


def main() -> None:
    parser = argparse.ArgumentParser(description="Align test-data prompts to the training-data template")
    parser.add_argument("--train", required=True, type=Path, help="training data jsonl (template source)")
    parser.add_argument("--test", required=True, type=Path, help="test data jsonl (to be aligned)")
    parser.add_argument("--out", type=Path, help="output jsonl (default <same dir as test>/<stem>-aligned.jsonl)")
    args = parser.parse_args()

    prefix, suffix = extract_template(args.train)
    print(f"template prefix: {prefix!r}")
    print(f"template suffix: {suffix!r}")

    out = args.out or args.test.parent / f"{args.test.stem}-aligned.jsonl"
    records = load_jsonl(args.test)
    try:
        with open(out, "w", encoding="utf-8") as fout:
            for rec in records:
                content = rec["prompt"][0]["content"]
                if content.startswith(prefix) and content.endswith(suffix):
                    body = content[len(prefix): len(content) - len(suffix)]
                else:
                    body = content
                aligned = {"prompt": [{"role": "user", "content": f"{prefix}{body.strip()}{suffix}"}],
                    "label": rec.get("label")}
                fout.write(json.dumps(aligned, ensure_ascii=False) + "\n")
    except PermissionError:
        raise SystemExit(f"output directory not writable: {out.parent}; use --out to specify another path")

    with open(out, encoding="utf-8") as f:
        for src, line in zip(records, f):
            d = json.loads(line)
            content = d["prompt"][0]["content"]
            assert content.startswith(prefix) and content.endswith(suffix)
            assert d["label"] == src.get("label")
    print(f"OK: {len(records)} records aligned and written -> {out}")


if __name__ == "__main__":
    main()