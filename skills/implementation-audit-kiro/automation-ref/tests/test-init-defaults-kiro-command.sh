#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOMATION_REF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

mkdir -p "${tmp_dir}/automation"
cp -R "${AUTOMATION_REF_DIR}" "${tmp_dir}/automation/implementation-audit-kiro"
mkdir -p "${tmp_dir}/docs"
cat >"${tmp_dir}/docs/design.md" <<'EOF_INPUT'
# Design
EOF_INPUT

pushd "${tmp_dir}" >/dev/null
bash automation/implementation-audit-kiro/init.sh \
  --task-id "kiro-default-command-test" \
  --input "docs/design.md" >/dev/null
popd >/dev/null

config_file="${tmp_dir}/.ai-workflows/kiro-default-command-test/config/task.json"
if [[ ! -f "${config_file}" ]]; then
  echo "expected task config file: ${config_file}"
  exit 1
fi

cmd="$(jq -r '.agents.claude.command // ""' "${config_file}")"

if [[ "${cmd}" != *"kiro-cli chat"* ]]; then
  echo "expected default claude command to use kiro-cli chat, got: ${cmd}"
  exit 1
fi

if [[ "${cmd}" != *"--no-interactive"* ]]; then
  echo "expected --no-interactive in default kiro command, got: ${cmd}"
  exit 1
fi

if [[ "${cmd}" != *"--trust-all-tools"* ]]; then
  echo "expected --trust-all-tools in default kiro command, got: ${cmd}"
  exit 1
fi

if [[ "${cmd}" != *"--agent"* ]]; then
  echo "expected --agent in default kiro command, got: ${cmd}"
  exit 1
fi
