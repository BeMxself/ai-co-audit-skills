#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TASK_ID=""
TASK_NAME=""
OBJECTIVE=""
OBJECTIVE_FILE=""
REPORT_BASE_NAME=""
MAX_ROUNDS="15"
TIMEOUT_SECONDS="7200"
WORKING_DIRECTORY="."
FINAL_REPORT_PATH=""
SUCCESS_MARKER="当前版本已无问题，可以作为正式版本使用"
FORCE=0
CLAUDE_CMD=""
CODEX_CMD=""
KIRO_AGENT_NAME="ai-co-audit-kiro-opus"
INPUTS=()
AUTO_META_WITH_CLAUDE=0
USER_PROVIDED_TASK_ID=0
DEFAULT_OBJECTIVE="检查未完成的、与设计不符合的、违反设计原则的、重复实现的、逻辑不能自洽的、实现存在矛盾的问题，并给出可验证证据（文件路径 + 行号）。"

slugify() {
  local raw="$1"
  local normalized
  normalized="$(printf "%s" "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
  normalized="$(printf "%s" "$normalized" | sed 's/^-*//;s/-*$//;s/-\{2,\}/-/g')"
  printf "%s" "$normalized"
}

input_list_text() {
  local out=""
  local item
  for item in "${INPUTS[@]}"; do
    out+="- ${item}"$'\n'
  done
  printf "%s" "$out"
}

extract_json_block() {
  local response="$1"
  local json_block=""

  if printf "%s" "$response" | jq -e . >/dev/null 2>&1; then
    printf "%s" "$response"
    return 0
  fi

  json_block="$(printf "%s\n" "$response" | awk 'BEGIN{in_json=0} /^```json/{in_json=1;next} /^```/{if(in_json){exit}} {if(in_json)print}')"
  if [[ -n "$json_block" ]] && printf "%s" "$json_block" | jq -e . >/dev/null 2>&1; then
    printf "%s" "$json_block"
    return 0
  fi

  return 1
}

try_generate_meta_with_claude() {
  command -v claude >/dev/null 2>&1 || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local prompt=""
  local response=""
  local json_payload=""
  local generated_task_id=""
  local generated_task_name=""
  local generated_report_base_name=""

  prompt="$(cat <<EOF
你是实现审计任务初始化助手。请根据下面信息生成 JSON。

【任务目标（可为空）】
${OBJECTIVE}

【输入文件】
$(input_list_text)

【输出要求】
1. 只输出一个 JSON 对象，不要输出 markdown 代码块，不要输出解释文字。
2. JSON 字段必须包含：
   - taskId: 英文小写短横线风格，适合目录名
   - taskName: 可读任务名
   - reportBaseName: 英文小写短横线风格，适合文件名前缀
3. taskId 和 reportBaseName 必须体现 implementation-audit 语义。
EOF
)"

  response="$(timeout 45s claude -p --dangerously-skip-permissions -c - <<<"$prompt" 2>/dev/null || true)"
  [[ -n "$response" ]] || return 1

  json_payload="$(extract_json_block "$response")" || return 1

  generated_task_id="$(printf "%s" "$json_payload" | jq -r '.taskId // empty')"
  generated_task_name="$(printf "%s" "$json_payload" | jq -r '.taskName // empty')"
  generated_report_base_name="$(printf "%s" "$json_payload" | jq -r '.reportBaseName // empty')"

  generated_task_id="$(slugify "$generated_task_id")"
  generated_report_base_name="$(slugify "$generated_report_base_name")"

  [[ -n "$generated_task_id" ]] || return 1
  [[ -n "$generated_task_name" ]] || return 1
  [[ -n "$generated_report_base_name" ]] || generated_report_base_name="${generated_task_id}-implementation-audit-report"

  TASK_ID="${TASK_ID:-$generated_task_id}"
  TASK_NAME="${TASK_NAME:-$generated_task_name}"
  REPORT_BASE_NAME="${REPORT_BASE_NAME:-$generated_report_base_name}"
  return 0
}

