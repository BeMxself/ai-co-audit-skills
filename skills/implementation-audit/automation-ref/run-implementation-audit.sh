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
TIMEOUT_SECONDS_OVERRIDE=""
DRY_RUN=0
RESUME=0
RESUME_FROM_PHASE=""
RESUME_FROM_ROUND=""
FINAL_REPORT_PATH_OVERRIDE=""
REVIEWER_RUNNER_OVERRIDE=""
REVISER_RUNNER_OVERRIDE=""
PLUGIN_VERSION="2.0.0"
RUNNING_BG_PIDS=()

REVIEWER_RUNNER=""
REVISER_RUNNER=""
REVIEWER_CMD=""
REVISER_CMD=""
KIRO_AGENT_NAME=""

register_running_bg_pids() {
  RUNNING_BG_PIDS=("$@")
}

clear_running_bg_pids() {
  RUNNING_BG_PIDS=()
}

force_stop_running_bg_pids() {
  local pid=""

  if [[ "${#RUNNING_BG_PIDS[@]}" -eq 0 ]]; then
    return 0
  fi

  for pid in "${RUNNING_BG_PIDS[@]}"; do
    kill -TERM -- "-${pid}" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.2
  for pid in "${RUNNING_BG_PIDS[@]}"; do
    kill -KILL -- "-${pid}" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
}

handle_interrupt() {
  log_warn "Interrupt received. Stopping running processes..."
  force_stop_running_bg_pids
  exit 130
}

trap 'handle_interrupt' INT TERM

confirm_run_start() {
  local answer=""

  log_info "Plugin version: ${PLUGIN_VERSION}"
  if [[ ! -t 0 ]]; then
    log_info "Non-interactive stdin detected. Auto-continue."
    return 0
  fi

  printf "Continue with implementation audit? [y/N]: "
  if ! IFS= read -r answer; then
    answer=""
  fi
  case "$answer" in
    y|Y)
      log_info "Confirmation accepted. Continue."
      ;;
    *)
      log_warn "User cancelled run at confirmation step."
      exit 3
      ;;
  esac
}

usage() {
  cat <<'USAGE'
Usage:
  automation/implementation-audit/run-implementation-audit.sh --task-dir <task-dir> [options]

Options:
  --task-dir <dir>         Task directory under .ai-workflows (required)
  --config <file>          Task config json path (default: <task-dir>/config/task.json)
  --reviewer <runner>      Override reviewer runner (default from config or codex)
  --reviser <runner>       Override reviser runner (default from config or claude)
  --max-rounds <n>         Override maxRounds from config
  --timeout-seconds <n>    Override timeoutSeconds from config
  --final-report-path <p>  Override final report export path (relative to working directory)
  --resume                 Resume from state/progress.json checkpoint
  --from-phase <phase>     Force resume from a specific phase (use with --resume)
  --from-round <n>         Force round index when phase is round-reviewer/round-reviser
  --dry-run                Generate prompts/artifacts without invoking agents
  -h, --help               Show help
USAGE
}

validate_runner_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid runner name: $name"
}

runner_command_from_config() {
  local runner="$1"
  jq -er --arg runner "$runner" '.runners[$runner].command // empty' "$CONFIG_FILE" 2>/dev/null || true
}

runner_kiro_agent_from_config() {
  jq -er '.runners.kiro.agent // empty' "$CONFIG_FILE" 2>/dev/null || true
}

validate_kiro_agent_file_tools() {
  local workdir="$1"
  local agent_name="$2"
  local agent_file="${workdir}/.kiro/agents/${agent_name}.json"
  local has_read=0
  local has_write=0
  local tool=""

  [[ -f "$agent_file" ]] || fail "Kiro agent config not found: ${agent_file}. Run automation/implementation-audit/setup-kiro-agent.sh --project-root \"${workdir}\" --agent-name \"${agent_name}\" --force"

  if jq -er '.tools // [] | index("*") != null' "$agent_file" >/dev/null 2>&1; then
    return 0
  fi

  for tool in fs_read read_file file_read; do
    if jq -er --arg t "$tool" '.tools // [] | index($t) != null' "$agent_file" >/dev/null 2>&1; then
      has_read=1
      break
    fi
  done

  for tool in fs_write write_file file_write; do
    if jq -er --arg t "$tool" '.tools // [] | index($t) != null' "$agent_file" >/dev/null 2>&1; then
      has_write=1
      break
    fi
  done

  if [[ "$has_read" -eq 1 && "$has_write" -eq 1 ]]; then
    return 0
  fi

  fail "Kiro agent lacks file read/write tools: ${agent_file}. Regenerate with: automation/implementation-audit/setup-kiro-agent.sh --project-root \"${workdir}\" --agent-name \"${agent_name}\" --force"
}

