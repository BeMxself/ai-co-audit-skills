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
  "maxRounds": 1
}
JSON

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "审查报告已写入 docs/plans/2026-02-23-security-external-auth-implementation-audit-auto.md"
exit 0
EOF
cat >"${tmp_dir}/bin/codex" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--output-last-message" ]]; then
    out="$arg"
    break
  fi
  prev="$arg"
done
if [[ -n "$out" ]]; then
  echo "ok" >"$out"
fi
exit 0
EOF
chmod +x "${tmp_dir}/bin/claude" "${tmp_dir}/bin/codex"

export PATH="${tmp_dir}/bin:${PATH}"

set +e
output="$("${RUN_SCRIPT}" --task-dir "${task_dir}" 2>&1)"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "expected non-zero exit code"
  exit 1
fi

if ! echo "$output" | grep -q "invalid agent output"; then
  echo "expected invalid agent output error, got:"
  echo "$output"
  exit 1
fi