generate_meta_fallback() {
  local first_input_basename=""
  local first_input_slug=""
  local time_tag=""

  first_input_basename="$(basename "${INPUTS[0]}")"
  first_input_basename="${first_input_basename%.*}"
  first_input_slug="$(slugify "$first_input_basename")"
  [[ -n "$first_input_slug" ]] || first_input_slug="artifact"

  time_tag="$(date '+%Y%m%d-%H%M%S')"
  TASK_ID="${TASK_ID:-${time_tag}-${first_input_slug}-implementation-audit}"
  TASK_NAME="${TASK_NAME:-Implementation Audit - ${first_input_basename}}"
  REPORT_BASE_NAME="${REPORT_BASE_NAME:-${TASK_ID}-implementation-audit-report}"
}

ensure_unique_auto_task_id() {
  local base_task_id="$1"
  local candidate="$base_task_id"
  local idx=1
  while [[ -d "${REPO_ROOT}/.ai-workflows/${candidate}" ]]; do
    candidate="${base_task_id}-$(printf '%02d' "$idx")"
    idx=$((idx + 1))
  done
  TASK_ID="$candidate"
  if [[ -z "$REPORT_BASE_NAME" || "$REPORT_BASE_NAME" == "${base_task_id}-implementation-audit-report" ]]; then
    REPORT_BASE_NAME="${TASK_ID}-implementation-audit-report"
  fi
}

validate_inputs_exist() {
  local f
  for f in "${INPUTS[@]}"; do
    if [[ -f "$f" || -f "${REPO_ROOT}/${f}" ]]; then
      continue
    fi
    fail "input file not found: $f"
  done
}

usage() {
  cat <<'USAGE'
Usage:
  automation/implementation-audit-kiro/init.sh --input <file> [--input <file> ...] [options]

Options:
  --input <file>            Input file to audit (repeatable, required)
  --prompt <text>           Audit prompt/objective text (optional)
  --prompt-file <file>      Read audit prompt/objective from file (optional)

  --task-id <id>            Override auto-generated task id
  --task-name <name>        Override auto-generated task name
  --report-base-name <name> Override auto-generated report base name
  --objective <text>        Alias of --prompt
  --objective-file <file>   Alias of --prompt-file
  --max-rounds <n>          Max review rounds (default: 15)
  --timeout-seconds <n>     Per-agent timeout (default: 7200)
  --working-directory <dir> Working directory for agent commands (default: .)
  --final-report-path <p>   Save final merged report to this relative path (relative to working directory)
  --success-marker <text>   Loop-exit marker string
  --kiro-agent <name>       Kiro agent name used in default command (default: ai-co-audit-kiro-opus)
  --claude-cmd <cmd>        Custom claude command (reads prompt from stdin)
  --codex-cmd <cmd>         Custom codex command (reads prompt from stdin)
  --no-claude-meta          Do not use claude for task meta generation (default in Kiro flow)
  --force                   Overwrite existing task directory
  -h, --help                Show help
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      TASK_ID="$2"
      USER_PROVIDED_TASK_ID=1
      shift 2
      ;;
    --task-name)
      TASK_NAME="$2"
      shift 2
      ;;
    --prompt)
      OBJECTIVE="$2"
      shift 2
      ;;
    --prompt-file)
      OBJECTIVE_FILE="$2"
      shift 2
      ;;
    --objective)
      OBJECTIVE="$2"
      shift 2
      ;;
    --objective-file)
      OBJECTIVE_FILE="$2"
      shift 2
      ;;
    --input)
      INPUTS+=("$2")
      shift 2
      ;;
    --report-base-name)
      REPORT_BASE_NAME="$2"
      shift 2
      ;;
    --max-rounds)
      MAX_ROUNDS="$2"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --working-directory)
      WORKING_DIRECTORY="$2"
      shift 2
      ;;
    --final-report-path)
      FINAL_REPORT_PATH="$2"
      shift 2
      ;;
    --success-marker)
      SUCCESS_MARKER="$2"
      shift 2
      ;;
    --kiro-agent)
      KIRO_AGENT_NAME="$2"
      shift 2
      ;;
    --claude-cmd)
      CLAUDE_CMD="$2"
      shift 2
      ;;
    --codex-cmd)
      CODEX_CMD="$2"
      shift 2
      ;;
    --no-claude-meta)
      AUTO_META_WITH_CLAUDE=0
      shift
      ;;
    --force)
      FORCE=1
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

