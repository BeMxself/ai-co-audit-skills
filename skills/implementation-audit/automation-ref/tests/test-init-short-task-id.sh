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
echo "test" >"${tmp_dir}/docs/2026-02-21-design-consistency-audit.md"

set +e
output="$(
  cd "${tmp_dir}" && \
  bash "${tmp_dir}/automation/implementation-audit/init.sh" \
    --input docs/2026-02-21-design-consistency-audit.md \
    --no-claude-meta
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

task_id="$(basename "$task_dir")"
expected_task_id="$(date '+%Y%m%d')-design-consistency-audit"

if [[ "$task_id" != "$expected_task_id" ]]; then
  echo "expected concise task id ${expected_task_id}, got: ${task_id}"
  exit 1
fi
