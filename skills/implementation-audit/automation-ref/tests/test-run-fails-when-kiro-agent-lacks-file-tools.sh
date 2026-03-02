#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/../run-implementation-audit.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

task_dir="${tmp_dir}/task"
mkdir -p "${task_dir}/config" "${task_dir}/inputs"

cat >"${task_dir}/config/task.json" <<JSON
{
  "taskName": "Kiro Agent Permission Guard Test",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1,
  "successMarker": "ok",
  "workingDirectory": "${tmp_dir}",
  "execution": {
    "reviewer": "kiro",
    "reviser": "custom-reviser"
  },
  "runners": {
    "kiro": {
      "command": "",
      "agent": "ai-co-audit-kiro-opus"
    },
    "custom-reviser": {
      "command": "cat >/dev/null; echo revised-body"
    }
  }
}
JSON

mkdir -p "${tmp_dir}/.kiro/agents"
cat >"${tmp_dir}/.kiro/agents/ai-co-audit-kiro-opus.json" <<'JSON'
{
  "name": "ai-co-audit-kiro-opus",
  "tools": []
}
JSON

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/kiro-cli" <<EOF
#!/usr/bin/env bash
touch "${tmp_dir}/kiro.called"
echo "should-not-run"
EOF

chmod +x "${tmp_dir}/bin/kiro-cli"
export PATH="${tmp_dir}/bin:${PATH}"

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" 2>&1)"
rc=$?
set -e

if [[ "${rc}" -eq 0 ]]; then
  echo "expected run-implementation-audit.sh to fail when agent has no file tools"
  exit 1
fi

if [[ "${output}" != *"lacks file read/write tools"* ]]; then
  echo "expected explicit missing file tool error"
  echo "${output}"
  exit 1
fi

if [[ -f "${tmp_dir}/kiro.called" ]]; then
  echo "kiro-cli should not be invoked when agent precheck fails"
  exit 1
fi
