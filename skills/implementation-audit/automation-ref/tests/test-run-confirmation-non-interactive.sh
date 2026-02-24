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
mkdir -p "${task_dir}/config" "${task_dir}/inputs"

cat >"${task_dir}/config/task.json" <<'JSON'
{
  "taskName": "Test Task",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1
}
JSON

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" --dry-run 2>&1)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "expected zero exit code in non-interactive mode"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "Plugin version: 1.1.1"; then
  echo "expected plugin version output"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "Non-interactive stdin detected. Auto-continue."; then
  echo "expected non-interactive auto-continue message"
  echo "$output"
  exit 1
fi

if [[ ! -f "${task_dir}/reports/merged/test-report.md" ]]; then
  echo "expected dry-run merged report output"
  exit 1
fi
