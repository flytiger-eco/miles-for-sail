import base64
import io
import json
import os
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest
import yaml
from tests.ci.ci_register import register_cpu_ci

register_cpu_ci(est_time=2, suite="stage-a-cpu", labels=[])

ROOT = Path(__file__).resolve().parents[3]
BUILD = yaml.safe_load((ROOT / ".github/workflows/ppu-docker-build.yml").read_text())["jobs"]["build"]["steps"]
TEST = yaml.safe_load((ROOT / ".github/workflows/ppu-linux-810-test.yml").read_text())["jobs"]["test"]["steps"]
REPOSITORY = "flytiger-eco/miles-for-sail"
IMAGE = f"ghcr.io/{REPOSITORY}@sha256:{'a' * 64}"
ENV = {
    "EVENT_NAME": "push",
    "EVENT_SHA": "b" * 40,
    "REF_NAME": "v0.1.3",
    "BASE_REPO": REPOSITORY,
}
PR_ENV = {
    **ENV,
    "EVENT_NAME": "pull_request",
    "PR_HEAD_SHA": "b" * 40,
    "PR_HEAD_REF": "feature",
    "PR_HEAD_REPO": REPOSITORY,
    "PR_NUMBER": "31",
    "BASE_REF": "v0.1.3",
}
HARNESS = r"""
const fs = require('node:fs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const result = { outputs: {}, errors: [], waits: [], artifactReads: [], queries: [] };
const actions = {
  listWorkflowRuns: 'runs',
  listWorkflowRunArtifacts: 'artifacts',
  downloadArtifact: async ({artifact_id}) => ({
    data: Buffer.from(Object.values(input.artifacts).flat().find(a => a.id === artifact_id).archive, 'base64'),
  }),
  getWorkflowRun: async () => ({data: input.polled.shift()}),
};
const paginate = async (method, params) => {
  if (method === 'artifacts') {
    result.artifactReads.push(params.run_id);
    return input.artifacts[params.run_id] || [];
  }
  result.queries.push(params);
  return input.direct.filter(r => r.event === params.event && r.head_sha === params.head_sha);
};
paginate.iterator = async function* (method, params) {
  result.queries.push(params);
  for (const page of input.branches[params.branch] || []) {
    yield {data: page.filter(r => r.status === 'completed' && r.conclusion === 'success')};
  }
};
const core = {
  setOutput: (name, value) => result.outputs[name] = value,
  setFailed: message => result.errors.push(message),
  info: () => {},
};
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
const script = new AsyncFunction('github', 'context', 'core', 'require', 'process', 'setTimeout', input.script);
script({rest: {actions}, paginate}, {repo: {owner: 'flytiger-eco', repo: 'miles-for-sail'}},
  core, require, {env: input.env}, (callback, ms) => {result.waits.push(ms); callback();})
  .catch(error => result.errors.push(error.message))
  .then(() => console.log(JSON.stringify(result)));
"""


def _step(steps, step_id):
    return next(step for step in steps if step.get("id") == step_id)


