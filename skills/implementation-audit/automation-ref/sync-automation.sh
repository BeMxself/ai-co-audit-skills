#!/usr/bin/env bash
# sync-automation.sh
# Compares implementation-audit reference scripts against a target directory and reports/copies differences.
# Usage: sync-automation.sh <reference-dir> <target-dir> [--auto-copy]
# Exit codes: 0=all in sync, 1=differences found, 2=invalid reference dir
set -euo pipefail

REFERENCE_DIR="${1:?Usage: sync-automation.sh <reference-dir> <target-dir> [--auto-copy]}"
TARGET_DIR="${2:?Usage: sync-automation.sh <reference-dir> <target-dir> [--auto-copy]}"
AUTO_COPY="${3:-}"

if [[ "$REFERENCE_DIR" != /* ]]; then
  REFERENCE_DIR="$(cd "$REFERENCE_DIR" && pwd)"
fi
if [[ "$TARGET_DIR" != /* ]]; then
  TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
fi

FILES=(
  "README.md"
  "init.sh"
  "init-implementation-audit-task.sh"
  "run-implementation-audit.sh"
  "lib/common.sh"
  "lib/runner.sh"
)

is_cache_reference_dir() {
  local dir="$1"
  [[ "$dir" == *"/.claude/plugins/cache/"* || "$dir" == *"/.claude/plugins/cache" ]]
}

is_valid_reference_dir() {
  local dir="$1"
  local f=""
  [[ -d "$dir" ]] || return 1
  for f in "${FILES[@]}"; do
    [[ -f "${dir}/${f}" ]] || return 1
  done
  return 0
}

resolve_non_cache_reference_dir() {
  local original="$1"
  local candidate=""
  local discovered_repo=""
  local -a candidates=()

  if ! is_cache_reference_dir "$original"; then
    echo "$original"
    return 0
  fi

  if [[ -n "${AI_CO_AUDIT_SKILLS_SOURCE_DIR:-}" ]]; then
    candidates+=("${AI_CO_AUDIT_SKILLS_SOURCE_DIR%/}/skills/implementation-audit/automation-ref")
    candidates+=("${AI_CO_AUDIT_SKILLS_SOURCE_DIR%/}")
  fi
  candidates+=("${PWD}/skills/implementation-audit/automation-ref")
  candidates+=("${HOME}/Projects/ai-co-audit-skills/skills/implementation-audit/automation-ref")

  if [[ -d "${HOME}/Projects" ]]; then
    while IFS= read -r discovered_repo; do
      candidates+=("${discovered_repo}/skills/implementation-audit/automation-ref")
    done < <(find "${HOME}/Projects" -maxdepth 4 -type d -name "ai-co-audit-skills" 2>/dev/null | head -n 20)
  fi

  for candidate in "${candidates[@]}"; do
    if is_cache_reference_dir "$candidate"; then
      continue
    fi
    if is_valid_reference_dir "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  echo ""
  return 1
}

ORIGINAL_REFERENCE_DIR="$REFERENCE_DIR"
if is_cache_reference_dir "$ORIGINAL_REFERENCE_DIR"; then
  resolved_reference_dir="$(resolve_non_cache_reference_dir "$ORIGINAL_REFERENCE_DIR" || true)"
  if [[ -z "$resolved_reference_dir" ]]; then
    echo "[ERROR] Cache reference detected: $ORIGINAL_REFERENCE_DIR" >&2
    echo "[ERROR] Could not resolve a non-cache source directory." >&2
    echo "[ERROR] Set AI_CO_AUDIT_SKILLS_SOURCE_DIR to your ai-co-audit-skills checkout root." >&2
    exit 2
  fi
  REFERENCE_DIR="$resolved_reference_dir"
  echo "[INFO] Cache reference detected. Using source dir: $REFERENCE_DIR"
fi

if ! is_valid_reference_dir "$REFERENCE_DIR"; then
  echo "[ERROR] Invalid reference dir: $REFERENCE_DIR" >&2
  echo "[ERROR] Expected implementation-audit automation files are missing." >&2
  exit 2
fi

NEED_CONFIRM=0

for f in "${FILES[@]}"; do
  source="${REFERENCE_DIR}/${f}"
  target="${TARGET_DIR}/${f}"

  if [[ ! -f "$target" ]]; then
    if [[ "$AUTO_COPY" == "--auto-copy" ]]; then
      mkdir -p "$(dirname "$target")"
      cp "$source" "$target"
      [[ -x "$source" ]] && chmod +x "$target"
      echo "[COPY] $f (created)"
    else
      echo "[MISS] $f (does not exist in target)"
      NEED_CONFIRM=1
    fi
  elif ! diff -q "$target" "$source" >/dev/null 2>&1; then
    if [[ "$AUTO_COPY" == "--auto-copy" ]]; then
      cp "$source" "$target"
      [[ -x "$source" ]] && chmod +x "$target"
      echo "[COPY] $f (replaced)"
    else
      echo "[DIFF] $f"
      NEED_CONFIRM=1
    fi
  else
    echo "[OK] $f"
  fi
done

exit ${NEED_CONFIRM}
