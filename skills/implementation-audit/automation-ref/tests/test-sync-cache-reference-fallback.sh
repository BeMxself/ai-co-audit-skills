#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/../sync-automation.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

source_root="${tmp_dir}/source-repo"
reference_dir="${source_root}/skills/implementation-audit/automation-ref"
target_dir="${tmp_dir}/target/automation/implementation-audit"
cache_reference="${tmp_dir}/.claude/plugins/cache/v1/implementation-audit"

mkdir -p "${reference_dir}/lib" "${target_dir}" "${cache_reference}"

cat >"${reference_dir}/README.md" <<'EOF'
source-readme
EOF
cat >"${reference_dir}/init.sh" <<'EOF'
#!/usr/bin/env bash
echo init
EOF
cat >"${reference_dir}/init-implementation-audit-task.sh" <<'EOF'
#!/usr/bin/env bash
echo init-task
EOF
cat >"${reference_dir}/run-implementation-audit.sh" <<'EOF'
#!/usr/bin/env bash
echo run
EOF
cat >"${reference_dir}/setup-kiro-agent.sh" <<'EOF'
#!/usr/bin/env bash
echo setup-kiro-agent
EOF
cat >"${reference_dir}/sync-automation.sh" <<'EOF'
#!/usr/bin/env bash
echo sync
EOF
cat >"${reference_dir}/lib/common.sh" <<'EOF'
#!/usr/bin/env bash
echo common
EOF
cat >"${reference_dir}/lib/runner.sh" <<'EOF'
#!/usr/bin/env bash
echo runner
EOF

chmod +x \
  "${reference_dir}/init.sh" \
  "${reference_dir}/init-implementation-audit-task.sh" \
  "${reference_dir}/run-implementation-audit.sh" \
  "${reference_dir}/setup-kiro-agent.sh" \
  "${reference_dir}/sync-automation.sh" \
  "${reference_dir}/lib/common.sh" \
  "${reference_dir}/lib/runner.sh"

set +e
output="$(AI_CO_AUDIT_SKILLS_SOURCE_DIR="${source_root}" "${SYNC_SCRIPT}" "${cache_reference}" "${target_dir}" --auto-copy 2>&1)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "expected successful fallback from cache reference"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "Cache reference detected. Using source dir:"; then
  echo "expected cache fallback info message"
  echo "$output"
  exit 1
fi

if [[ ! -f "${target_dir}/run-implementation-audit.sh" ]]; then
  echo "expected run script copied into target"
  exit 1
fi

if ! grep -q "echo run" "${target_dir}/run-implementation-audit.sh"; then
  echo "expected copied file content from source reference dir"
  exit 1
fi