def _execute(step, *, env=ENV, direct=(), branches=None, artifacts=None, polled=()):
    node = shutil.which("node")
    if not node:
        pytest.skip("Node.js is required to execute the embedded github-script")
    result = subprocess.run(
        [node, "-e", HARNESS],
        input=json.dumps(
            dict(
                script=step["with"]["script"],
                env=env,
                direct=direct,
                branches=branches or {},
                artifacts=artifacts or {},
                polled=list(polled),
            )
        ),
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def _run(run_id, *, event="push", branch="v0.1.3", repository=REPOSITORY, pr=31, **overrides):
    return dict(
        id=run_id,
        event=event,
        head_branch=branch,
        head_repository={"full_name": repository},
        pull_requests=[{"number": pr}] if event == "pull_request" else [],
        **(dict(head_sha=ENV["EVENT_SHA"], run_attempt=1, status="completed", conclusion="success") | overrides),
    )


def _artifact(artifact_id, *, published=True, image=IMAGE, attempt=1, expired=False):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("ppu-image-publication.json", json.dumps(dict(published=published, image=image)))
    return dict(
        id=artifact_id,
        name=f"ppu-image-publication-{attempt}",
        expired=expired,
        archive=base64.b64encode(buffer.getvalue()).decode(),
    )


@pytest.mark.parametrize("exists", [False, True])
def test_dockerfile_probe_precedes_and_guards_image_resolution(tmp_path, exists):
    ids = [step.get("id") for step in TEST]
    assert ids.index("checkout") < ids.index("has_dockerfile") < ids.index("image")
    assert _step(TEST, "image")["if"] == TEST[-1]["if"] == "${{ steps.has_dockerfile.outputs.exists == 'true' }}"
    if exists:
        (tmp_path / "docker").mkdir()
        (tmp_path / "docker/Dockerfile.ppu").touch()
    output, summary = tmp_path / "output", tmp_path / "summary"
    subprocess.run(
        ["bash", "-e", "-c", _step(TEST, "has_dockerfile")["run"]],
        cwd=tmp_path,
        env={**os.environ, "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)},
        check=True,
    )
    assert output.read_text() == f"exists={str(exists).lower()}\n"
    if not exists:
        assert "no tests were run" in summary.read_text()


@pytest.mark.parametrize("published", [False, True])
@pytest.mark.parametrize(
    "tag", ["ghcr.io/flytiger-eco/miles-for-sail:miles-v0.1.3", "registry.example:5000/custom:tag"]
)
def test_publication_records_actual_repository_and_digest(tmp_path, published, tag):
    result = _execute(
        _step(BUILD, "publication"),
        env={
            "RUNNER_TEMP": str(tmp_path),
            "PUBLISHED": str(published).lower(),
            "IMAGE_TAG": tag,
            "IMAGE_DIGEST": f"sha256:{'a' * 64}" if published else "",
        },
    )
    assert not result["errors"]
    metadata = json.loads((tmp_path / "ppu-image-publication.json").read_text())
    assert metadata == dict(
        published=published, image=f"{tag.rsplit(':', 1)[0]}@sha256:{'a' * 64}" if published else None
    )
    upload = next(step for step in BUILD if step.get("uses") == "actions/upload-artifact@v4")
    assert upload["with"]["name"] == "ppu-image-publication-${{ github.run_attempt }}"
    assert upload["with"]["path"] == "${{ runner.temp }}/ppu-image-publication.json"
    assert _step(BUILD, "publication")["env"]["IMAGE_DIGEST"] == "${{ steps.build.outputs.digest }}"


@pytest.mark.parametrize("env", [ENV, {**ENV, "EVENT_NAME": "workflow_dispatch"}, PR_ENV])
def test_current_build_uses_published_digest_including_custom_images(env):
    image = f"registry.example:5000/custom@sha256:{'c' * 64}"
    result = _execute(
        _step(TEST, "image"),
        env=env,
        direct=[_run(1, event=env["EVENT_NAME"], branch=env.get("PR_HEAD_REF", env["REF_NAME"]))],
        artifacts={1: [_artifact(1, image=image)]},
    )
    assert result["outputs"] == {"image": image}
    assert not result["errors"]
    assert not result["waits"]
    assert all(query["workflow_id"] == "ppu-docker-build.yml" for query in result["queries"])


@pytest.mark.parametrize("metadata", [[], [_artifact(1, published=False)], [_artifact(1, expired=True)]])
def test_unpublished_dispatch_falls_back_to_older_published_build(metadata):
    current = _run(1, event="workflow_dispatch")
    result = _execute(
        _step(TEST, "image"),
        env={**ENV, "EVENT_NAME": "workflow_dispatch"},
        direct=[current],
        branches={"v0.1.3": [[current, _run(2)]]},
        artifacts={1: metadata, 2: [_artifact(2)]},
    )
    assert result["outputs"] == {"image": IMAGE}
    assert not result["errors"]
    assert result["artifactReads"] == [1, 2]


@pytest.mark.parametrize("env", [ENV, {**PR_ENV, "PR_HEAD_REPO": "contributor/miles-for-sail"}])
def test_branch_fallback_rejects_pr_and_fork_builds_and_paginates(env):
    result = _execute(
        _step(TEST, "image"),
        env=env,
        branches={
            "v0.1.3": [
                [_run(1, event="pull_request"), _run(2, repository="contributor/miles-for-sail")],
                [_run(3, event="workflow_dispatch"), _run(4)],
            ]
        },
        artifacts={3: [_artifact(3, published=False)], 4: [_artifact(4)]},
    )
    assert result["outputs"] == {"image": IMAGE}
    assert not result["errors"]
    assert result["artifactReads"] == [3, 4]
    if env["EVENT_NAME"] == "pull_request":
        assert not result["waits"]


@pytest.mark.parametrize("current", [False, True])
def test_same_repository_pr_filters_other_prs_and_forks(current):
    runs = [
        _run(1, event="pull_request", branch="feature", pr=99),
        _run(2, event="pull_request", branch="feature", repository="contributor/miles-for-sail"),
        _run(3, event="pull_request", branch="feature"),
    ]
    result = _execute(
        _step(TEST, "image"),
        env=PR_ENV,
        direct=runs if current else [],
        branches={"feature": [runs]},
        artifacts={3: [_artifact(3)]},
    )
    assert result["outputs"] == {"image": IMAGE}
    assert not result["errors"]
    assert result["artifactReads"] == [3]


def test_pr_without_published_pr_image_can_use_base_branch():
    result = _execute(
        _step(TEST, "image"), env=PR_ENV, branches={"v0.1.3": [[_run(1)]]}, artifacts={1: [_artifact(1)]}
    )
    assert result["outputs"] == {"image": IMAGE}
    assert not result["errors"]


def test_rerun_does_not_reuse_previous_attempt_publication():
    result = _execute(
        _step(TEST, "image"),
        direct=[_run(1, run_attempt=2)],
        artifacts={1: [_artifact(1, attempt=1), _artifact(2, attempt=2, published=False)]},
    )
    assert result["outputs"] == {}
    assert "no compatible published image" in result["errors"][0]


@pytest.mark.parametrize("image", ["ghcr.io/flytiger-eco/miles-for-sail:miles-v0.1.3", "bad\nreference", None])
def test_rejects_invalid_or_mutable_published_references(image):
    result = _execute(_step(TEST, "image"), direct=[_run(1)], artifacts={1: [_artifact(1, image=image)]})
    assert result["outputs"] == {}
    assert "invalid published image reference" in result["errors"][0]


@pytest.mark.parametrize("conclusion", ["success", "failure", "cancelled"])
def test_waits_for_current_build_and_never_masks_failure(conclusion):
    result = _execute(
        _step(TEST, "image"),
        direct=[_run(1, status="in_progress", conclusion=None)],
        polled=[_run(1, conclusion=conclusion)],
        artifacts={1: [_artifact(1)]},
        branches={"v0.1.3": [[_run(2)]]},
    )
    assert result["waits"] == [60000]
    assert result["outputs"] == ({"image": IMAGE} if conclusion == "success" else {})
    assert bool(result["errors"]) == (conclusion != "success")


def test_missing_publication_fails_instead_of_using_rolling_tag():
    result = _execute(_step(TEST, "image"))
    assert result["outputs"] == {}
    assert "no compatible published image" in result["errors"][0]


def test_missing_commit_context_fails_without_waiting():
    result = _execute(_step(TEST, "image"), env={**ENV, "EVENT_SHA": ""})
    assert result["outputs"] == {}
    assert "missing commit context" in result["errors"][0]
    assert not result["waits"]
