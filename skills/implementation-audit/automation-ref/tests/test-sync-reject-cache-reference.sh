#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/../sync-automation.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

reference_dir="${tmp_dir}/.claude/plugins/cache/v1/implementation-audit"
target_dir="${tmp_dir}/automation/implementation-audit"
mkdir -p "${reference_dir}" "${target_dir}"

set +e
output="$(
  (
    export HOME="${tmp_dir}"
    cd "${tmp_dir}"
    "${SYNC_SCRIPT}" "${reference_dir}" "${target_dir}" 2>&1
  )
)"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "expected non-zero exit code for cache reference dir"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "Could not resolve a non-cache source directory"; then
  echo "expected non-cache resolution failure message"
  echo "$output"
  exit 1
fi
