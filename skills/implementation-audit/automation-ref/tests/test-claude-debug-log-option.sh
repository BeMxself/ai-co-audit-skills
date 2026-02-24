#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_SH="${SCRIPT_DIR}/../lib/runner.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

prompt_file="${tmp_dir}/prompt.txt"
output_file="${tmp_dir}/report.md"
log_file="${tmp_dir}/claude.log"
debug_log_file="${log_file}.debug"
args_file="${tmp_dir}/claude.args"

printf "test prompt\n" >"${prompt_file}"
mkdir -p "${tmp_dir}/bin"

cat >"${tmp_dir}/bin/claude" <<'EOF'
#!/usr/bin/env bash
args_file="$CLAUDE_ARGS_FILE"
printf "%s\n" "$@" >"$args_file"

debug_file=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--debug-file" ]]; then
    debug_file="$arg"
    break
  fi
  prev="$arg"
done

if [[ -n "$debug_file" ]]; then
  echo "debug-log-enabled" >"$debug_file"
fi

prompt_payload="$(cat)"
output_path="$(printf "%s\n" "$prompt_payload" | sed -n 's/^__OUTPUT_FILE_PATH__=//p' | tail -n 1)"
if [[ -n "$output_path" ]]; then
  echo "report-body" >"$output_path"
fi
echo "stderr-log-line" >&2
echo "OUTPUT_WRITTEN"
EOF
chmod +x "${tmp_dir}/bin/claude"

export CLAUDE_ARGS_FILE="${args_file}"
export IMPLEMENTATION_AUDIT_CLAUDE_DEBUG=1
export PATH="${tmp_dir}/bin:${PATH}"
# shellcheck source=../lib/runner.sh
source "${RUNNER_SH}"

run_agent "claude" "${prompt_file}" "${output_file}" "${log_file}" "30" "${tmp_dir}" ""

if ! grep -Fxq -- "--debug-file" "${args_file}"; then
  echo "expected --debug-file option in claude command"
  cat "${args_file}"
  exit 1
fi

if ! grep -Fxq -- "${debug_log_file}" "${args_file}"; then
  echo "expected log file path passed to --debug-file"
  cat "${args_file}"
  exit 1
fi

if ! grep -q "debug-log-enabled" "${debug_log_file}"; then
  echo "expected debug-file output in log file"
  cat "${debug_log_file}"
  exit 1
fi

if ! grep -q "stderr-log-line" "${log_file}"; then
  echo "expected stderr output appended to log file"
  cat "${log_file}"
  exit 1
fi

if ! grep -q "report-body" "${output_file}"; then
  echo "expected report output file content"
  cat "${output_file}"
  exit 1
fi
