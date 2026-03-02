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
  "taskName": "Dynamic Suffix Task",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1,
  "successMarker": "DONE",
  "execution": {
    "reviewer": "reviewerx",
    "reviser": "reviserx"
  },
  "runners": {
    "reviewerx": {
      "command": "cat >/dev/null; echo DONE"
    },
    "reviserx": {
      "command": "cat >/dev/null; echo revised-body"
    }
  }
}
JSON

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" 2>&1)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "run-implementation-audit.sh failed"
  echo "$output"
  exit 1
fi

if [[ ! -f "${task_dir}/reports/initial/test-report-reviserx.md" ]]; then
  echo "expected reviser initial report suffix file"
  exit 1
fi

if [[ ! -f "${task_dir}/reports/initial/test-report-reviewerx.md" ]]; then
  echo "expected reviewer initial report suffix file"
  exit 1
fi

if [[ ! -f "${task_dir}/reports/comparison/test-report-compare-by-reviserx.md" ]]; then
  echo "expected reviser compare report suffix file"
  exit 1
fi

if [[ ! -f "${task_dir}/reports/comparison/test-report-compare-by-reviewerx.md" ]]; then
  echo "expected reviewer compare report suffix file"
  exit 1
fi

if [[ ! -f "${task_dir}/reports/rounds/round-01-reviewerx-review.md" ]]; then
  echo "expected dynamic round reviewer output file"
  exit 1
fi

if ls "${task_dir}/reports/rounds"/round-01-*-revision.md >/dev/null 2>&1; then
  echo "round revision should not exist when reviewer already returned success marker"
  exit 1
fi
