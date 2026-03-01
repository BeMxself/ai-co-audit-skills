#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEFAULT_AGENT_NAME="ai-co-audit-kiro-opus"
DEFAULT_MODEL="claude-opus-4.6"
AGENT_NAME="${DEFAULT_AGENT_NAME}"
MODEL_NAME="${DEFAULT_MODEL}"
PROJECT_ROOT="${REPO_ROOT}"
FORCE=0

usage() {
  cat <<'USAGE'
Usage:
  automation/implementation-audit-kiro/setup-kiro-agent.sh [options]

Options:
  --project-root <dir>  Target project root (default: current workflow repo root)
  --agent-name <name>   Kiro agent profile name (default: ai-co-audit-kiro-opus)
  --model <model-id>    Kiro model id (default: claude-opus-4.6)
  --force               Overwrite existing agent file
  -h, --help            Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --agent-name)
      AGENT_NAME="$2"
      shift 2
      ;;
    --model)
      MODEL_NAME="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${AGENT_NAME}" ]]; then
  echo "--agent-name must not be empty" >&2
  exit 1
fi

if [[ -z "${MODEL_NAME}" ]]; then
  echo "--model must not be empty" >&2
  exit 1
fi

if [[ "${PROJECT_ROOT}" != /* ]]; then
  PROJECT_ROOT="$(cd "${PROJECT_ROOT}" && pwd)"
fi

AGENT_DIR="${PROJECT_ROOT}/.kiro/agents"
AGENT_FILE="${AGENT_DIR}/${AGENT_NAME}.json"

mkdir -p "${AGENT_DIR}"

if [[ -f "${AGENT_FILE}" && "${FORCE}" -ne 1 ]]; then
  echo "Agent file already exists: ${AGENT_FILE} (use --force to overwrite)" >&2
  exit 1
fi

cat >"${AGENT_FILE}" <<EOF
{
  "name": "${AGENT_NAME}",
  "description": "AI co-audit primary reviewer (Kiro CLI).",
  "prompt": "You are a pragmatic software engineering reviewer focused on precise, evidence-based implementation audits.",
  "model": "${MODEL_NAME}",
  "resources": [
    "skill://.kiro/skills/**/SKILL.md"
  ]
}
EOF

echo "Kiro agent written: ${AGENT_FILE}"
