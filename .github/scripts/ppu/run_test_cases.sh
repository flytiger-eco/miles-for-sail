#!/usr/bin/env bash
# Copyright © 2026 Zhejiang Runhe Cloud Intelligence Technology Co., Ltd
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${REPO_ROOT}"
export PYTHONPATH="${REPO_ROOT}:${PYTHONPATH:-}"


# Per-case wall-clock guards: a hung case previously blocked the whole
# job until the pod timeout killed it (observed: test_semaphore.py hangs
# indefinitely on the v0.1.2 image while it passed on the v0.1.0 image).
# timeout returns 124 on expiry, which run_case records as FAIL.
#
# tests/fast-gpu/test_semaphore.py is not in the set: upstream marks the
# whole file disabled ("FIXME: re-enable after shared HTTP client
# concurrency is reset between cases"), and its remaining selected case
# (test_max_concurrent[limit_1]) hangs on the v0.1.2 image. Re-enable it
# in both suites after triage.
CASES=(
  'timeout 1800 pytest -v tests/ci/test/ -k "not test_no_test_file_lives_outside_the_tests_tree"'
  'timeout 1800 pytest -v tests/fast-gpu/test_det_process_group.py'
  'timeout 1800 pytest -v tests/fast-gpu/test_quantizer_ci.py'
  'timeout 1800 pytest -v tests/fast-gpu/test_run_megatron_worker_main.py'
  'timeout 1800 pytest -v tests/test_attention_output_gate_tp.py'
  'timeout 1800 pytest -v tests/test_chunked_gae.py'
  'timeout 1800 pytest -v tests/test_fsdp_import.py'
  'timeout 3600 pytest -v tests/fast/ --override-ini="addopts=" --continue-on-collection-errors'
)

# ---------------------------------------------------------------------------
# execution
# ---------------------------------------------------------------------------
log()    { printf '[ppu-ci] %s\n' "$*"; }
banner() { printf '\n==== %s ====\n' "$*"; }

run_case() {
  banner "$1"
  eval "$1"
}

main() {
  log "repo root = ${REPO_ROOT}"
  log "python    = $(python --version 2>&1)"

  local cmd failed=()
  for cmd in "${CASES[@]}"; do
    if run_case "${cmd}"; then
      log "PASS: ${cmd}"
    else
      log "FAIL: ${cmd}"
      failed+=("${cmd}")
    fi
  done

  banner "summary"
  ((${#failed[@]} == 0)) || { printf '  - %s\n' "${failed[@]}"; return 1; }
  log "all ${#CASES[@]} cases passed"
}

main "$@"
