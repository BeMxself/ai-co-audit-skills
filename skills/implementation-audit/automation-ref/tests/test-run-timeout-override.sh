#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/../run-implementation-audit.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

task_dir="${tmp_dir}/task"
mkdir -p "${task_dir}/config"
mkdir -p "${task_dir}/inputs"

cat >"${task_dir}/config/task.json" <<'JSON'
{
  "taskName": "Test Task",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1,
  "timeoutSeconds": 3600
}
JSON

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" --dry-run --timeout-seconds 7200 2>&1)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "run-implementation-audit.sh failed"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "Timeout seconds: 7200"; then
  echo "expected timeout override log, got:"
  echo "$output"
  exit 1
fi
