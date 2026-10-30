#!/usr/bin/env bash
# Copyright © 2026 Zhejiang Runhe Cloud Intelligence Technology Co., Ltd
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${REPO_ROOT}"
export PYTHONPATH="${REPO_ROOT}:${PYTHONPATH:-}"


CASES=(
  'pytest -v tests/ci/test/ -k "not test_no_test_file_lives_outside_the_tests_tree"'
  'pytest -v tests/fast-gpu/test_det_process_group.py'
  'pytest -v tests/fast-gpu/test_quantizer_ci.py'
  'pytest -v tests/fast-gpu/test_run_megatron_worker_main.py'
  'pytest -v tests/fast-gpu/test_semaphore.py -k "not test_max_concurrent[no_limit]"'
  'pytest -v tests/test_attention_output_gate_tp.py'
  'pytest -v tests/test_chunked_gae.py'
  'pytest -v tests/test_fsdp_import.py'
  'pytest -v tests/fast/ --override-ini="addopts=" --continue-on-collection-errors'
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
