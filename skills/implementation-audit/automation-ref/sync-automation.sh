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

if [[ "$REFERENCE_DIR" == *"/.claude/plugins/cache/"* || "$REFERENCE_DIR" == *"/.claude/plugins/cache" ]]; then
  echo "[ERROR] Refusing to read Claude cache reference dir: $REFERENCE_DIR" >&2
  echo "[ERROR] Use a non-cache source directory to avoid syncing stale assets." >&2
  exit 2
fi

FILES=(
  "README.md"
  "init.sh"
  "init-implementation-audit-task.sh"
  "run-implementation-audit.sh"
  "lib/common.sh"
  "lib/runner.sh"
)

NEED_CONFIRM=0

for f in "${FILES[@]}"; do
  source="${REFERENCE_DIR}/${f}"
  target="${TARGET_DIR}/${f}"

  if [[ ! -f "$source" ]]; then
    echo "[WARN] Reference file missing: $f"
    continue
  fi

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