ensure_runner_ready() {
  local runner="$1"
  local command="$2"

  if [[ -n "$command" ]]; then
    return 0
  fi

  case "$runner" in
    claude)
      if is_claude_code_session; then
        fail "Claude Code session detected. Runner 'claude' invokes the claude CLI, which cannot run inside Claude Code. Run from an external terminal, or use --dry-run."
      fi
      require_commands claude
      ;;
    codex)
      require_commands codex
      ;;
    kiro)
      require_commands kiro-cli
      [[ -n "$KIRO_AGENT_NAME" ]] || KIRO_AGENT_NAME="${IMPLEMENTATION_AUDIT_KIRO_AGENT:-ai-co-audit-kiro-opus}"
      validate_kiro_agent_file_tools "$WORKDIR" "$KIRO_AGENT_NAME"
      ;;
    *)
      fail "unknown built-in runner '${runner}'. Configure runners.${runner}.command in task config or choose claude/codex/kiro"
      ;;
  esac
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
    --reviewer)
      REVIEWER_RUNNER_OVERRIDE="$2"
      shift 2
      ;;
    --reviser)
      REVISER_RUNNER_OVERRIDE="$2"
      shift 2
      ;;
    --max-rounds)
      MAX_ROUNDS_OVERRIDE="$2"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS_OVERRIDE="$2"
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
REVIEWER_RUNNER_CFG="$(json_optional "$CONFIG_FILE" '.execution.reviewer')"
REVISER_RUNNER_CFG="$(json_optional "$CONFIG_FILE" '.execution.reviser')"

REVIEWER_RUNNER="${REVIEWER_RUNNER_OVERRIDE:-${REVIEWER_RUNNER_CFG:-codex}}"
REVISER_RUNNER="${REVISER_RUNNER_OVERRIDE:-${REVISER_RUNNER_CFG:-claude}}"

validate_runner_name "$REVIEWER_RUNNER"
validate_runner_name "$REVISER_RUNNER"
[[ "$REVIEWER_RUNNER" != "$REVISER_RUNNER" ]] || fail "reviewer and reviser must be different runners"

REVIEWER_CMD="$(runner_command_from_config "$REVIEWER_RUNNER")"
REVISER_CMD="$(runner_command_from_config "$REVISER_RUNNER")"
KIRO_AGENT_NAME="$(runner_kiro_agent_from_config)"
[[ -n "$KIRO_AGENT_NAME" ]] || KIRO_AGENT_NAME="${IMPLEMENTATION_AUDIT_KIRO_AGENT:-ai-co-audit-kiro-opus}"

if [[ -n "$FINAL_REPORT_PATH_OVERRIDE" ]]; then
  FINAL_REPORT_PATH="$FINAL_REPORT_PATH_OVERRIDE"
fi

if [[ -n "$TIMEOUT_SECONDS_OVERRIDE" ]]; then
  TIMEOUT_SECONDS="$TIMEOUT_SECONDS_OVERRIDE"
fi

[[ -n "$SUCCESS_MARKER" ]] || SUCCESS_MARKER="当前版本已无问题，可以作为正式版本使用"
[[ -n "$TIMEOUT_SECONDS" ]] || TIMEOUT_SECONDS="7200"
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

if [[ "$DRY_RUN" -eq 0 ]]; then
  if [[ "$REVIEWER_RUNNER" == "kiro" || "$REVISER_RUNNER" == "kiro" ]]; then
    export IMPLEMENTATION_AUDIT_KIRO_AGENT="$KIRO_AGENT_NAME"
  fi
  ensure_runner_ready "$REVIEWER_RUNNER" "$REVIEWER_CMD"
  ensure_runner_ready "$REVISER_RUNNER" "$REVISER_CMD"
fi

INPUTS_FILE="${TASK_DIR}/inputs/targets.txt"
INPUT_FILES=()
while IFS= read -r input_file; do
  INPUT_FILES+=("$input_file")
