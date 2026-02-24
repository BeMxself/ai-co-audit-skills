#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TASK_DIR=""
OUTPUT_PATH=""

usage() {
  cat <<'USAGE'
Usage:
  automation/implementation-audit/export-final-report.sh --task-dir <task-dir> --output <path>

Options:
  --task-dir <dir>   Task directory under .ai-workflows (required)
  --output <path>    Output path (absolute or relative to workingDirectory)
  -h, --help         Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-dir)
      TASK_DIR="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$TASK_DIR" ]] || fail "--task-dir is required"
[[ -n "$OUTPUT_PATH" ]] || fail "--output is required"

TASK_DIR="$(abs_path "$TASK_DIR")"
[[ -d "$TASK_DIR" ]] || fail "task dir not found: $TASK_DIR"

CONFIG_FILE="${TASK_DIR}/config/task.json"
[[ -f "$CONFIG_FILE" ]] || fail "config file not found: $CONFIG_FILE"

require_commands jq

REPORT_BASE_NAME="$(json_required "$CONFIG_FILE" '.reportBaseName')"
WORKING_DIRECTORY="$(json_optional "$CONFIG_FILE" '.workingDirectory')"
[[ -n "$WORKING_DIRECTORY" ]] || WORKING_DIRECTORY="."

MERGED_REPORT="${TASK_DIR}/reports/merged/${REPORT_BASE_NAME}.md"
[[ -f "$MERGED_REPORT" ]] || fail "merged report not found: $MERGED_REPORT"

if [[ "$WORKING_DIRECTORY" = /* ]]; then
  WORKDIR="$WORKING_DIRECTORY"
else
  WORKDIR="${REPO_ROOT}/${WORKING_DIRECTORY}"
fi
[[ -d "$WORKDIR" ]] || fail "working directory not found: $WORKDIR"

if [[ "$OUTPUT_PATH" = /* ]]; then
  TARGET_ABS="$OUTPUT_PATH"
else
  TARGET_ABS="${WORKDIR}/${OUTPUT_PATH}"
fi

TARGET_DIR="$(dirname "$TARGET_ABS")"
ensure_dir "$TARGET_DIR"
cp "$MERGED_REPORT" "$TARGET_ABS"

log_info "Final report exported to: $TARGET_ABS"
