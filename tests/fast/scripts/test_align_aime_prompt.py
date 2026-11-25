import json
import sys

import pytest

from scripts.tools.align_aime_prompt import main

PREFIX = "Solve carefully.\n\n"
SUFFIX = "\n\nBox the answer."


@pytest.fixture
def datasets(tmp_path):
    train = tmp_path / "train.jsonl"
    test = tmp_path / "test.jsonl"
    train_records = [
        {"prompt": [{"role": "user", "content": f"{PREFIX}{question}{SUFFIX}"}], "label": "42"}
        for question in ("Alpha?", "Beta!")
    ]
    test_records = [
        {"prompt": [{"role": "user", "content": "What is six times seven?"}], "label": "42"},
        {"prompt": [{"role": "user", "content": f"{PREFIX}Already aligned.{SUFFIX}"}], "label": 7},
    ]
    train.write_text("".join(json.dumps(record) + "\n" for record in train_records), encoding="utf-8")
    test.write_text("".join(json.dumps(record) + "\n" for record in test_records), encoding="utf-8")
    return train, test


@pytest.mark.parametrize("input_name", ["train", "test"])
@pytest.mark.parametrize("alias", ["direct", "relative", "symlink", "hardlink", "symlink_parent"])
def test_rejects_output_aliasing_input(datasets, tmp_path, monkeypatch, capsys, input_name, alias):
    train, test = datasets
    before = (train.read_bytes(), test.read_bytes())
    source = train if input_name == "train" else test
    out = tmp_path / "out.jsonl"
    if alias == "direct":
        out = source
    elif alias == "relative":
        monkeypatch.chdir(tmp_path)
        out = source.relative_to(tmp_path)
    elif alias == "symlink":
        out.symlink_to(source)
    elif alias == "hardlink":
        out.hardlink_to(source)
    else:
        directory = tmp_path / "alias"
        directory.symlink_to(tmp_path, target_is_directory=True)
        out = directory / source.name
    monkeypatch.setattr(
        sys, "argv", ["align_aime_prompt.py", "--train", str(train), "--test", str(test), "--out", str(out)]
    )

    with pytest.raises(SystemExit) as exc:
        main()

    assert exc.value.code == 2
    assert "output path must not overwrite input file" in capsys.readouterr().err
    assert (train.read_bytes(), test.read_bytes()) == before


@pytest.mark.parametrize("input_name", ["train", "test"])
@pytest.mark.parametrize("alias", ["symlink", "hardlink"])
def test_rejects_default_output_aliasing_input(datasets, monkeypatch, input_name, alias):
    train, test = datasets
    before = (train.read_bytes(), test.read_bytes())
    source = train if input_name == "train" else test
    out = test.with_name("test-aligned.jsonl")
    if alias == "symlink":
        out.symlink_to(source)
    else:
        out.hardlink_to(source)
    monkeypatch.setattr(sys, "argv", ["align_aime_prompt.py", "--train", str(train), "--test", str(test)])

    with pytest.raises(SystemExit) as exc:
        main()

    assert exc.value.code == 2
    assert (train.read_bytes(), test.read_bytes()) == before


def test_rejects_default_output_equal_to_training_file(datasets, monkeypatch):
    train, test = datasets
    train = train.rename(test.with_name("test-aligned.jsonl"))
    before = (train.read_bytes(), test.read_bytes())
    monkeypatch.setattr(sys, "argv", ["align_aime_prompt.py", "--train", str(train), "--test", str(test)])

    with pytest.raises(SystemExit) as exc:
        main()

    assert exc.value.code == 2
    assert (train.read_bytes(), test.read_bytes()) == before


@pytest.mark.parametrize("output_mode", ["default", "explicit", "existing"])
def test_alignment_preserves_inputs_and_labels(datasets, monkeypatch, output_mode):
    train, test = datasets
    before = (train.read_bytes(), test.read_bytes())
    argv = ["align_aime_prompt.py", "--train", str(train), "--test", str(test)]
    out = test.with_name("test-aligned.jsonl")
    if output_mode != "default":
        out = test.with_name("out.jsonl")
        argv.extend(["--out", str(out)])
    if output_mode == "existing":
        out.write_text("old output", encoding="utf-8")
    monkeypatch.setattr(sys, "argv", argv)

    main()
    first_output = out.read_bytes()
    main()

    assert out.read_bytes() == first_output
    records = [json.loads(line) for line in out.read_text(encoding="utf-8").splitlines()]
    assert [record["label"] for record in records] == ["42", 7]
    assert [record["prompt"][0]["content"] for record in records] == [
        f"{PREFIX}What is six times seven?{SUFFIX}",
        f"{PREFIX}Already aligned.{SUFFIX}",
    ]
    assert (train.read_bytes(), test.read_bytes()) == before
