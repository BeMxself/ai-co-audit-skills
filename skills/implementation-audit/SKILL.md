---
name: implementation-audit
description: Sync and run implementation-audit automation scripts in a project. Supports configurable reviewer/reviser runners (claude/codex/kiro/custom), init, run, continue, and manual resume.
user_invocable: true
argument: "<action and args>"
---

# Implementation Audit Skill

This skill installs/syncs implementation-audit automation assets into the current project, then runs the workflow.

## Path Model

- `PROJECT_ROOT`: current working directory.
- `SKILL_DIR`: directory containing this `SKILL.md`.
- `PROJECT_REFERENCE_DIR`: `${PROJECT_ROOT}/skills/implementation-audit/automation-ref`.
- `SKILL_REFERENCE_DIR`: `${SKILL_DIR}/automation-ref`.
- `FALLBACK_SOURCE_DIR`: `${AI_CO_AUDIT_SKILLS_SOURCE_DIR:-$HOME/Projects/ai-co-audit-skills}`.
- `FALLBACK_REFERENCE_DIR`: `${FALLBACK_SOURCE_DIR}/skills/implementation-audit/automation-ref`.
- `REFERENCE_DIR`: resolved source directory.
- `TARGET_DIR`: `${PROJECT_ROOT}/automation/implementation-audit`.

Resolve `REFERENCE_DIR` before Step 1:

```bash
PROJECT_REFERENCE_DIR="${PROJECT_ROOT}/skills/implementation-audit/automation-ref"
SKILL_REFERENCE_DIR="${SKILL_DIR}/automation-ref"
FALLBACK_SOURCE_DIR="${AI_CO_AUDIT_SKILLS_SOURCE_DIR:-$HOME/Projects/ai-co-audit-skills}"
FALLBACK_REFERENCE_DIR="${FALLBACK_SOURCE_DIR}/skills/implementation-audit/automation-ref"

if [[ -d "${PROJECT_REFERENCE_DIR}" ]]; then
  REFERENCE_DIR="${PROJECT_REFERENCE_DIR}"
elif [[ -d "${FALLBACK_REFERENCE_DIR}" ]]; then
  REFERENCE_DIR="${FALLBACK_REFERENCE_DIR}"
else
  REFERENCE_DIR="${SKILL_REFERENCE_DIR}"
fi
```

## Step 1: Sync Automation Assets

If `${TARGET_DIR}/sync-automation.sh` is missing, copy it from reference first:

```bash
mkdir -p automation/implementation-audit
cp "${REFERENCE_DIR}/sync-automation.sh" automation/implementation-audit/sync-automation.sh
chmod +x automation/implementation-audit/sync-automation.sh
```

Run sync check:

```bash
bash automation/implementation-audit/sync-automation.sh "${REFERENCE_DIR}" "${TARGET_DIR}"
```

If exit code is `1`, show `[MISS]` / `[DIFF]` items and ask user whether to force sync. If user agrees:

```bash
bash automation/implementation-audit/sync-automation.sh "${REFERENCE_DIR}" "${TARGET_DIR}" --auto-copy
```

## Step 2 (Optional): Prepare Kiro Agent

Only needed when reviewer/reviser uses `kiro` runner.

```bash
bash automation/implementation-audit/setup-kiro-agent.sh \
  --project-root "${PROJECT_ROOT}" \
  --agent-name "ai-co-audit-kiro-opus" \
  --model "claude-opus-4.6"
```

Use `--force` to overwrite an existing agent file.

## Step 3: Execute User Intent

### Init Task

```bash
bash automation/implementation-audit/init.sh \
  --input <file> [--input <file> ...] \
  [--prompt "..."] \
  [--reviewer codex] \
  [--reviser claude] \
  [--runner-cmd kiro='prompt="$(cat)"; kiro-cli chat --agent ai-co-audit-kiro-opus --no-interactive --trust-all-tools "$prompt"'] \
  [--kiro-agent ai-co-audit-kiro-opus] \
  [--final-report-path <relative-path>]
```

Defaults:
- `reviewer=codex`
- `reviser=claude`
- merge phase executed by `reviser`

### Run Task

```bash
.ai-workflows/<task-id>/run
```

`run` reads task config first, prints plugin version, then asks for one-time confirmation in interactive terminals (`y` to continue). In non-interactive terminals, it auto-continues.

CLI overrides are supported:

```bash
.ai-workflows/<task-id>/run --reviewer codex --reviser kiro
```

Override precedence:
- CLI (`--reviewer/--reviser`)
- `task.json` default (`execution.reviewer/reviser`)
- hardcoded default (`codex` / `claude`)

### Continue Task

```bash
.ai-workflows/<task-id>/continue
```

### Continue from Specific Phase

```bash
.ai-workflows/<task-id>/continue --from-phase <phase> [--from-round <n>]
```

Valid phases:
- `initial-reviser`
- `initial-reviewer`
- `compare-reviser`
- `compare-reviewer`
- `merge`
- `round-reviewer`
- `round-reviser`
- `completed`

## Notes

- `init` must remain non-interactive.
- `run` may ask one startup confirmation in interactive terminals; non-interactive terminals must auto-continue.
- Keep workflow files under `.ai-workflows/<task-id>/`.
- `--final-report-path` must be relative to `workingDirectory`.
- If `kiro` runner is used with built-in command, the workflow verifies Kiro agent file tools before execution and fails fast when file read/write tools are missing.
