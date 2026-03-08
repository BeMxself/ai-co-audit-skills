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
  "taskName": "Prompt Convergence Task",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1,
  "execution": {
    "reviewer": "reviewer-agent",
    "reviser": "reviser-agent"
  },
  "runners": {
    "reviewer-agent": {
      "command": "cat >/dev/null; printf '%s\n' '问题清单（按严重级）' '- 阻断：示例问题，需一次性收敛'"
    },
    "reviser-agent": {
      "command": "cat >/dev/null; printf '%s\n' '# Revised Report' '' 'Body'"
    }
  }
}
JSON

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" 2>&1)"
rc=$?
set -e

if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
  echo "run failed unexpectedly"
  echo "$output"
  exit 1
fi

merge_prompt="${task_dir}/prompts/03-merge.prompt.txt"
reviewer_prompt="${task_dir}/prompts/04-round-01-reviewer-agent-review.prompt.txt"
reviser_prompt="${task_dir}/prompts/05-round-01-reviser-agent-revise.prompt.txt"

for f in "$merge_prompt" "$reviewer_prompt" "$reviser_prompt"; do
  if [[ ! -f "$f" ]]; then
    echo "missing prompt file: $f"
    exit 1
  fi
done

if ! rg -n "摘要中的各状态数量之和必须与基准项总数一致" "$merge_prompt" >/dev/null 2>&1; then
  echo "merge prompt should require summary/count self-check"
  exit 1
fi

if ! rg -n "尽量一次性列出所有" "$reviewer_prompt" >/dev/null 2>&1; then
  echo "reviewer prompt should require batch issue surfacing"
  exit 1
fi

if ! rg -n "同一根因或同一类型的问题请合并成一条" "$reviewer_prompt" >/dev/null 2>&1; then
  echo "reviewer prompt should require merging same-root-cause issues"
  exit 1
fi

if ! rg -n "同一根因、同一口径、同一类措辞/统计/证据问题，必须全报告批量修正" "$reviser_prompt" >/dev/null 2>&1; then
  echo "reviser prompt should require batch fixes across the whole report"
  exit 1
fi

if ! rg -n "修完后必须做一轮自检" "$reviser_prompt" >/dev/null 2>&1; then
  echo "reviser prompt should require post-revision self-check"
  exit 1
fi
