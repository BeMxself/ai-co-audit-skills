#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/runner.sh
source "${SCRIPT_DIR}/lib/runner.sh"

TASK_DIR=""
CONFIG_FILE=""
MAX_ROUNDS_OVERRIDE=""
DRY_RUN=0
RESUME=0
RESUME_FROM_PHASE=""
RESUME_FROM_ROUND=""
FINAL_REPORT_PATH_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage:
  automation/implementation-audit/run-implementation-audit.sh --task-dir <task-dir> [options]

Options:
  --task-dir <dir>       Task directory under .ai-workflows (required)
  --config <file>        Task config json path (default: <task-dir>/config/task.json)
  --max-rounds <n>       Override maxRounds from config
  --final-report-path <p> Override final report export path (relative to working directory)
  --resume               Resume from state/progress.json checkpoint
  --from-phase <phase>   Force resume from a specific phase (use with --resume)
  --from-round <n>       Force round index when phase is round-codex/round-claude
  --dry-run              Generate prompts/artifacts without invoking claude/codex
  -h, --help             Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-dir)
      TASK_DIR="$2"
      shift 2
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --max-rounds)
      MAX_ROUNDS_OVERRIDE="$2"
      shift 2
      ;;
    --final-report-path)
      FINAL_REPORT_PATH_OVERRIDE="$2"
      shift 2
      ;;
    --resume)
      RESUME=1
      shift
      ;;
    --from-phase)
      RESUME_FROM_PHASE="$2"
      shift 2
      ;;
    --from-round)
      RESUME_FROM_ROUND="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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
[[ "$DRY_RUN" -eq 1 && "$RESUME" -eq 1 ]] && fail "--dry-run and --resume cannot be used together"
[[ -n "$RESUME_FROM_PHASE" && "$RESUME" -ne 1 ]] && fail "--from-phase must be used with --resume"
[[ -n "$RESUME_FROM_ROUND" && "$RESUME" -ne 1 ]] && fail "--from-round must be used with --resume"

if [[ -n "$RESUME_FROM_ROUND" && ! "$RESUME_FROM_ROUND" =~ ^[1-9][0-9]*$ ]]; then
  fail "--from-round must be a positive integer"
fi

TASK_DIR="$(abs_path "$TASK_DIR")"
[[ -d "$TASK_DIR" ]] || fail "task dir not found: $TASK_DIR"

if [[ -z "$CONFIG_FILE" ]]; then
  CONFIG_FILE="${TASK_DIR}/config/task.json"
fi
CONFIG_FILE="$(abs_path "$CONFIG_FILE")"
[[ -f "$CONFIG_FILE" ]] || fail "config file not found: $CONFIG_FILE"

require_commands jq timeout

TASK_NAME="$(json_required "$CONFIG_FILE" '.taskName')"
OBJECTIVE="$(json_required "$CONFIG_FILE" '.objective')"
REPORT_BASE_NAME="$(json_required "$CONFIG_FILE" '.reportBaseName')"
MAX_ROUNDS_CFG="$(json_required "$CONFIG_FILE" '.maxRounds')"
SUCCESS_MARKER="$(json_optional "$CONFIG_FILE" '.successMarker')"
TIMEOUT_SECONDS="$(json_optional "$CONFIG_FILE" '.timeoutSeconds')"
WORKING_DIRECTORY="$(json_optional "$CONFIG_FILE" '.workingDirectory')"
FINAL_REPORT_PATH="$(json_optional "$CONFIG_FILE" '.finalReportPath')"
CLAUDE_CMD="$(json_optional "$CONFIG_FILE" '.agents.claude.command')"
CODEX_CMD="$(json_optional "$CONFIG_FILE" '.agents.codex.command')"

if [[ -n "$FINAL_REPORT_PATH_OVERRIDE" ]]; then
  FINAL_REPORT_PATH="$FINAL_REPORT_PATH_OVERRIDE"
fi


if [[ "$DRY_RUN" -eq 0 && -z "$CLAUDE_CMD" ]] && is_claude_code_session; then
  fail "Claude Code session detected. This workflow invokes the claude CLI, which cannot run inside Claude Code. Run it from an external terminal, or use --dry-run to generate prompts only."
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  if [[ -z "$CLAUDE_CMD" ]]; then
    require_commands claude
  fi
  if [[ -z "$CODEX_CMD" ]]; then
    require_commands codex
  fi
