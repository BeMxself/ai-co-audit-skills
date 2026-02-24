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

if ! echo "$output" | grep -E -q "\\./\\.ai-workflows/.+/run"; then
  echo "expected run command hint in output, got:"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -E -q "\\./\\.ai-workflows/.+/continue"; then
  echo "expected continue command hint in output, got:"
  echo "$output"
  exit 1
fi
