#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/../run-implementation-audit.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  local runner_pid="$1"
  if [[ -n "${runner_pid}" ]] && kill -0 "${runner_pid}" 2>/dev/null; then
    kill -KILL "${runner_pid}" 2>/dev/null || true
  fi
  if [[ -f "${tmp_dir}/claude.pid" ]]; then
    pid="$(cat "${tmp_dir}/claude.pid" || true)"
    [[ -n "${pid:-}" ]] && kill -KILL "${pid}" 2>/dev/null || true
  fi
  if [[ -f "${tmp_dir}/codex.pid" ]]; then
    pid="$(cat "${tmp_dir}/codex.pid" || true)"
    [[ -n "${pid:-}" ]] && kill -KILL "${pid}" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
}

task_dir="${tmp_dir}/task"
mkdir -p "${task_dir}/config" "${task_dir}/inputs"

cat >"${task_dir}/config/task.json" <<'JSON'
{
  "taskName": "Interrupt Task",
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
echo \$\$ >"${tmp_dir}/claude.pid"
trap '' INT
trap '' TERM
sleep 60
prompt_payload="\$(cat)"
output_path="\$(printf "%s\n" "\$prompt_payload" | sed -n 's/^__OUTPUT_FILE_PATH__=//p' | tail -n 1)"
if [[ -n "\$output_path" ]]; then
  echo "ok" >"\$output_path"
fi
echo "OUTPUT_WRITTEN"
EOF

cat >"${tmp_dir}/bin/codex" <<EOF
#!/usr/bin/env bash
echo \$\$ >"${tmp_dir}/codex.pid"
trap '' INT
trap '' TERM
sleep 60
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
EOF

chmod +x "${tmp_dir}/bin/claude" "${tmp_dir}/bin/codex"
export PATH="${tmp_dir}/bin:${PATH}"

run_log="${tmp_dir}/run.log"
"${RUN_SCRIPT}" --task-dir "${task_dir}" >"${run_log}" 2>&1 &
runner_pid=$!
trap 'cleanup "$runner_pid"' EXIT

sleep 1
for _ in {1..40}; do
  if [[ -f "${tmp_dir}/claude.pid" && -f "${tmp_dir}/codex.pid" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -f "${tmp_dir}/claude.pid" || ! -f "${tmp_dir}/codex.pid" ]]; then
  echo "expected test agent pid files before interrupt"
  cat "${run_log}"
  exit 1
fi

# SIGTERM is used in test mode because background processes ignore SIGINT by default.
kill -TERM "${runner_pid}"

set +e
wait "${runner_pid}"
runner_rc=$?
set -e

if [[ "${runner_rc}" -eq 0 ]]; then
  echo "expected non-zero exit code after interrupt"
  cat "${run_log}"
  exit 1
fi

if [[ "${runner_rc}" -ne 130 ]]; then
  echo "expected interrupt exit code 130, got ${runner_rc}"
  cat "${run_log}"
  exit 1
fi

claude_pid="$(cat "${tmp_dir}/claude.pid")"
codex_pid="$(cat "${tmp_dir}/codex.pid")"

sleep 0.5
if kill -0 "${claude_pid}" 2>/dev/null; then
  echo "claude agent process still alive after interrupt: ${claude_pid}"
  cat "${run_log}"
  exit 1
fi

if kill -0 "${codex_pid}" 2>/dev/null; then
  echo "codex agent process still alive after interrupt: ${codex_pid}"
  cat "${run_log}"
  exit 1
fi