done < <(jq -er '.inputs[]' "$CONFIG_FILE")
[[ "${#INPUT_FILES[@]}" -gt 0 ]] || fail "config.inputs must not be empty"

confirm_run_start

PROMPTS_DIR="${TASK_DIR}/prompts"
REPORTS_INITIAL_DIR="${TASK_DIR}/reports/initial"
REPORTS_COMPARISON_DIR="${TASK_DIR}/reports/comparison"
REPORTS_MERGED_DIR="${TASK_DIR}/reports/merged"
REPORTS_ROUNDS_DIR="${TASK_DIR}/reports/rounds"
LOGS_DIR="${TASK_DIR}/logs"
STATE_DIR="${TASK_DIR}/state"
STATE_FILE="${STATE_DIR}/state.json"
PROGRESS_FILE="${STATE_DIR}/progress.json"

ensure_dir "${PROMPTS_DIR}"
ensure_dir "${REPORTS_INITIAL_DIR}"
ensure_dir "${REPORTS_COMPARISON_DIR}"
ensure_dir "${REPORTS_MERGED_DIR}"
ensure_dir "${REPORTS_ROUNDS_DIR}"
ensure_dir "${LOGS_DIR}"
ensure_dir "${STATE_DIR}"

printf "%s\n" "${INPUT_FILES[@]}" >"${INPUTS_FILE}"

INITIAL_PROMPT="${PROMPTS_DIR}/01-initial-review.prompt.txt"
COMPARE_PROMPT="${PROMPTS_DIR}/02-compare.prompt.txt"
MERGE_PROMPT="${PROMPTS_DIR}/03-merge.prompt.txt"

INITIAL_REVISER_REPORT="${REPORTS_INITIAL_DIR}/${REPORT_BASE_NAME}-${REVISER_RUNNER}.md"
INITIAL_REVIEWER_REPORT="${REPORTS_INITIAL_DIR}/${REPORT_BASE_NAME}-${REVIEWER_RUNNER}.md"
COMPARE_REVISER_REPORT="${REPORTS_COMPARISON_DIR}/${REPORT_BASE_NAME}-compare-by-${REVISER_RUNNER}.md"
COMPARE_REVIEWER_REPORT="${REPORTS_COMPARISON_DIR}/${REPORT_BASE_NAME}-compare-by-${REVIEWER_RUNNER}.md"
MERGED_REPORT="${REPORTS_MERGED_DIR}/${REPORT_BASE_NAME}.md"
FINAL_REPORT_OUTPUT_ABS=""

