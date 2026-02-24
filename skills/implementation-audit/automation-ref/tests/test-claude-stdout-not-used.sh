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

printf "test prompt\n" >"${prompt_file}"
mkdir -p "${tmp_dir}/bin"

cat >"${tmp_dir}/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "stdout-report-body"
EOF
chmod +x "${tmp_dir}/bin/claude"

export PATH="${tmp_dir}/bin:${PATH}"
# shellcheck source=../lib/runner.sh
source "${RUNNER_SH}"

set +e
run_agent "claude" "${prompt_file}" "${output_file}" "${log_file}" "30" "${tmp_dir}" "" 2>/dev/null
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "expected failure when claude only writes stdout"
  exit 1
fi

if [[ -f "${output_file}" ]]; then
  echo "output file should not be generated from stdout"
  cat "${output_file}"
  exit 1
fi
