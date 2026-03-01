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
mkdir -p "${task_dir}/config"
mkdir -p "${task_dir}/inputs"

cat >"${task_dir}/config/task.json" <<'JSON'
{
  "taskName": "Kiro Default Command Test",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1,
  "successMarker": "ok"
}
JSON

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/kiro-cli" <<EOF
#!/usr/bin/env bash
touch "${tmp_dir}/kiro.called"
echo "ok"
EOF

cat >"${tmp_dir}/bin/codex" <<EOF
#!/usr/bin/env bash
out=""
prev=""
for arg in "\$@"; do
  if [[ "\${prev}" == "--output-last-message" ]]; then
    out="\${arg}"
    break
  fi
  prev="\${arg}"
done
if [[ -n "\${out}" ]]; then
  echo "ok" >"\${out}"
fi
exit 0
EOF

chmod +x "${tmp_dir}/bin/kiro-cli" "${tmp_dir}/bin/codex"
export PATH="${tmp_dir}/bin:${PATH}"

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" 2>&1)"
rc=$?
set -e

if [[ "${rc}" -ne 0 ]]; then
  echo "run-implementation-audit.sh failed"
  echo "${output}"
  exit 1
fi

if [[ ! -f "${tmp_dir}/kiro.called" ]]; then
  echo "expected kiro-cli to be invoked as default primary reviewer command"
  exit 1
fi

if echo "${output}" | grep -q "Missing required command: claude"; then
  echo "unexpected claude dependency detected in kiro workflow"
  echo "${output}"
  exit 1
fi