run_initial_phase() {
  local need_reviser=1
  local need_reviewer=1
  local reviser_rc_file="${LOGS_DIR}/.rc-initial-${REVISER_RUNNER}"
  local reviewer_rc_file="${LOGS_DIR}/.rc-initial-${REVIEWER_RUNNER}"
  local rc=0
  local final_status=""

  if [[ -s "$INITIAL_REVISER_REPORT" ]]; then
    need_reviser=0
  fi
  if [[ -s "$INITIAL_REVIEWER_REPORT" ]]; then
    need_reviewer=0
  fi

  if [[ "$need_reviser" -eq 0 && "$need_reviewer" -eq 0 ]]; then
    log_info "Phase start: initial (skip, reports already exist)"
    log_info "Phase done: initial (skip, reports already exist)"
    return 0
  fi

  if [[ "$need_reviser" -eq 1 && "$need_reviewer" -eq 1 ]]; then
    log_info "Phase start: initial (${REVISER_RUNNER}+${REVIEWER_RUNNER})"

    rm -f "$reviser_rc_file" "$reviewer_rc_file"
    set -m
    (
      run_agent "$REVISER_RUNNER" "$INITIAL_PROMPT" "$INITIAL_REVISER_REPORT" \
        "${LOGS_DIR}/01-initial-${REVISER_RUNNER}.log" "$TIMEOUT_SECONDS" "$WORKDIR" "$REVISER_CMD"
      echo $? >"$reviser_rc_file"
    ) &
    reviser_pid=$!

    (
      run_agent "$REVIEWER_RUNNER" "$INITIAL_PROMPT" "$INITIAL_REVIEWER_REPORT" \
        "${LOGS_DIR}/01-initial-${REVIEWER_RUNNER}.log" "$TIMEOUT_SECONDS" "$WORKDIR" "$REVIEWER_CMD"
      echo $? >"$reviewer_rc_file"
    ) &
    reviewer_pid=$!
    set +m

    register_running_bg_pids "$reviser_pid" "$reviewer_pid"
    wait "$reviser_pid" || true
    wait "$reviewer_pid" || true
    clear_running_bg_pids

    rc=0
    if [[ -f "$reviser_rc_file" ]]; then
      rc="$(cat "$reviser_rc_file" || echo 1)"
    else
      rc=1
    fi
    if [[ "$rc" -ne 0 ]]; then
      if [[ "$rc" -eq 124 ]]; then
        final_status="failed-timeout-initial-${REVISER_RUNNER}"
      else
        final_status="failed-initial-${REVISER_RUNNER}-exit-${rc}"
      fi
      write_progress_json "failed" "initial-reviser" "$NEXT_ROUND" "$final_status" "initial-${REVISER_RUNNER}"
      fail "agent failed at step initial-${REVISER_RUNNER} (exit=${rc}), checkpoint saved to ${PROGRESS_FILE}"
    fi

    rc=0
    if [[ -f "$reviewer_rc_file" ]]; then
      rc="$(cat "$reviewer_rc_file" || echo 1)"
    else
      rc=1
    fi
    if [[ "$rc" -ne 0 ]]; then
      if [[ "$rc" -eq 124 ]]; then
        final_status="failed-timeout-initial-${REVIEWER_RUNNER}"
      else
        final_status="failed-initial-${REVIEWER_RUNNER}-exit-${rc}"
      fi
      write_progress_json "failed" "initial-reviewer" "$NEXT_ROUND" "$final_status" "initial-${REVIEWER_RUNNER}"
      fail "agent failed at step initial-${REVIEWER_RUNNER} (exit=${rc}), checkpoint saved to ${PROGRESS_FILE}"
    fi

    log_info "Phase done: initial (${REVISER_RUNNER}+${REVIEWER_RUNNER})"
    return 0
  fi

  if [[ "$need_reviser" -eq 1 ]]; then
    log_info "Phase start: initial (${REVISER_RUNNER})"
    run_agent_checked "$REVISER_RUNNER" "$INITIAL_PROMPT" "$INITIAL_REVISER_REPORT" \
      "${LOGS_DIR}/01-initial-${REVISER_RUNNER}.log" "initial-${REVISER_RUNNER}" "$REVISER_CMD"
    log_info "Phase done: initial (${REVISER_RUNNER})"
  fi

  if [[ "$need_reviewer" -eq 1 ]]; then
    log_info "Phase start: initial (${REVIEWER_RUNNER})"
    NEXT_PHASE="initial-reviewer"
    run_agent_checked "$REVIEWER_RUNNER" "$INITIAL_PROMPT" "$INITIAL_REVIEWER_REPORT" \
      "${LOGS_DIR}/01-initial-${REVIEWER_RUNNER}.log" "initial-${REVIEWER_RUNNER}" "$REVIEWER_CMD"
    log_info "Phase done: initial (${REVIEWER_RUNNER})"
  fi
}

build_input_list() {
  local out=""
  local f
  for f in "${INPUT_FILES[@]}"; do
    out+="- ${f}"$'\n'
  done
  echo "$out"
}

to_workdir_relative_path() {
  local target_path="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$WORKDIR" "$target_path" <<'PY'
import os
import sys
base = os.path.abspath(sys.argv[1])
target = os.path.abspath(sys.argv[2])
print(os.path.relpath(target, base))
PY
  else
    printf "%s\n" "$target_path"
  fi
}

render_file_reference_block() {
  local title="$1"
  local file="$2"
  local rel_file=""

  [[ -f "$file" ]] || fail "required artifact missing for prompt assembly: $file (this phase depends on outputs from earlier phases; if resuming with --from-phase, ensure prerequisite outputs exist)"
  rel_file="$(to_workdir_relative_path "$file")"

  cat <<EOF_BLOCK
【${title} 文件路径（相对工作目录）】
${rel_file}
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
6. 报告正文必须可直接写入目标文件（不要额外说明文字）。
EOF_PROMPT
}

