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
  "taskName": "Initial Prompt Profile Task",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1,
  "execution": {
    "reviewer": "reviewer-agent",
    "reviser": "reviser-agent"
  },
  "promptProfiles": {
    "initial": {
      "reviewer": "strict",
      "reviser": "balanced"
    }
  },
  "runners": {
    "reviewer-agent": { "command": "" },
    "reviser-agent": { "command": "" }
  }
}
JSON

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" --dry-run 2>&1)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "dry-run failed unexpectedly"
  echo "$output"
  exit 1
fi

reviewer_prompt="${task_dir}/prompts/01-initial-reviewer-agent.prompt.txt"
reviser_prompt="${task_dir}/prompts/01-initial-reviser-agent.prompt.txt"

if [[ ! -f "$reviewer_prompt" || ! -f "$reviser_prompt" ]]; then
  echo "expected role-specific initial prompt files"
  exit 1
fi

if ! rg -n "重点审查以下内容" "$reviewer_prompt" >/dev/null 2>&1; then
  echo "expected strict reviewer initial prompt"
  exit 1
fi

if ! rg -n "被过度乐观判定为“已完成/已满足”的地方" "$reviewer_prompt" >/dev/null 2>&1; then
  echo "expected strict reviewer prompt to challenge overclaimed completion"
  exit 1
fi

if ! rg -n "先自行理解输入材料中的关键要求" "$reviser_prompt" >/dev/null 2>&1; then
  echo "expected balanced reviser initial prompt"
  exit 1
fi

if ! rg -n "新增观察、新增风险或衍生问题" "$reviser_prompt" >/dev/null 2>&1; then
  echo "expected balanced reviser prompt to distinguish new observations"
  exit 1
fi