fi

[[ -n "$SUCCESS_MARKER" ]] || SUCCESS_MARKER="当前版本已无问题，可以作为正式版本使用"
[[ -n "$TIMEOUT_SECONDS" ]] || TIMEOUT_SECONDS="1800"
[[ -n "$WORKING_DIRECTORY" ]] || WORKING_DIRECTORY="."

if [[ -n "$MAX_ROUNDS_OVERRIDE" ]]; then
  MAX_ROUNDS="$MAX_ROUNDS_OVERRIDE"
else
  MAX_ROUNDS="$MAX_ROUNDS_CFG"
fi

if [[ "$WORKING_DIRECTORY" = /* ]]; then
  WORKDIR="$WORKING_DIRECTORY"
else
  WORKDIR="${REPO_ROOT}/${WORKING_DIRECTORY}"
fi
[[ -d "$WORKDIR" ]] || fail "working directory not found: $WORKDIR"

INPUTS_FILE="${TASK_DIR}/inputs/targets.txt"
INPUT_FILES=()
while IFS= read -r input_file; do
  INPUT_FILES+=("$input_file")
done < <(jq -er '.inputs[]' "$CONFIG_FILE")
[[ "${#INPUT_FILES[@]}" -gt 0 ]] || fail "config.inputs must not be empty"

PROMPTS_DIR="${TASK_DIR}/prompts"
REPORTS_INITIAL_DIR="${TASK_DIR}/reports/initial"
REPORTS_COMPARISON_DIR="${TASK_DIR}/reports/comparison"
REPORTS_MERGED_DIR="${TASK_DIR}/reports/merged"
REPORTS_ROUNDS_DIR="${TASK_DIR}/reports/rounds"
LOGS_DIR="${TASK_DIR}/logs"
STATE_DIR="${TASK_DIR}/state"
TRANSCRIPTS_DIR="${TASK_DIR}/transcripts"
TRANSCRIPT_FILE="${TRANSCRIPTS_DIR}/implementation-audit-dialogue.md"
STATE_FILE="${STATE_DIR}/state.json"
PROGRESS_FILE="${STATE_DIR}/progress.json"

ensure_dir "${PROMPTS_DIR}"
ensure_dir "${REPORTS_INITIAL_DIR}"
ensure_dir "${REPORTS_COMPARISON_DIR}"
ensure_dir "${REPORTS_MERGED_DIR}"
ensure_dir "${REPORTS_ROUNDS_DIR}"
ensure_dir "${LOGS_DIR}"
ensure_dir "${STATE_DIR}"
ensure_dir "${TRANSCRIPTS_DIR}"

printf "%s\n" "${INPUT_FILES[@]}" >"${INPUTS_FILE}"

INITIAL_PROMPT="${PROMPTS_DIR}/01-initial-review.prompt.txt"
COMPARE_PROMPT="${PROMPTS_DIR}/02-compare.prompt.txt"
MERGE_PROMPT="${PROMPTS_DIR}/03-merge.prompt.txt"

CLAUDE_INITIAL_REPORT="${REPORTS_INITIAL_DIR}/${REPORT_BASE_NAME}-claude.md"
CODEX_INITIAL_REPORT="${REPORTS_INITIAL_DIR}/${REPORT_BASE_NAME}-codex.md"
CLAUDE_COMPARE_REPORT="${REPORTS_COMPARISON_DIR}/${REPORT_BASE_NAME}-compare-by-claude.md"
CODEX_COMPARE_REPORT="${REPORTS_COMPARISON_DIR}/${REPORT_BASE_NAME}-compare-by-codex.md"
MERGED_REPORT="${REPORTS_MERGED_DIR}/${REPORT_BASE_NAME}.md"
FINAL_REPORT_OUTPUT_ABS=""
PROMPT_INLINE_WARN_BYTES=200000

build_input_list() {
  local out=""
  local f
  for f in "${INPUT_FILES[@]}"; do
    out+="- ${f}"$'\n'
  done
  echo "$out"
}

render_file_block() {
  local title="$1"
  local file="$2"
  local file_bytes=0

  [[ -f "$file" ]] || fail "required artifact missing for prompt assembly: $file (this phase depends on outputs from earlier phases; if resuming with --from-phase, ensure prerequisite outputs exist)"
  file_bytes="$(wc -c <"$file" | tr -d '[:space:]')"
  if [[ "$file_bytes" -gt "$PROMPT_INLINE_WARN_BYTES" ]]; then
    log_warn "large inline prompt source detected (${file_bytes} bytes): $file (section=${title}); agent context truncation risk may increase"
  fi

  cat <<EOF_BLOCK
【${title} 文件路径】
${file}
【${title} 内容】
$(cat "$file")
EOF_BLOCK
}

build_initial_prompt() {
  cat >"$INITIAL_PROMPT" <<EOF_PROMPT
你是资深评审工程师。请基于以下输入材料进行实现一致性会审。

【评审目标】
${OBJECTIVE}

【输入材料】
$(build_input_list)

【输出要求】
1. 输出 Markdown 审查报告。
2. 优先找出：未完成、与设计不符合、违反设计原则、重复实现、逻辑不自洽、实现矛盾。
3. 按严重级别排序（先高后低）。
4. 每条问题必须给出可验证证据（文件路径 + 行号）。
5. 最后补充：未阻断但建议跟进项。
6. 只输出报告正文，不要额外说明文字。
EOF_PROMPT
}

build_compare_prompt() {
  {
    cat <<EOF_PROMPT
你是技术审查对比分析员。请对两份审查报告进行对比分析。
EOF_PROMPT

    echo ""
    render_file_block "报告A" "$CLAUDE_INITIAL_REPORT"

    echo ""
    render_file_block "报告B" "$CODEX_INITIAL_REPORT"

    cat <<EOF_PROMPT

【输出要求】
1. 输出 Markdown 对比分析。
2. 给出：共同结论、仅A提出、仅B提出、互相冲突点。
3. 对冲突点标注你认为更可信的一方并说明依据。
4. 给出后续合并建议（保留、降级、删除、待确认）。
5. 只输出对比分析正文，不要额外说明文字。
EOF_PROMPT
  } >"$COMPARE_PROMPT"
}

build_merge_prompt() {
  {
    cat <<EOF_PROMPT
你是会审合并编辑。请基于两份报告和两份对比分析，产出一份合并版正式审查报告。
EOF_PROMPT

    echo ""
    render_file_block "初始报告-claude" "$CLAUDE_INITIAL_REPORT"

    echo ""
    render_file_block "初始报告-codex" "$CODEX_INITIAL_REPORT"

    echo ""
    render_file_block "对比分析-claude" "$CLAUDE_COMPARE_REPORT"

    echo ""
    render_file_block "对比分析-codex" "$CODEX_COMPARE_REPORT"

    cat <<EOF_PROMPT

【输出要求】
1. 输出完整 Markdown 报告正文（不要额外解释）。
2. 保留可验证问题，去除已证伪或证据不足项。
3. 所有问题按严重级别排序并包含证据路径+行号。
4. 加入“审查边界/待确认项”。
EOF_PROMPT
  } >"$MERGE_PROMPT"
}

build_codex_round_prompt() {
  local round="$1"
  local prompt_file="${PROMPTS_DIR}/04-round-${round}-codex-review.prompt.txt"
  {
    cat <<EOF_PROMPT
请评审以下“合并版审查报告”的质量与事实准确性：
EOF_PROMPT

    echo ""
    render_file_block "合并版审查报告" "$MERGED_REPORT"

    cat <<EOF_PROMPT

重点检查：
1. 是否还有事实错误、误报、证据不足、矛盾表述。
2. 是否存在可改进之处（分级、措辞、证据完整性）。

【严格输出规则】
- 如果你认为当前版本已无问题，或你提出的意见全部可视为不必采纳，请严格输出以下字符串（原样，不要增加任何其他内容）：
${SUCCESS_MARKER}
- 否则输出“问题清单（按严重级）”，每条包含修改建议。
EOF_PROMPT
  } >"$prompt_file"
  echo "$prompt_file"
}

build_claude_round_prompt() {
  local round="$1"
  local codex_feedback_file="$2"
  local prompt_file="${PROMPTS_DIR}/05-round-${round}-claude-revise.prompt.txt"
  {
    cat <<EOF_PROMPT
请根据 codex 的评审意见修订合并版审查报告。
EOF_PROMPT

    echo ""
    render_file_block "当前合并版" "$MERGED_REPORT"

    echo ""
    render_file_block "codex 评审意见" "$codex_feedback_file"

    cat <<EOF_PROMPT

【严格输出规则】
- 如果你决定“全部不采纳 codex 本轮意见”，请严格输出以下字符串（原样，不要增加任何其他内容）：
${SUCCESS_MARKER}
- 否则请输出“修订后的完整 Markdown 报告正文”（完整替换版本，不要解释）。
EOF_PROMPT
  } >"$prompt_file"
  echo "$prompt_file"
}

write_dry_run_placeholder() {
  local out_file="$1"
  local title="$2"
  cat >"$out_file" <<EOF_OUT
# ${title}

DRY-RUN: no agent execution.
EOF_OUT
}

publish_final_report_if_configured() {
  local configured_path="${1:-}"
  local target_abs=""
  local target_dir=""

  [[ -n "$configured_path" ]] || return 0

  if [[ "$configured_path" = /* ]]; then
    fail "config.finalReportPath must be a relative path (relative to working directory): $configured_path"
  fi

  [[ -f "$MERGED_REPORT" ]] || fail "merged report not found, cannot export final report: $MERGED_REPORT"

  target_abs="${WORKDIR}/${configured_path}"
  target_dir="$(dirname "$target_abs")"
  ensure_dir "$target_dir"
  cp "$MERGED_REPORT" "$target_abs"
  FINAL_REPORT_OUTPUT_ABS="$target_abs"
}

write_progress_json() {
  local status="$1"
  local next_phase="$2"
  local next_round="$3"
  local final_status="${4:-}"
  local last_step="${5:-}"

  jq -n \
    --arg taskName "$TASK_NAME" \
    --arg status "$status" \
    --arg nextPhase "$next_phase" \
    --arg finalStatus "$final_status" \
    --arg lastStep "$last_step" \
    --arg mergedReport "$MERGED_REPORT" \
    --arg updatedAt "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --argjson nextRound "$next_round" \
    '{
      taskName: $taskName,
      status: $status,
      nextPhase: $nextPhase,
      nextRound: $nextRound,
      finalStatus: $finalStatus,
      lastStep: $lastStep,
      mergedReport: $mergedReport,
      updatedAt: $updatedAt
    }' >"$PROGRESS_FILE"
}

run_agent_checked() {
  local agent="$1"
  local prompt_file="$2"
  local output_file="$3"
  local log_file="$4"
  local step_name="$5"
  local custom_cmd="$6"
  local rc=0
  local final_status=""

  set +e
  run_agent "$agent" "$prompt_file" "$output_file" "$log_file" "$TIMEOUT_SECONDS" "$WORKDIR" "$custom_cmd"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 124 ]]; then
      final_status="failed-timeout-${step_name}"
    else
      final_status="failed-${step_name}-exit-${rc}"
    fi
    write_progress_json "failed" "$NEXT_PHASE" "$NEXT_ROUND" "$final_status" "$step_name"
    fail "agent failed at step ${step_name} (exit=${rc}), checkpoint saved to ${PROGRESS_FILE}"
  fi
}

init_transcript_fresh() {
  cat >"$TRANSCRIPT_FILE" <<EOF_TRANSCRIPT
# AI Implementation Audit Dialogue

- Task: ${TASK_NAME}
- Started At: $(date '+%Y-%m-%d %H:%M:%S')
- Success Marker: ${SUCCESS_MARKER}

EOF_TRANSCRIPT
}

append_resume_header() {
  local next_phase="$1"
  local next_round="$2"
  local reason="${3:-}"

  if [[ ! -f "$TRANSCRIPT_FILE" ]]; then
    init_transcript_fresh
  fi

  {
    echo ""
    echo "## $(log_ts) | Resume"
    echo ""
    echo "- Next phase: ${next_phase}"
    echo "- Next round: ${next_round}"
    if [[ -n "$reason" ]]; then
      echo "- Resume reason: ${reason}"
    fi
    echo ""
  } >>"$TRANSCRIPT_FILE"
}

is_valid_phase() {
  case "$1" in
    initial-claude|initial-codex|compare-claude|compare-codex|merge-claude|round-codex|round-claude|completed)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

status=""
NEXT_PHASE="initial-claude"
NEXT_ROUND=1
LAST_ROUND_EXECUTED=0

log_info "Task: ${TASK_NAME}"
log_info "Task dir: ${TASK_DIR}"
log_info "Config: ${CONFIG_FILE}"
log_info "Working directory: ${WORKDIR}"
log_info "Max rounds: ${MAX_ROUNDS}"
log_info "Success marker: ${SUCCESS_MARKER}"
if [[ -n "$FINAL_REPORT_PATH" ]]; then
  log_info "Final report path (relative to working directory): ${FINAL_REPORT_PATH}"
fi
log_info "Dry run: ${DRY_RUN}"
log_info "Resume: ${RESUME}"

build_initial_prompt

if [[ "$DRY_RUN" -eq 1 ]]; then
  init_transcript_fresh
  write_dry_run_placeholder "$CLAUDE_INITIAL_REPORT" "Initial Review (Claude)"
  write_dry_run_placeholder "$CODEX_INITIAL_REPORT" "Initial Review (Codex)"
  build_compare_prompt
  write_dry_run_placeholder "$CLAUDE_COMPARE_REPORT" "Compare Analysis (Claude)"
  write_dry_run_placeholder "$CODEX_COMPARE_REPORT" "Compare Analysis (Codex)"
  build_merge_prompt
  write_dry_run_placeholder "$MERGED_REPORT" "Merged Report (Claude)"
  append_dialogue_entry "$TRANSCRIPT_FILE" "Initial Review" "claude" "$INITIAL_PROMPT" "$CLAUDE_INITIAL_REPORT"
  append_dialogue_entry "$TRANSCRIPT_FILE" "Initial Review" "codex" "$INITIAL_PROMPT" "$CODEX_INITIAL_REPORT"
  append_dialogue_entry "$TRANSCRIPT_FILE" "Compare Reports" "claude" "$COMPARE_PROMPT" "$CLAUDE_COMPARE_REPORT"
  append_dialogue_entry "$TRANSCRIPT_FILE" "Compare Reports" "codex" "$COMPARE_PROMPT" "$CODEX_COMPARE_REPORT"
  append_dialogue_entry "$TRANSCRIPT_FILE" "Merge Reports" "claude" "$MERGE_PROMPT" "$MERGED_REPORT"
  write_progress_json "completed" "completed" 0 "dry-run-complete" "dry-run"
  publish_final_report_if_configured "$FINAL_REPORT_PATH"
  write_state_json "$STATE_FILE" "$TASK_NAME" "dry-run-complete" 0 "$MERGED_REPORT" "$SUCCESS_MARKER" "$FINAL_REPORT_OUTPUT_ABS"
  if [[ -n "$FINAL_REPORT_OUTPUT_ABS" ]]; then
    log_info "Final report exported to: $FINAL_REPORT_OUTPUT_ABS"
  fi
  log_info "Dry-run completed."
  exit 0
fi

if [[ "$RESUME" -eq 1 ]]; then
  [[ -f "$PROGRESS_FILE" ]] || fail "progress file not found: $PROGRESS_FILE"
  NEXT_PHASE="$(json_required "$PROGRESS_FILE" '.nextPhase')"
  NEXT_ROUND="$(json_required "$PROGRESS_FILE" '.nextRound')"

  if [[ -n "$RESUME_FROM_PHASE" ]]; then
    is_valid_phase "$RESUME_FROM_PHASE" || fail "invalid --from-phase: $RESUME_FROM_PHASE"
    NEXT_PHASE="$RESUME_FROM_PHASE"

    if [[ "$NEXT_PHASE" == "round-codex" || "$NEXT_PHASE" == "round-claude" ]]; then
      if [[ -n "$RESUME_FROM_ROUND" ]]; then
        NEXT_ROUND="$RESUME_FROM_ROUND"
      elif [[ "$NEXT_ROUND" -lt 1 ]]; then
        NEXT_ROUND=1
      fi
    else
      if [[ -n "$RESUME_FROM_ROUND" ]]; then
        fail "--from-round can only be used with --from-phase round-codex or round-claude"
      fi
      NEXT_ROUND=1
    fi

    write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "manual-resume-override"
    append_resume_header "$NEXT_PHASE" "$NEXT_ROUND" "manual-override"
  else
    append_resume_header "$NEXT_PHASE" "$NEXT_ROUND"
  fi
else
  init_transcript_fresh
  write_progress_json "running" "initial-claude" 1 "" "bootstrap"
fi

while :; do
  case "$NEXT_PHASE" in
    initial-claude)
      run_agent_checked "claude" "$INITIAL_PROMPT" "$CLAUDE_INITIAL_REPORT" \
        "${LOGS_DIR}/01-initial-claude.log" "initial-claude" "$CLAUDE_CMD"
      append_dialogue_entry "$TRANSCRIPT_FILE" "Initial Review" "claude" "$INITIAL_PROMPT" "$CLAUDE_INITIAL_REPORT"
      NEXT_PHASE="initial-codex"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "initial-claude"
      ;;

    initial-codex)
      run_agent_checked "codex" "$INITIAL_PROMPT" "$CODEX_INITIAL_REPORT" \
        "${LOGS_DIR}/01-initial-codex.log" "initial-codex" "$CODEX_CMD"
      append_dialogue_entry "$TRANSCRIPT_FILE" "Initial Review" "codex" "$INITIAL_PROMPT" "$CODEX_INITIAL_REPORT"
      NEXT_PHASE="compare-claude"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "initial-codex"
      ;;

    compare-claude)
      build_compare_prompt
      run_agent_checked "claude" "$COMPARE_PROMPT" "$CLAUDE_COMPARE_REPORT" \
        "${LOGS_DIR}/02-compare-claude.log" "compare-claude" "$CLAUDE_CMD"
      append_dialogue_entry "$TRANSCRIPT_FILE" "Compare Reports" "claude" "$COMPARE_PROMPT" "$CLAUDE_COMPARE_REPORT"
      NEXT_PHASE="compare-codex"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "compare-claude"
      ;;

    compare-codex)
      build_compare_prompt
      run_agent_checked "codex" "$COMPARE_PROMPT" "$CODEX_COMPARE_REPORT" \
        "${LOGS_DIR}/02-compare-codex.log" "compare-codex" "$CODEX_CMD"
      append_dialogue_entry "$TRANSCRIPT_FILE" "Compare Reports" "codex" "$COMPARE_PROMPT" "$CODEX_COMPARE_REPORT"
      NEXT_PHASE="merge-claude"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "compare-codex"
      ;;

    merge-claude)
      build_merge_prompt
      run_agent_checked "claude" "$MERGE_PROMPT" "$MERGED_REPORT" \
        "${LOGS_DIR}/03-merge-claude.log" "merge-claude" "$CLAUDE_CMD"
      append_dialogue_entry "$TRANSCRIPT_FILE" "Merge Reports" "claude" "$MERGE_PROMPT" "$MERGED_REPORT"
      NEXT_PHASE="round-codex"
      NEXT_ROUND=1
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "merge-claude"
      ;;

    round-codex)
      if [[ "$NEXT_ROUND" -gt "$MAX_ROUNDS" ]]; then
        status="max-rounds-reached"
        NEXT_PHASE="completed"
        write_progress_json "completed" "$NEXT_PHASE" "$NEXT_ROUND" "$status" "round-limit"
        break
      fi

      LAST_ROUND_EXECUTED="$NEXT_ROUND"
      round_label="$(printf '%02d' "$NEXT_ROUND")"
      codex_prompt="$(build_codex_round_prompt "$round_label")"
      codex_review_file="${REPORTS_ROUNDS_DIR}/round-${round_label}-codex-review.md"
      codex_log_file="${LOGS_DIR}/04-round-${round_label}-codex-review.log"

      run_agent_checked "codex" "$codex_prompt" "$codex_review_file" \
        "$codex_log_file" "round-${round_label}-codex" "$CODEX_CMD"
      append_dialogue_entry "$TRANSCRIPT_FILE" "Round ${round_label} Review" "codex" "$codex_prompt" "$codex_review_file"

      if contains_marker "$codex_review_file" "$SUCCESS_MARKER"; then
        status="accepted-by-codex-round-${round_label}"
        NEXT_PHASE="completed"
        write_progress_json "completed" "$NEXT_PHASE" "$NEXT_ROUND" "$status" "round-${round_label}-codex"
        break
      fi

      NEXT_PHASE="round-claude"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "round-${round_label}-codex"
      ;;

    round-claude)
      if [[ "$NEXT_ROUND" -gt "$MAX_ROUNDS" ]]; then
        status="max-rounds-reached"
        NEXT_PHASE="completed"
        write_progress_json "completed" "$NEXT_PHASE" "$NEXT_ROUND" "$status" "round-limit"
        break
      fi

      LAST_ROUND_EXECUTED="$NEXT_ROUND"
      round_label="$(printf '%02d' "$NEXT_ROUND")"
      codex_review_file="${REPORTS_ROUNDS_DIR}/round-${round_label}-codex-review.md"
      claude_prompt="$(build_claude_round_prompt "$round_label" "$codex_review_file")"
      claude_revision_file="${REPORTS_ROUNDS_DIR}/round-${round_label}-claude-revision.md"
      claude_log_file="${LOGS_DIR}/05-round-${round_label}-claude-revision.log"

      run_agent_checked "claude" "$claude_prompt" "$claude_revision_file" \
        "$claude_log_file" "round-${round_label}-claude" "$CLAUDE_CMD"
      append_dialogue_entry "$TRANSCRIPT_FILE" "Round ${round_label} Revision" "claude" "$claude_prompt" "$claude_revision_file"

      if contains_marker "$claude_revision_file" "$SUCCESS_MARKER"; then
        status="claude-rejected-all-feedback-round-${round_label}"
        NEXT_PHASE="completed"
        write_progress_json "completed" "$NEXT_PHASE" "$NEXT_ROUND" "$status" "round-${round_label}-claude"
        break
      fi

      cp "$claude_revision_file" "$MERGED_REPORT"
      NEXT_ROUND=$((NEXT_ROUND + 1))
      NEXT_PHASE="round-codex"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "round-${round_label}-claude"
      ;;

    completed)
      status="$(json_optional "$PROGRESS_FILE" '.finalStatus')"
      [[ -n "$status" ]] || status="completed"
      break
      ;;

    *)
      fail "unknown next phase in progress file: $NEXT_PHASE"
      ;;
  esac
done

rounds_used="$LAST_ROUND_EXECUTED"
if [[ "$status" == "max-rounds-reached" ]]; then
  rounds_used="$MAX_ROUNDS"
fi
if [[ "$rounds_used" -eq 0 ]]; then
  parsed_round="$(printf "%s" "$status" | sed -n 's/.*-round-\([0-9][0-9]*\)$/\1/p')"
  if [[ -n "$parsed_round" ]]; then
    rounds_used="$((10#$parsed_round))"
  fi
fi

publish_final_report_if_configured "$FINAL_REPORT_PATH"
write_state_json "$STATE_FILE" "$TASK_NAME" "$status" "$rounds_used" "$MERGED_REPORT" "$SUCCESS_MARKER" "$FINAL_REPORT_OUTPUT_ABS"
log_info "Completed with status: $status"
log_info "Merged report: $MERGED_REPORT"
if [[ -n "$FINAL_REPORT_OUTPUT_ABS" ]]; then
  log_info "Final report exported to: $FINAL_REPORT_OUTPUT_ABS"
fi
log_info "Transcript: $TRANSCRIPT_FILE"
log_info "Progress: $PROGRESS_FILE"

if [[ "$status" == "max-rounds-reached" ]]; then
  exit 2
fi