build_compare_prompt() {
  {
    cat <<EOF_PROMPT
你是技术审查对比分析员。请对两份审查报告进行对比分析。
EOF_PROMPT

    echo ""
    render_file_reference_block "报告A" "$INITIAL_REVISER_REPORT"

    echo ""
    render_file_reference_block "报告B" "$INITIAL_REVIEWER_REPORT"

    cat <<EOF_PROMPT

请自行读取上述文件并完成对比分析。

【输出要求】
1. 输出 Markdown 对比分析。
2. 给出：共同结论、仅A提出、仅B提出、互相冲突点。
3. 对冲突点标注你认为更可信的一方并说明依据。
4. 给出后续合并建议（保留、降级、删除、待确认）。
5. 对比分析正文必须可直接写入目标文件（不要额外说明文字）。
EOF_PROMPT
  } >"$COMPARE_PROMPT"
}

build_merge_prompt() {
  {
    cat <<EOF_PROMPT
你是会审合并编辑。请基于两份报告和两份对比分析，产出一份合并版正式审查报告。
EOF_PROMPT

    echo ""
    render_file_reference_block "初始报告-${REVISER_RUNNER}" "$INITIAL_REVISER_REPORT"

    echo ""
    render_file_reference_block "初始报告-${REVIEWER_RUNNER}" "$INITIAL_REVIEWER_REPORT"

    echo ""
    render_file_reference_block "对比分析-${REVISER_RUNNER}" "$COMPARE_REVISER_REPORT"

    echo ""
    render_file_reference_block "对比分析-${REVIEWER_RUNNER}" "$COMPARE_REVIEWER_REPORT"

    cat <<EOF_PROMPT

请自行读取上述文件并完成报告合并。

【输出要求】
1. 输出完整 Markdown 报告正文（不要额外解释）。
2. 保留可验证问题，去除已证伪或证据不足项。
3. 所有问题按严重级别排序并包含证据路径+行号。
4. 加入“审查边界/待确认项”。
5. 报告正文必须可直接写入目标文件。
EOF_PROMPT
  } >"$MERGE_PROMPT"
}

build_reviewer_round_prompt() {
  local round="$1"
  local prompt_file="${PROMPTS_DIR}/04-round-${round}-${REVIEWER_RUNNER}-review.prompt.txt"
  {
    cat <<EOF_PROMPT
请评审以下“合并版审查报告”的质量与事实准确性。
EOF_PROMPT

    echo ""
    render_file_reference_block "合并版审查报告" "$MERGED_REPORT"

    cat <<EOF_PROMPT

请先自行读取上述报告文件。

重点检查：
1. 是否还有事实错误、误报、证据不足、矛盾表述。
2. 是否存在可改进之处（分级、措辞、证据完整性）。

【严格输出规则】
- 如果你认为当前版本已无问题，或你提出的意见全部可视为不必采纳，请严格输出以下字符串（原样，不要增加任何其他内容）：
${SUCCESS_MARKER}
- 否则输出“问题清单（按严重级）”，每条包含修改建议。
- 不要创建、修改或写入任何文件；直接在当前响应输出上述内容。
EOF_PROMPT
  } >"$prompt_file"
  echo "$prompt_file"
}

