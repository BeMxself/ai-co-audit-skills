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
  "taskName": "Prompt Ref Task",
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
  echo "dry-run failed"
  echo "$output"
  exit 1
fi

compare_prompt="${task_dir}/prompts/02-compare.prompt.txt"
merge_prompt="${task_dir}/prompts/03-merge.prompt.txt"

if rg -n "DRY-RUN: no agent execution\\." "$compare_prompt" "$merge_prompt" >/dev/null 2>&1; then
  echo "prompts should reference files, not inline report content"
  exit 1
fi

if rg -n "【.*内容】" "$compare_prompt" "$merge_prompt" >/dev/null 2>&1; then
  echo "prompts should not include inline content sections"
  exit 1
fi

if ! rg -n "文件路径（相对工作目录）" "$compare_prompt" "$merge_prompt" >/dev/null 2>&1; then
  echo "prompts should contain file path references"
  exit 1
fi

if rg -n "^/.*reports/" "$compare_prompt" "$merge_prompt" >/dev/null 2>&1; then
  echo "prompts should use relative paths rather than absolute paths"
  exit 1
fi
