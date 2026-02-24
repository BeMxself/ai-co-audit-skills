#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/../run-implementation-audit.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

task_dir="${tmp_dir}/task"
mkdir -p "${task_dir}/config"
mkdir -p "${task_dir}/inputs"

cat >"${task_dir}/config/task.json" <<'JSON'
{
  "taskName": "Test Task",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1,
  "successMarker": "ok"
}
JSON

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/claude" <<EOF
#!/usr/bin/env bash
count_file="${tmp_dir}/claude.count"
flag_file="${tmp_dir}/sequential.flag"
touch "${tmp_dir}/claude.started"
sleep 0.5
if [[ ! -f "${tmp_dir}/codex.started" ]]; then
  echo "claude-before-codex" >"\${flag_file}"
fi
count=0
if [[ -f "\${count_file}" ]]; then
  count="\$(cat "\${count_file}")"
fi
count=\$((count + 1))
echo "\${count}" >"\${count_file}"
if [[ "\${count}" -eq 1 ]]; then
  sleep 1
fi
echo "ok"
exit 0
EOF

cat >"${tmp_dir}/bin/codex" <<EOF
#!/usr/bin/env bash
count_file="${tmp_dir}/codex.count"
flag_file="${tmp_dir}/sequential.flag"
touch "${tmp_dir}/codex.started"
sleep 0.5
if [[ ! -f "${tmp_dir}/claude.started" ]]; then
  echo "codex-before-claude" >"\${flag_file}"
fi
count=0
if [[ -f "\${count_file}" ]]; then
  count="\$(cat "\${count_file}")"
fi
count=\$((count + 1))
echo "\${count}" >"\${count_file}"
if [[ "\${count}" -eq 1 ]]; then
  sleep 1
fi

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

chmod +x "${tmp_dir}/bin/claude" "${tmp_dir}/bin/codex"
export PATH="${tmp_dir}/bin:${PATH}"

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" 2>&1)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "run-implementation-audit.sh failed"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "Phase start: initial"; then
  echo "expected phase start log, got:"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "Round 01/1"; then
  echo "expected round progress log, got:"
  echo "$output"
  exit 1
fi

if [[ -f "${tmp_dir}/sequential.flag" ]]; then
  echo "expected initial analyses to run in parallel"
  cat "${tmp_dir}/sequential.flag"
  exit 1
fi