build_reviser_round_prompt() {
  local round="$1"
  local reviewer_feedback_file="$2"
  local prompt_file="${PROMPTS_DIR}/05-round-${round}-${REVISER_RUNNER}-revise.prompt.txt"
  {
    cat <<EOF_PROMPT
请根据 ${REVIEWER_RUNNER} 的评审意见修订合并版审查报告。
EOF_PROMPT

    echo ""
    render_file_reference_block "当前合并版" "$MERGED_REPORT"

    echo ""
    render_file_reference_block "${REVIEWER_RUNNER} 评审意见" "$reviewer_feedback_file"

    cat <<EOF_PROMPT

请先自行读取上述文件，再决定是否采纳本轮意见并完成修订。

【严格输出规则】
- 如果你决定“全部不采纳 ${REVIEWER_RUNNER} 本轮意见”，请严格输出以下字符串（原样，不要增加任何其他内容）：
${SUCCESS_MARKER}
- 否则请输出“修订后的完整 Markdown 报告正文”（完整替换版本，不要解释）。
- 如果输出修订稿，正文必须可直接写入目标文件。
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

is_valid_phase() {
  case "$1" in
    initial-reviser|initial-reviewer|compare-reviser|compare-reviewer|merge|round-reviewer|round-reviser|completed)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

status=""
NEXT_PHASE="initial-reviser"
NEXT_ROUND=1
LAST_ROUND_EXECUTED=0

log_info "Task: ${TASK_NAME}"
log_info "Task dir: ${TASK_DIR}"
log_info "Config: ${CONFIG_FILE}"
log_info "Working directory: ${WORKDIR}"
log_info "Reviewer runner: ${REVIEWER_RUNNER}"
log_info "Reviser runner: ${REVISER_RUNNER}"
log_info "Max rounds: ${MAX_ROUNDS}"
log_info "Timeout seconds: ${TIMEOUT_SECONDS}"
log_info "Success marker: ${SUCCESS_MARKER}"
if [[ -n "$FINAL_REPORT_PATH" ]]; then
  log_info "Final report path (relative to working directory): ${FINAL_REPORT_PATH}"
fi
log_info "Dry run: ${DRY_RUN}"
log_info "Resume: ${RESUME}"

build_initial_prompt

if [[ "$DRY_RUN" -eq 1 ]]; then
  write_dry_run_placeholder "$INITIAL_REVISER_REPORT" "Initial Review (${REVISER_RUNNER})"
  write_dry_run_placeholder "$INITIAL_REVIEWER_REPORT" "Initial Review (${REVIEWER_RUNNER})"
  build_compare_prompt
  write_dry_run_placeholder "$COMPARE_REVISER_REPORT" "Compare Analysis (${REVISER_RUNNER})"
  write_dry_run_placeholder "$COMPARE_REVIEWER_REPORT" "Compare Analysis (${REVIEWER_RUNNER})"
  build_merge_prompt
  write_dry_run_placeholder "$MERGED_REPORT" "Merged Report (${REVISER_RUNNER})"
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

    if [[ "$NEXT_PHASE" == "round-reviewer" || "$NEXT_PHASE" == "round-reviser" ]]; then
      if [[ -n "$RESUME_FROM_ROUND" ]]; then
        NEXT_ROUND="$RESUME_FROM_ROUND"
      elif [[ "$NEXT_ROUND" -lt 1 ]]; then
        NEXT_ROUND=1
      fi
    else
      if [[ -n "$RESUME_FROM_ROUND" ]]; then
        fail "--from-round can only be used with --from-phase round-reviewer or round-reviser"
      fi
      NEXT_ROUND=1
    fi

    write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "manual-resume-override"
  fi
else
  write_progress_json "running" "initial-reviser" 1 "" "bootstrap"
fi

while :; do
  case "$NEXT_PHASE" in
    initial-reviser)
      run_initial_phase
      NEXT_PHASE="compare-reviser"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "initial-${REVISER_RUNNER}"
      ;;

    initial-reviewer)
      run_initial_phase
      NEXT_PHASE="compare-reviser"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "initial-${REVIEWER_RUNNER}"
      ;;

    compare-reviser)
      log_info "Phase start: compare (${REVISER_RUNNER})"
      build_compare_prompt
      run_agent_checked "$REVISER_RUNNER" "$COMPARE_PROMPT" "$COMPARE_REVISER_REPORT" \
        "${LOGS_DIR}/02-compare-${REVISER_RUNNER}.log" "compare-${REVISER_RUNNER}" "$REVISER_CMD"
      log_info "Phase done: compare (${REVISER_RUNNER})"
      NEXT_PHASE="compare-reviewer"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "compare-${REVISER_RUNNER}"
      ;;

    compare-reviewer)
      log_info "Phase start: compare (${REVIEWER_RUNNER})"
      build_compare_prompt
      run_agent_checked "$REVIEWER_RUNNER" "$COMPARE_PROMPT" "$COMPARE_REVIEWER_REPORT" \
        "${LOGS_DIR}/02-compare-${REVIEWER_RUNNER}.log" "compare-${REVIEWER_RUNNER}" "$REVIEWER_CMD"
      log_info "Phase done: compare (${REVIEWER_RUNNER})"
      NEXT_PHASE="merge"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "compare-${REVIEWER_RUNNER}"
      ;;

    merge)
      log_info "Phase start: merge (${REVISER_RUNNER})"
      build_merge_prompt
      run_agent_checked "$REVISER_RUNNER" "$MERGE_PROMPT" "$MERGED_REPORT" \
        "${LOGS_DIR}/03-merge-${REVISER_RUNNER}.log" "merge-${REVISER_RUNNER}" "$REVISER_CMD"
      log_info "Phase done: merge (${REVISER_RUNNER})"
      NEXT_PHASE="round-reviewer"
      NEXT_ROUND=1
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "merge-${REVISER_RUNNER}"
      ;;

    round-reviewer)
      if [[ "$NEXT_ROUND" -gt "$MAX_ROUNDS" ]]; then
        status="max-rounds-reached"
        NEXT_PHASE="completed"
        write_progress_json "completed" "$NEXT_PHASE" "$NEXT_ROUND" "$status" "round-limit"
        break
      fi

      LAST_ROUND_EXECUTED="$NEXT_ROUND"
      round_label="$(printf '%02d' "$NEXT_ROUND")"
      log_info "Round ${round_label}/${MAX_ROUNDS} start: ${REVIEWER_RUNNER} review"
      reviewer_prompt="$(build_reviewer_round_prompt "$round_label")"
      reviewer_review_file="${REPORTS_ROUNDS_DIR}/round-${round_label}-${REVIEWER_RUNNER}-review.md"
      reviewer_log_file="${LOGS_DIR}/04-round-${round_label}-${REVIEWER_RUNNER}-review.log"

      run_agent_checked "$REVIEWER_RUNNER" "$reviewer_prompt" "$reviewer_review_file" \
        "$reviewer_log_file" "round-${round_label}-${REVIEWER_RUNNER}" "$REVIEWER_CMD"
      log_info "Round ${round_label}/${MAX_ROUNDS} done: ${REVIEWER_RUNNER} review"

      if contains_marker "$reviewer_review_file" "$SUCCESS_MARKER"; then
        status="accepted-by-${REVIEWER_RUNNER}-round-${round_label}"
        NEXT_PHASE="completed"
        write_progress_json "completed" "$NEXT_PHASE" "$NEXT_ROUND" "$status" "round-${round_label}-${REVIEWER_RUNNER}"
        break
      fi

      NEXT_PHASE="round-reviser"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "round-${round_label}-${REVIEWER_RUNNER}"
      ;;

    round-reviser)
      if [[ "$NEXT_ROUND" -gt "$MAX_ROUNDS" ]]; then
        status="max-rounds-reached"
        NEXT_PHASE="completed"
        write_progress_json "completed" "$NEXT_PHASE" "$NEXT_ROUND" "$status" "round-limit"
        break
      fi

      LAST_ROUND_EXECUTED="$NEXT_ROUND"
      round_label="$(printf '%02d' "$NEXT_ROUND")"
      reviewer_review_file="${REPORTS_ROUNDS_DIR}/round-${round_label}-${REVIEWER_RUNNER}-review.md"
      log_info "Round ${round_label}/${MAX_ROUNDS} start: ${REVISER_RUNNER} revision"
      reviser_prompt="$(build_reviser_round_prompt "$round_label" "$reviewer_review_file")"
      reviser_revision_file="${REPORTS_ROUNDS_DIR}/round-${round_label}-${REVISER_RUNNER}-revision.md"
      reviser_log_file="${LOGS_DIR}/05-round-${round_label}-${REVISER_RUNNER}-revision.log"

      run_agent_checked "$REVISER_RUNNER" "$reviser_prompt" "$reviser_revision_file" \
        "$reviser_log_file" "round-${round_label}-${REVISER_RUNNER}" "$REVISER_CMD"
      log_info "Round ${round_label}/${MAX_ROUNDS} done: ${REVISER_RUNNER} revision"

      if contains_marker "$reviser_revision_file" "$SUCCESS_MARKER"; then
        status="${REVISER_RUNNER}-rejected-all-feedback-round-${round_label}"
        NEXT_PHASE="completed"
        write_progress_json "completed" "$NEXT_PHASE" "$NEXT_ROUND" "$status" "round-${round_label}-${REVISER_RUNNER}"
        break
      fi

      cp "$reviser_revision_file" "$MERGED_REPORT"
      NEXT_ROUND=$((NEXT_ROUND + 1))
      NEXT_PHASE="round-reviewer"
      write_progress_json "running" "$NEXT_PHASE" "$NEXT_ROUND" "" "round-${round_label}-${REVISER_RUNNER}"
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
log_info "Progress: $PROGRESS_FILE"

if [[ "$status" == "max-rounds-reached" ]]; then
  exit 2
fi
