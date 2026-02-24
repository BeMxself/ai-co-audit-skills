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
args_file="${tmp_dir}/claude.args"

printf "test prompt\n" >"${prompt_file}"
mkdir -p "${tmp_dir}/bin"

cat >"${tmp_dir}/bin/claude" <<EOF
#!/usr/bin/env bash
printf "%s\n" "\$@" >"${args_file}"
prompt_payload="\$(cat)"
output_path="\$(printf "%s\n" "\$prompt_payload" | sed -n 's/^__OUTPUT_FILE_PATH__=//p' | tail -n 1)"
if [[ -n "\$output_path" ]]; then
  printf "ok\n" >"\$output_path"
fi
printf "OUTPUT_WRITTEN\n"
EOF
chmod +x "${tmp_dir}/bin/claude"

export PATH="${tmp_dir}/bin:${PATH}"
# shellcheck source=../lib/runner.sh
source "${RUNNER_SH}"

run_agent "claude" "${prompt_file}" "${output_file}" "${log_file}" "30" "${tmp_dir}" ""

if grep -Fxq -- "-c" "${args_file}"; then
  echo "claude command must be stateless; unexpected -c option found"
  cat "${args_file}"
  exit 1
fi

if ! grep -Fxq -- "-p" "${args_file}"; then
  echo "expected -p option in claude command"
  cat "${args_file}"
  exit 1
fi

if ! grep -Fxq -- "--dangerously-skip-permissions" "${args_file}"; then
  echo "expected --dangerously-skip-permissions option in claude command"
  cat "${args_file}"
  exit 1
fi

if grep -Fxq -- "--debug-file" "${args_file}"; then
  echo "expected --debug-file to be disabled by default"
  cat "${args_file}"
  exit 1
fi

if ! grep -Fxq -- "-" "${args_file}"; then
  echo "expected stdin marker '-' option in claude command"
  cat "${args_file}"
  exit 1
fi
