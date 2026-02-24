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
  bash "${tmp_dir}/automation/implementation-audit/init.sh" --input docs/one.md
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

timeout_val="$(jq -r '.timeoutSeconds' "${task_dir}/config/task.json")"
if [[ "$timeout_val" != "7200" ]]; then
  echo "expected default timeoutSeconds=7200, got: ${timeout_val}"
  exit 1
fi
