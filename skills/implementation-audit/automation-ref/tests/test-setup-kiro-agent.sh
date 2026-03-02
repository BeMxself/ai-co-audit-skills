#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/../setup-kiro-agent.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

bash "${SETUP_SCRIPT}" --project-root "${tmp_dir}" >/dev/null

agent_file="${tmp_dir}/.kiro/agents/ai-co-audit-kiro-opus.json"
if [[ ! -f "${agent_file}" ]]; then
  echo "expected agent file: ${agent_file}"
  exit 1
fi

agent_model="$(jq -r '.model // ""' "${agent_file}")"
agent_name="$(jq -r '.name // ""' "${agent_file}")"
agent_has_wildcard_tools="$(jq -r '(.tools // []) | index("*") != null' "${agent_file}")"

if [[ "${agent_model}" != "claude-opus-4.6" ]]; then
  echo "expected model claude-opus-4.6, got: ${agent_model}"
  exit 1
fi

if [[ "${agent_name}" != "ai-co-audit-kiro-opus" ]]; then
  echo "expected default agent name ai-co-audit-kiro-opus, got: ${agent_name}"
  exit 1
fi

if [[ "${agent_has_wildcard_tools}" != "true" ]]; then
  echo "expected setup script to grant wildcard tools"
  cat "${agent_file}"
  exit 1
fi