[[ "${#INPUTS[@]}" -gt 0 ]] || fail "At least one --input is required"
validate_inputs_exist

if [[ -n "$OBJECTIVE_FILE" ]]; then
  if [[ -f "$OBJECTIVE_FILE" ]]; then
    OBJECTIVE="$(cat "$OBJECTIVE_FILE")"
  elif [[ -f "${REPO_ROOT}/${OBJECTIVE_FILE}" ]]; then
    OBJECTIVE="$(cat "${REPO_ROOT}/${OBJECTIVE_FILE}")"
  else
    fail "objective file not found: $OBJECTIVE_FILE"
  fi
fi

if [[ -z "$OBJECTIVE" ]]; then
  OBJECTIVE="$DEFAULT_OBJECTIVE"
fi

if [[ -n "$FINAL_REPORT_PATH" && "$FINAL_REPORT_PATH" = /* ]]; then
  fail "--final-report-path must be a relative path (relative to working directory)"
fi

if [[ -z "$KIRO_AGENT_NAME" ]]; then
  fail "--kiro-agent must not be empty"
fi

FINAL_REPORT_PATH_DISPLAY="(not configured)"
if [[ -n "$FINAL_REPORT_PATH" ]]; then
  FINAL_REPORT_PATH_DISPLAY="(configured)"
fi

if [[ -z "$CLAUDE_CMD" ]]; then
  CLAUDE_CMD="prompt=\"\$(cat)\"; kiro-cli chat --agent \"${KIRO_AGENT_NAME}\" --no-interactive --trust-all-tools \"\$prompt\""
fi

if [[ -z "$TASK_ID" || -z "$TASK_NAME" || -z "$REPORT_BASE_NAME" ]]; then
  if [[ "$AUTO_META_WITH_CLAUDE" -eq 1 ]] && try_generate_meta_with_claude; then
    log_info "Task metadata generated by claude."
  else
    generate_meta_fallback
    log_info "Task metadata generated by local fallback."
  fi
fi

TASK_ID="$(slugify "$TASK_ID")"
REPORT_BASE_NAME="$(slugify "$REPORT_BASE_NAME")"

[[ -n "$TASK_ID" ]] || fail "failed to generate task id"
[[ -n "$TASK_NAME" ]] || fail "failed to generate task name"
[[ -n "$REPORT_BASE_NAME" ]] || REPORT_BASE_NAME="${TASK_ID}-implementation-audit-report"

if [[ "$USER_PROVIDED_TASK_ID" -eq 0 && "$FORCE" -ne 1 ]]; then
  ensure_unique_auto_task_id "$TASK_ID"
fi

TASK_DIR="${REPO_ROOT}/.ai-workflows/${TASK_ID}"

if [[ -d "$TASK_DIR" ]]; then
  if [[ "$FORCE" -ne 1 ]]; then
    fail "Task dir already exists: $TASK_DIR (use --force to overwrite)"
  fi
  rm -rf "$TASK_DIR"
fi

ensure_dir "$TASK_DIR"
ensure_dir "$TASK_DIR/config"
ensure_dir "$TASK_DIR/inputs"
ensure_dir "$TASK_DIR/prompts"
ensure_dir "$TASK_DIR/reports/initial"
ensure_dir "$TASK_DIR/reports/comparison"
ensure_dir "$TASK_DIR/reports/merged"
ensure_dir "$TASK_DIR/reports/rounds"
ensure_dir "$TASK_DIR/logs"
ensure_dir "$TASK_DIR/state"
ensure_dir "$TASK_DIR/transcripts"

printf "%s\n" "${INPUTS[@]}" >"${TASK_DIR}/inputs/targets.txt"
printf "%s\n" "$OBJECTIVE" >"${TASK_DIR}/inputs/objective.txt"

inputs_json="$(printf "%s\n" "${INPUTS[@]}" | jq -R . | jq -s .)"

jq -n \
  --arg taskName "$TASK_NAME" \
  --arg objective "$OBJECTIVE" \
  --arg reportBaseName "$REPORT_BASE_NAME" \
  --arg successMarker "$SUCCESS_MARKER" \
  --arg workingDirectory "$WORKING_DIRECTORY" \
  --arg finalReportPath "" \
  --arg claudeCmd "$CLAUDE_CMD" \
  --arg codexCmd "$CODEX_CMD" \
  --argjson maxRounds "$MAX_ROUNDS" \
  --argjson timeoutSeconds "$TIMEOUT_SECONDS" \
  --argjson inputs "$inputs_json" \
  '{
    taskName: $taskName,
    objective: $objective,
    inputs: $inputs,
    reportBaseName: $reportBaseName,
    maxRounds: $maxRounds,
    timeoutSeconds: $timeoutSeconds,
    workingDirectory: $workingDirectory,
    finalReportPath: $finalReportPath,
    successMarker: $successMarker,
    agents: {
      claude: { command: $claudeCmd },
      codex: { command: $codexCmd }
    }
  }' >"${TASK_DIR}/config/task.json"

FINAL_REPORT_ARG=""
if [[ -n "$FINAL_REPORT_PATH" ]]; then
  FINAL_REPORT_ARG="--final-report-path \"${FINAL_REPORT_PATH}\""
fi

cat >"${TASK_DIR}/run" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TASK_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="\$(cd "\${TASK_DIR}/../.." && pwd)"

"\${REPO_ROOT}/automation/implementation-audit-kiro/run-implementation-audit.sh" \\
  --task-dir "\${TASK_DIR}" ${FINAL_REPORT_ARG} "\$@"
EOF
chmod +x "${TASK_DIR}/run"

cat >"${TASK_DIR}/continue" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TASK_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="\$(cd "\${TASK_DIR}/../.." && pwd)"

"\${REPO_ROOT}/automation/implementation-audit-kiro/run-implementation-audit.sh" \\
  --task-dir "\${TASK_DIR}" ${FINAL_REPORT_ARG} --resume "\$@"
EOF
chmod +x "${TASK_DIR}/continue"

cat >"${TASK_DIR}/README.md" <<EOF
# ${TASK_NAME}

## Run

\`\`\`bash
./.ai-workflows/${TASK_ID}/run
\`\`\`

## Continue

\`\`\`bash
./.ai-workflows/${TASK_ID}/continue
\`\`\`

## Continue From Phase

\`\`\`bash
./.ai-workflows/${TASK_ID}/continue --from-phase round-codex --from-round 3
\`\`\`

## Config

- Task config: \`.ai-workflows/${TASK_ID}/config/task.json\`
- Objective: \`.ai-workflows/${TASK_ID}/inputs/objective.txt\`
- Input targets: \`.ai-workflows/${TASK_ID}/inputs/targets.txt\`

## Outputs

- Initial reports: \`.ai-workflows/${TASK_ID}/reports/initial/\`
- Compare reports: \`.ai-workflows/${TASK_ID}/reports/comparison/\`
- Merged report: \`.ai-workflows/${TASK_ID}/reports/merged/\`
- Round outputs: \`.ai-workflows/${TASK_ID}/reports/rounds/\`
- Dialogue transcript: \`.ai-workflows/${TASK_ID}/transcripts/implementation-audit-dialogue.md\`
- Progress checkpoint: \`.ai-workflows/${TASK_ID}/state/progress.json\`
- State: \`.ai-workflows/${TASK_ID}/state/state.json\`
- Final report export path (if configured): \`${FINAL_REPORT_PATH_DISPLAY}\`
EOF

log_info "Task initialized: ${TASK_DIR}"
log_info "Entry scripts: ${TASK_DIR}/run , ${TASK_DIR}/continue"

cat <<EOF
Next steps (run in terminal):
  ./.ai-workflows/${TASK_ID}/run
  ./.ai-workflows/${TASK_ID}/continue
EOF
