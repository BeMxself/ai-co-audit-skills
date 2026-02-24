#!/usr/bin/env bash

run_agent() {
  local agent="$1"
  local prompt_file="$2"
  local output_file="$3"
  local log_file="$4"
  local timeout_seconds="$5"
  local workdir="$6"
  local custom_cmd="${7:-}"
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
        (
          cd "$workdir"
          timeout "${timeout_seconds}s" \
            claude -p --dangerously-skip-permissions - \
            <"$prompt_file" >"$output_file" 2>"$log_file"
        )
        rc=$?
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
