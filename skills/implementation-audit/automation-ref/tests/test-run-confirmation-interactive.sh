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
mkdir -p "${task_dir}/config" "${task_dir}/inputs"

cat >"${task_dir}/config/task.json" <<'JSON'
{
  "taskName": "Test Task",
  "objective": "Test objective",
  "inputs": ["docs/one.md"],
  "reportBaseName": "test-report",
  "maxRounds": 1
}
JSON

output_file="${tmp_dir}/interactive.out"
expect_file="${tmp_dir}/interactive.expect"
cat >"${expect_file}" <<'EXPECT'
set timeout 20
set run_script [lindex $argv 0]
set task_dir [lindex $argv 1]
log_file -noappend [lindex $argv 2]
spawn $run_script --task-dir $task_dir --dry-run
expect "Continue with implementation audit?"
send "n\r"
expect eof
catch wait result
set code [lindex $result 3]
exit $code
EXPECT

set +e
expect "${expect_file}" "${RUN_SCRIPT}" "${task_dir}" "${output_file}" >/dev/null 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "expected non-zero exit code when user declines confirmation"
  cat "$output_file"
  exit 1
fi

if ! grep -q "Plugin version: 1.1.1" "$output_file"; then
  echo "expected plugin version output"
  cat "$output_file"
  exit 1
fi

if ! grep -q "User cancelled run at confirmation step." "$output_file"; then
  echo "expected cancel message"
  cat "$output_file"
  exit 1
fi

if [[ -d "${task_dir}/reports" ]]; then
  echo "reports should not be generated after cancellation"
  exit 1
fi
