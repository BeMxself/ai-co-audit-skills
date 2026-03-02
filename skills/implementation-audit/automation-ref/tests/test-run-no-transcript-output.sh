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
  "taskName": "No Transcript Task",
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

if [[ -e "${task_dir}/transcripts/implementation-audit-dialogue.md" ]]; then
  echo "transcript file should not be generated"
  exit 1
fi

if [[ -d "${task_dir}/transcripts" ]]; then
  echo "transcripts directory should not be generated"
  exit 1
fi
