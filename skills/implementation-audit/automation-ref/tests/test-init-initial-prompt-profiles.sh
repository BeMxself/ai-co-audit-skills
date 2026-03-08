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
output_default="$(
  cd "${tmp_dir}" && \
  bash "${tmp_dir}/automation/implementation-audit/init.sh" \
    --input docs/one.md \
    --no-claude-meta
)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "default init.sh failed unexpectedly"
  echo "$output_default"
  exit 1
fi

default_task_dir="$(echo "$output_default" | sed -n 's/.*Task initialized: //p' | head -n 1)"
default_config="${default_task_dir}/config/task.json"

default_reviewer_profile="$(jq -r '.promptProfiles.initial.reviewer // ""' "$default_config")"
default_reviser_profile="$(jq -r '.promptProfiles.initial.reviser // ""' "$default_config")"

if [[ "$default_reviewer_profile" != "strict" ]]; then
  echo "expected default initial reviewer prompt profile strict, got: $default_reviewer_profile"
  exit 1
fi

if [[ "$default_reviser_profile" != "balanced" ]]; then
  echo "expected default initial reviser prompt profile balanced, got: $default_reviser_profile"
  exit 1
fi

set +e
output_marked="$(
  cd "${tmp_dir}" && \
  bash "${tmp_dir}/automation/implementation-audit/init.sh" \
    --input docs/one.md \
    --no-claude-meta \
    --task-id profile-marker-test \
    --prompt '[initial-reviewer-prompt=balanced] [initial-reviser-prompt=strict] 请做初版实现一致性会审'
)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "marked init.sh failed unexpectedly"
  echo "$output_marked"
  exit 1
fi

marked_task_dir="$(echo "$output_marked" | sed -n 's/.*Task initialized: //p' | head -n 1)"
marked_config="${marked_task_dir}/config/task.json"

marked_reviewer_profile="$(jq -r '.promptProfiles.initial.reviewer // ""' "$marked_config")"
marked_reviser_profile="$(jq -r '.promptProfiles.initial.reviser // ""' "$marked_config")"

if [[ "$marked_reviewer_profile" != "balanced" ]]; then
  echo "expected marker-driven initial reviewer prompt profile balanced, got: $marked_reviewer_profile"
  exit 1
fi

if [[ "$marked_reviser_profile" != "strict" ]]; then
  echo "expected marker-driven initial reviser prompt profile strict, got: $marked_reviser_profile"
  exit 1
fi
