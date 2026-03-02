#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_DIR="${SCRIPT_DIR}/.."

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "${tmp_dir}/automation/implementation-audit"
cp -R "${REF_DIR}/." "${tmp_dir}/automation/implementation-audit/"

mkdir -p "${tmp_dir}/docs"
echo "test" >"${tmp_dir}/docs/one.md"

set +e
output="$(
  cd "${tmp_dir}" && \
  bash "${tmp_dir}/automation/implementation-audit/init.sh" \
    --input docs/one.md \
    --reviewer kiro \
    --reviser codex \
    --kiro-agent custom-kiro-agent \
    --runner-cmd codex='echo custom-codex'
)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "init.sh failed unexpectedly"
  echo "$output"
  exit 1
fi

task_dir="$(echo "$output" | sed -n 's/.*Task initialized: //p' | head -n 1)"
if [[ -z "$task_dir" ]]; then
  echo "failed to parse task dir from output"
  echo "$output"
  exit 1
fi

config_file="${task_dir}/config/task.json"

reviewer="$(jq -r '.execution.reviewer' "$config_file")"
reviser="$(jq -r '.execution.reviser' "$config_file")"
codex_cmd="$(jq -r '.runners.codex.command // ""' "$config_file")"
kiro_agent="$(jq -r '.runners.kiro.agent // ""' "$config_file")"

if [[ "$reviewer" != "kiro" ]]; then
  echo "expected execution.reviewer=kiro, got: $reviewer"
  exit 1
fi

if [[ "$reviser" != "codex" ]]; then
  echo "expected execution.reviser=codex, got: $reviser"
  exit 1
fi

if [[ "$codex_cmd" != "echo custom-codex" ]]; then
  echo "expected codex custom command in runners, got: $codex_cmd"
  exit 1
fi

if [[ "$kiro_agent" != "custom-kiro-agent" ]]; then
  echo "expected kiro agent persisted, got: $kiro_agent"
  exit 1
fi
