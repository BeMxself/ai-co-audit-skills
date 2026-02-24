#!/usr/bin/env bash

log_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
  echo "[$(log_ts)] [INFO] $*"
}

log_warn() {
  echo "[$(log_ts)] [WARN] $*" >&2
}

log_error() {
  echo "[$(log_ts)] [ERROR] $*" >&2
}

fail() {
  log_error "$*"
  exit 1
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
  done
}

ensure_dir() {
  mkdir -p "$1"
}

abs_path() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    echo "$p"
  else
    local dir
    local base
    dir="$(dirname "$p")"
    base="$(basename "$p")"
    if [[ -d "$dir" ]]; then
      echo "$(cd "$dir" && pwd)/$base"
    else
      echo "$(pwd)/$p"
    fi
  fi
}

json_required() {
  local json_file="$1"
  local jq_expr="$2"
  jq -er "$jq_expr" "$json_file"
}

json_optional() {
  local json_file="$1"
  local jq_expr="$2"
  jq -er "$jq_expr // empty" "$json_file" 2>/dev/null || true
}

contains_marker() {
  local file="$1"
  local marker="$2"
  local normalized_non_empty
  normalized_non_empty="$(tr -d '\r' <"$file" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | sed '/^$/d')"
  [[ "$normalized_non_empty" == "$marker" ]]
}

append_dialogue_entry() {
  local transcript_file="$1"
  local step_name="$2"
  local speaker="$3"
  local prompt_file="$4"
  local output_file="$5"

  {
    echo ""
    echo "## $(log_ts) | ${step_name} | ${speaker}"
    echo ""
    echo "### Prompt (${prompt_file})"
    echo '```text'
    cat "$prompt_file"
    echo '```'
    echo ""
    echo "### Output (${output_file})"
    echo '```markdown'
    cat "$output_file"
    echo '```'
    echo ""
  } >>"$transcript_file"
}

write_state_json() {
  local state_file="$1"
  local task_name="$2"
  local status="$3"
  local rounds_used="$4"
  local merged_report="$5"
  local success_marker="$6"
  local final_report_output_path="${7:-}"

  jq -n \
    --arg taskName "$task_name" \
    --arg status "$status" \
    --arg mergedReport "$merged_report" \
    --arg successMarker "$success_marker" \
    --arg finalReportOutputPath "$final_report_output_path" \
    --arg finishedAt "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --argjson roundsUsed "$rounds_used" \
    '{
      taskName: $taskName,
      status: $status,
      roundsUsed: $roundsUsed,
      mergedReport: $mergedReport,
      successMarker: $successMarker,
      finishedAt: $finishedAt
    } + (if $finalReportOutputPath == "" then {} else {finalReportOutputPath: $finalReportOutputPath} end)' >"$state_file"
}
