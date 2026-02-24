#!/usr/bin/env bash

augment_claude_prompt_for_file_output() {
  local prompt_file="$1"
  local output_file="$2"
  local augmented_prompt_file="$3"

  cat "$prompt_file" >"$augmented_prompt_file"
  cat >>"$augmented_prompt_file" <<EOF

【输出落盘要求（必须严格执行）】
请将你的最终完整输出正文写入以下文件路径（覆盖写入）：
__OUTPUT_FILE_PATH__=${output_file}

执行规则：
1. 只写入上面的路径，不要写入任何其他文件。
2. 写入完成后，你在当前响应中只输出：OUTPUT_WRITTEN
3. 不要在当前响应中输出报告正文。
EOF
}

run_agent() {
  local agent="$1"
  local prompt_file="$2"
  local output_file="$3"
  local log_file="$4"
  local timeout_seconds="$5"
  local workdir="$6"
  local custom_cmd="${7:-}"
  local claude_prompt_file=""
  local claude_debug_mode="${IMPLEMENTATION_AUDIT_CLAUDE_DEBUG:-0}"
  local claude_debug_file=""
  local rc=0

  rm -f "$output_file" "$log_file"

  if [[ -n "$custom_cmd" ]]; then
    (
      cd "$workdir"
      timeout "${timeout_seconds}s" bash -lc "$custom_cmd" \
        <"$prompt_file" >"$output_file" 2>"$log_file"
    )
    rc=$?
  else
    case "$agent" in
      claude)
        claude_prompt_file="$(mktemp)"
        augment_claude_prompt_for_file_output "$prompt_file" "$output_file" "$claude_prompt_file"
        claude_debug_file="${log_file}.debug"
        rm -f "$claude_debug_file"
        (
          cd "$workdir"
          if [[ "$claude_debug_mode" == "1" || "$claude_debug_mode" == "true" || "$claude_debug_mode" == "TRUE" || "$claude_debug_mode" == "yes" || "$claude_debug_mode" == "YES" ]]; then
            timeout "${timeout_seconds}s" \
              claude -p --dangerously-skip-permissions --debug-file "$claude_debug_file" - \
              <"$claude_prompt_file" >>"$log_file" 2>>"$log_file"
          else
            timeout "${timeout_seconds}s" \
              claude -p --dangerously-skip-permissions - \
              <"$claude_prompt_file" >>"$log_file" 2>>"$log_file"
          fi
        )
        rc=$?
        rm -f "$claude_prompt_file"
        ;;
      codex)
        (
          cd "$workdir"
          timeout "${timeout_seconds}s" \
            codex exec - \
              --dangerously-bypass-approvals-and-sandbox \
              --skip-git-repo-check \
              --output-last-message "$output_file" \
              <"$prompt_file" >"$log_file" 2>&1
        )
        rc=$?
        ;;
      *)
        echo "unknown agent: $agent" >&2
        return 2
        ;;
    esac
  fi

  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 124 ]]; then
      echo "agent command timed out after ${timeout_seconds}s: $agent" >&2
    else
      echo "agent command failed with exit code ${rc}: $agent" >&2
    fi
    return "$rc"
  fi

  if [[ ! -e "$output_file" ]]; then
    echo "agent did not produce output file: $output_file" >&2
    return 3
  fi

  if [[ ! -s "$output_file" ]]; then
    echo "agent output file is empty: $output_file" >&2
    return 3
  fi
}
